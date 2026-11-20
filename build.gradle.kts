plugins {
    id("org.springframework.boot") version "3.5.16" apply false
    id("io.spring.dependency-management") version "1.1.7" apply false
    kotlin("jvm") version "1.9.25" apply false
    kotlin("plugin.spring") version "1.9.25" apply false
    kotlin("plugin.jpa") version "1.9.25" apply false
    id("org.sonarqube") version "6.2.0.5505"
}

// SonarQube analysis (run by the CI pipeline with ./gradlew sonar).
// Server URL and token come from Jenkins; coverage comes from the JaCoCo XML reports.
sonar {
    properties {
        property("sonar.projectKey", "CircleGuard")
        property("sonar.projectName", "CircleGuard")
    }
}

allprojects {
    group = "com.circleguard"
    version = "1.0.0-SNAPSHOT"

    repositories {
        mavenCentral()
    }
}

val coverageGatedServices = setOf(
    ":services:circleguard-auth-service",
    ":services:circleguard-identity-service",
    ":services:circleguard-promotion-service",
    ":services:circleguard-form-service",
    ":services:circleguard-gateway-service"
)

subprojects {
    // Versions of libraries that the Spring Boot BOM does not manage, declared once.
    extra["resilience4jVersion"] = "2.2.0"

    apply(plugin = "java")
    apply(plugin = "org.jetbrains.kotlin.jvm")
    apply(plugin = "jacoco")
    extensions.configure<JavaPluginExtension> {
        toolchain {
            languageVersion.set(JavaLanguageVersion.of(21))
        }
    }

    // Jackson above the version managed by Spring Boot 3.5.16 (2.21.4): CVE-2026-68497 is
    // fixed in 2.21.6. The property drives the io.spring.dependency-management plugin and
    // the platform below drives Gradle's own resolution; both must agree.
    val jacksonVersion = "2.21.8"
    extra["jackson-bom.version"] = jacksonVersion

    // Security patches of transitive libraries, reported by the Trivy image scan. Each one
    // stays on the line Spring Boot 3.5.16 already uses (only the patch version changes).
    // Libraries managed by the Boot BOM are raised through its version properties; the
    // rest through dependency constraints.
    val bomOverrides = mapOf(
        "tomcat.version" to "10.1.62",        // CVE-2026-55276, -65182, -65637, -65905, -68525, -53404
        "netty.version" to "4.1.141.Final",   // CVE-2026-75595, -59901, -55831, -55833, -56745, -56819
        "postgresql.version" to "42.7.14",    // CVE-2026-54291
        "freemarker.version" to "2.3.35"      // CVE-2026-84939
    )
    bomOverrides.forEach { (property, version) -> extra[property] = version }
    val patchedLibraries = listOf(
        "org.apache.tomcat.embed:tomcat-embed-core:10.1.62",
        "org.apache.tomcat.embed:tomcat-embed-el:10.1.62",
        "org.apache.tomcat.embed:tomcat-embed-websocket:10.1.62",
        "io.netty:netty-bom:4.1.141.Final",
        "org.postgresql:postgresql:42.7.14",
        "org.freemarker:freemarker:2.3.35",
        "org.xerial.snappy:snappy-java:1.1.10.12", // CVE-2026-108106, -93451 (Kafka client)
        "at.yawk.lz4:lz4-java:1.11.4",             // CVE-2026-106451 (Kafka client)
        "commons-io:commons-io:2.22.0"             // CVE-2024-47554 (notification)
    )

    dependencies {
        "implementation"(platform(org.springframework.boot.gradle.plugin.SpringBootPlugin.BOM_COORDINATES))
        "testImplementation"(platform(org.springframework.boot.gradle.plugin.SpringBootPlugin.BOM_COORDINATES))
        "implementation"(platform("com.fasterxml.jackson:jackson-bom:$jacksonVersion"))
        "testImplementation"(platform("com.fasterxml.jackson:jackson-bom:$jacksonVersion"))
        patchedLibraries.forEach { coordinates ->
            if (coordinates.substringAfter(':').substringBefore(':').endsWith("-bom")) {
                "implementation"(platform(coordinates))
            } else {
                constraints { "implementation"(coordinates) }
            }
        }
        "compileOnly"("org.projectlombok:lombok")
        "annotationProcessor"("org.projectlombok:lombok")
        "testCompileOnly"("org.projectlombok:lombok")
        "testAnnotationProcessor"("org.projectlombok:lombok")
        "implementation"("org.jetbrains.kotlin:kotlin-reflect")
        // Health probes (container HEALTHCHECK, Kubernetes) and Prometheus metrics.
        "implementation"("org.springframework.boot:spring-boot-starter-actuator")
        "runtimeOnly"("io.micrometer:micrometer-registry-prometheus")
        "testImplementation"("org.springframework.boot:spring-boot-starter-test")
        "testRuntimeOnly"("com.h2database:h2")
    }

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
        kotlinOptions {
            freeCompilerArgs = listOf("-Xjsr305=strict")
            jvmTarget = "21"
        }
    }

    tasks.withType<Test> {
        useJUnitPlatform()
        // HU-34: the configuration is external and the secrets are mandatory.
        // Tests supply fictional values (never real credentials) so the Spring
        // context starts without an environment file.
        environment("DB_PASSWORD", "password")
        environment("LDAP_PASSWORD", "admin")
        environment("NEO4J_PASSWORD", "password")
        environment("JWT_SECRET", "test-jwt-secret-key-at-least-32-bytes-long")
        environment("QR_SECRET", "test-qr-secret-key-at-least-32-bytes-long")
        environment("VAULT_SECRET", "746573742d7365637265742d33322d63686172732d6c6f6e672d313233343536")
        environment("VAULT_SALT", "deadbeef")
        environment("VAULT_HASH_SALT", "12345678")
    }

    tasks.named<Test>("test") {
        exclude("**/*IT.class")
        // Benchmarks depend on the hardware, they run with performanceTest instead
        useJUnitPlatform {
            excludeTags("performance")
        }
        finalizedBy("jacocoTestReport")
    }

    if (path != ":services") {
        tasks.register<Test>("integrationTest") {
            description = "Runs integration tests tagged with 'integration'."
            group = "verification"

            val testSourceSet = project.extensions
                .getByType<SourceSetContainer>()
                .getByName("test")

            testClassesDirs = testSourceSet.output.classesDirs
            classpath = testSourceSet.runtimeClasspath

            useJUnitPlatform {
                includeTags("integration")
            }

            filter {
                isFailOnNoMatchingTests = false
            }

            dependsOn(tasks.named("testClasses"))
            shouldRunAfter(tasks.named("test"))
        }

        tasks.register<Test>("performanceTest") {
            description = "Runs performance benchmarks tagged with 'performance'."
            group = "verification"

            val testSourceSet = project.extensions
                .getByType<SourceSetContainer>()
                .getByName("test")

            testClassesDirs = testSourceSet.output.classesDirs
            classpath = testSourceSet.runtimeClasspath

            useJUnitPlatform {
                includeTags("performance")
            }

            filter {
                isFailOnNoMatchingTests = false
            }

            dependsOn(tasks.named("testClasses"))
        }
    }
    tasks.withType<JacocoReport> {
        reports {
            xml.required.set(true)
            html.required.set(true)
        }
    }

    if (path in coverageGatedServices) {
        tasks.named<org.gradle.testing.jacoco.tasks.JacocoCoverageVerification>(
            "jacocoTestCoverageVerification"
        ) {
            dependsOn("test")
            violationRules {
                rule {
                    limit {
                        counter = "LINE"
                        value = "COVEREDRATIO"
                        minimum = "0.60".toBigDecimal()
                    }
                }
            }
        }

        tasks.named("check") {
            dependsOn("jacocoTestCoverageVerification")
        }
    }
}
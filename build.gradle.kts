plugins {
    id("org.springframework.boot") version "3.2.4" apply false
    id("io.spring.dependency-management") version "1.1.4" apply false
    kotlin("jvm") version "1.9.24" apply false
    kotlin("plugin.spring") version "1.9.24" apply false
    kotlin("plugin.jpa") version "1.9.24" apply false
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
    apply(plugin = "java")
    apply(plugin = "org.jetbrains.kotlin.jvm")
    apply(plugin = "jacoco")
    extensions.configure<JavaPluginExtension> {
        toolchain {
            languageVersion.set(JavaLanguageVersion.of(21))
        }
    }

    dependencies {
        "implementation"(platform("org.springframework.boot:spring-boot-dependencies:3.2.4"))
        "testImplementation"(platform("org.springframework.boot:spring-boot-dependencies:3.2.4"))
        "compileOnly"("org.projectlombok:lombok")
        "annotationProcessor"("org.projectlombok:lombok")
        "testCompileOnly"("org.projectlombok:lombok")
        "testAnnotationProcessor"("org.projectlombok:lombok")
        "implementation"("org.jetbrains.kotlin:kotlin-reflect")
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
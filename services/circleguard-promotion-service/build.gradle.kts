plugins {
    id("org.springframework.boot")
    id("io.spring.dependency-management")
    kotlin("jvm")
    kotlin("plugin.spring")
    kotlin("plugin.jpa")
}

sourceSets {
    test {
        java.srcDir("../circleguard-form-service/src/main/java")
    }
}

dependencies {
    implementation(platform("org.springframework.boot:spring-boot-dependencies:3.2.4"))
    testImplementation(platform("org.springframework.boot:spring-boot-dependencies:3.2.4"))

    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-data-neo4j")
    implementation("org.springframework.boot:spring-boot-starter-data-redis")
    implementation("org.springframework.kafka:spring-kafka")
    implementation("org.springframework.boot:spring-boot-starter-cache")
    implementation("com.github.ben-manes.caffeine:caffeine")
    implementation("org.springframework.boot:spring-boot-starter-validation")
    implementation("org.springframework.boot:spring-boot-starter-security")
    implementation("io.jsonwebtoken:jjwt-api:0.11.5")
    runtimeOnly("io.jsonwebtoken:jjwt-impl:0.11.5")
    runtimeOnly("io.jsonwebtoken:jjwt-jackson:0.11.5")
    implementation("org.flywaydb:flyway-core")
    runtimeOnly("org.postgresql:postgresql")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.springframework.security:spring-security-test")
    // Testcontainers >= 1.20 ships docker-java that speaks Docker API >= 1.40.
    // Older 1.19.x pulls docker-java 3.3.6 (API 1.32), which modern Docker daemons reject:
    // "client version 1.32 is too old. Minimum supported API version is 1.40".
    testImplementation("org.testcontainers:junit-jupiter:1.21.4")
    testImplementation("org.testcontainers:postgresql:1.21.4")
    testImplementation("org.testcontainers:neo4j:1.21.4")
    testImplementation("org.testcontainers:kafka:1.21.4")
}

// Spring Boot's BOM manages testcontainers core to 1.19.x, which drags in docker-java
// 3.3.6 (Docker API 1.32) and breaks against modern daemons:
// "client version 1.32 is too old. Minimum supported API version is 1.40".
// Overriding the managed version here takes precedence over the imported Spring BOM.
dependencyManagement {
    imports {
        mavenBom("org.testcontainers:testcontainers-bom:1.21.4")
    }
    dependencies {
        dependency("org.testcontainers:testcontainers:1.21.4")
        dependency("org.testcontainers:junit-jupiter:1.21.4")
        dependency("org.testcontainers:postgresql:1.21.4")
        dependency("org.testcontainers:neo4j:1.21.4")
        dependency("org.testcontainers:kafka:1.21.4")
    }
}

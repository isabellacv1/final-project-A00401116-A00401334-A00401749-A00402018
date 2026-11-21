# syntax=docker/dockerfile:1.7

# ---------- Build stage ----------
FROM eclipse-temurin:21.0.13_9-jdk-jammy AS builder

WORKDIR /workspace

# Copy only the files needed to resolve the Gradle build first.
COPY gradlew gradlew.bat settings.gradle.kts build.gradle.kts ./
COPY gradle ./gradle
COPY services ./services

# Build only the identity service. Tests run separately, not during image build.
RUN --mount=type=cache,target=/root/.gradle,sharing=locked \
    chmod +x gradlew && \
    ./gradlew :services:circleguard-identity-service:bootJar \
      -x test --no-daemon --console=plain

# ---------- Runtime stage ----------
FROM eclipse-temurin:21.0.13_9-jre-jammy

RUN groupadd --system app && useradd --system --gid app --home-dir /app app

WORKDIR /app

COPY --from=builder --chown=app:app \
    /workspace/services/circleguard-identity-service/build/libs/*.jar \
    app.jar

USER app

EXPOSE 8083

# HU-28: the healthcheck asks Spring Boot whether the service can serve requests
# (/actuator/health/readiness, which includes its database, Redis or Neo4j), not
# just whether the port is open. The JRE image has bash but no curl, so the HTTP
# request goes through /dev/tcp. The answer is 200 when UP and 503 when DOWN.
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/8083 && printf "GET /actuator/health/readiness HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3 && head -n1 <&3 | grep -q " 200 "' || exit 1

# HU-28: an OutOfMemoryError leaves the JVM in an undefined state. Exiting lets the
# container restart policy start a clean process instead of keeping a broken one.
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-XX:+ExitOnOutOfMemoryError", "-jar", "/app/app.jar"]

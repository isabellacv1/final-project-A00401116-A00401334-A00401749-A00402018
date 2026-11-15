# syntax=docker/dockerfile:1.7

# ---------- Build stage ----------
FROM eclipse-temurin:21.0.8_9-jdk-jammy AS builder

WORKDIR /workspace

# Copy only the files needed to resolve the Gradle build first.
COPY gradlew gradlew.bat settings.gradle.kts build.gradle.kts ./
COPY gradle ./gradle
COPY services ./services

# Build only the file service. Tests run separately, not during image build.
RUN --mount=type=cache,target=/root/.gradle,sharing=locked \
    chmod +x gradlew && \
    ./gradlew :services:circleguard-file-service:bootJar \
      -x test --no-daemon --console=plain

# ---------- Runtime stage ----------
FROM eclipse-temurin:21.0.8_9-jre-jammy

RUN groupadd --system app && useradd --system --gid app --home-dir /app app

WORKDIR /app

COPY --from=builder --chown=app:app \
    /workspace/services/circleguard-file-service/build/libs/*.jar \
    app.jar

# FileStorageService creates ./uploads at startup; /app belongs to root, so the
# directory is created here and owned by the non-root user. Mount a volume on it
# to keep the files when the container is recreated.
RUN mkdir -p /app/uploads && chown app:app /app/uploads

USER app

EXPOSE 8085

# The JRE image includes bash, so we can probe the port without extra tools.
HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/8085' || exit 1

ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]

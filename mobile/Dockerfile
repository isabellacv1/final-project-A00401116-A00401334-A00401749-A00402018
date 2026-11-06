# syntax=docker/dockerfile:1.7
#
# Web build of the CircleGuard Expo app.
# Build context is the mobile/ folder:
#   docker build -t circleguard/web:1.0.0 mobile

# ---------- Build stage ----------
FROM node:22.21.1-alpine3.22 AS builder

WORKDIR /app

ENV CI=1 \
    EXPO_NO_TELEMETRY=1

# Install dependencies first so this layer is reused when only sources change.
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

COPY . .

# Static web export (HTML per route + hashed JS/CSS bundles) into /app/dist.
RUN npx expo export --platform web --output-dir dist

# ---------- Runtime stage ----------
FROM nginxinc/nginx-unprivileged:1.28.0-alpine3.21

COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --chmod=755 docker/40-env-config.sh /docker-entrypoint.d/40-env-config.sh

# Owned by the nginx user so the entrypoint script can rewrite env-config.js.
COPY --from=builder --chown=nginx:nginx /app/dist /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8080/ || exit 1

# ENTRYPOINT and CMD come from the base image: run /docker-entrypoint.d/*.sh,
# then start nginx in the foreground.

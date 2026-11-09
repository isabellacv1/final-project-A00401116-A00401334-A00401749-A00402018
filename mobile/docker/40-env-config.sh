#!/bin/sh
# Generates /env-config.js from environment variables at container start.
#
# The nginx image runs every script in /docker-entrypoint.d/ before starting
# nginx, so the same image can point at different backends per environment:
#   docker run -e AUTH_BASE_URL=https://auth.example.com circleguard/web
#
# Only variables that are set are written; the app falls back to its
# localhost defaults for the rest (see constants/Config.ts).
set -eu

TARGET="${ENV_CONFIG_PATH:-/usr/share/nginx/html/env-config.js}"

VARS="AUTH_BASE_URL DASHBOARD_BASE_URL FILE_BASE_URL FORM_BASE_URL GATEWAY_BASE_URL IDENTITY_BASE_URL NOTIFICATION_BASE_URL PROMOTION_BASE_URL"

{
  echo "// Generated at container start by 40-env-config.sh. Do not edit."
  echo "window.__ENV__ = {"
  for name in $VARS; do
    eval "value=\${$name:-}"
    if [ -n "$value" ]; then
      # Escape backslashes and double quotes so the value is a valid JS string.
      escaped=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
      echo "  \"$name\": \"$escaped\","
    fi
  done
  echo "};"
} > "$TARGET"

echo "40-env-config.sh: wrote runtime configuration to $TARGET"

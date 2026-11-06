// Runtime configuration for the web app.
//
// Left empty on purpose: constants/Config.ts falls back to the localhost
// defaults, which is what `expo start --web` needs during development.
//
// The Docker image overwrites this file at container start with the values of
// AUTH_BASE_URL, GATEWAY_BASE_URL, ... (see docker/40-env-config.sh).
window.__ENV__ = {};

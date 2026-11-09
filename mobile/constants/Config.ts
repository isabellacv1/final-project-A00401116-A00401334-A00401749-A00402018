/**
 * Global Configuration for CircleGuard Mobile.
 *
 * On web, service URLs can be supplied at runtime through `window.__ENV__`,
 * which is defined by `/env-config.js` (see `public/env-config.js`). The web
 * Docker image regenerates that file from environment variables every time
 * the container starts, so one image works in every environment.
 *
 * When a value is not supplied (native builds, `expo start`, static rendering
 * in Node), the localhost defaults below are used.
 */
type RuntimeEnv = Partial<Record<string, string>>;

const runtimeEnv: RuntimeEnv =
  (typeof window !== 'undefined' && (window as unknown as { __ENV__?: RuntimeEnv }).__ENV__) || {};

const fromEnv = (key: string, fallback: string): string => runtimeEnv[key] || fallback;

export const AUTH_BASE_URL = fromEnv('AUTH_BASE_URL', 'http://localhost:8180'); // Auth Service
export const DASHBOARD_BASE_URL = fromEnv('DASHBOARD_BASE_URL', 'http://localhost:8084'); // Dashboard Service
export const FILE_BASE_URL = fromEnv('FILE_BASE_URL', 'http://localhost:8085'); // File Service
export const FORM_BASE_URL = fromEnv('FORM_BASE_URL', 'http://localhost:8086'); // Form Service
export const GATEWAY_BASE_URL = fromEnv('GATEWAY_BASE_URL', 'http://localhost:8087'); // Gateway Service
export const IDENTITY_BASE_URL = fromEnv('IDENTITY_BASE_URL', 'http://localhost:8083'); // Identity Service
export const NOTIFICATION_BASE_URL = fromEnv('NOTIFICATION_BASE_URL', 'http://localhost:8082'); // Notification Service
export const PROMOTION_BASE_URL = fromEnv('PROMOTION_BASE_URL', 'http://localhost:8088'); // Promotion Service

// Gate validation (/api/v1/gate/validate) is served by the Gateway Service.
export const API_BASE_URL = GATEWAY_BASE_URL;

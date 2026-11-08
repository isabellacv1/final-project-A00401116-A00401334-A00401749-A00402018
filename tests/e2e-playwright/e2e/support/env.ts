const requiredEnv = (name: string): string => {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
};

export const getCredentials = (): { username: string; password: string } => ({
  username: requiredEnv('E2E_USERNAME'),
  password: requiredEnv('E2E_PASSWORD'),
});

export const getInvalidCredentials = (): { username: string; password: string } => {
  const { username, password } = getCredentials();
  return {
    username: process.env.E2E_INVALID_USERNAME?.trim() || `${username}_invalid`,
    password: process.env.E2E_INVALID_PASSWORD?.trim() || `${password}_invalid`,
  };
};

export const getAuthBaseUrl = (): string =>
  process.env.AUTH_BASE_URL?.trim() || 'http://localhost:8180';

export const getInvalidQrToken = (): string =>
  process.env.E2E_INVALID_QR_TOKEN?.trim() || 'invalid-or-expired-token';

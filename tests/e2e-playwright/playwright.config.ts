import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.BASE_URL ?? 'http://localhost:8081';

// The QR scanner needs the camera, and browsers only allow it in a secure context
// (https or localhost). In the pipeline the web app runs on http://<environment host>:8081,
// so that origin is treated as secure for the test browser only.
const insecureOrigin = new URL(baseURL).origin;
const secureOriginArgs = /^https:|\/\/(localhost|127\.0\.0\.1)(:|$)/.test(insecureOrigin)
  ? []
  : [`--unsafely-treat-insecure-origin-as-secure=${insecureOrigin}`];

export default defineConfig({
  testDir: './e2e/tests',
  timeout: 30_000,
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  reporter: [
    ['list'],
    ['html', { open: 'never' }],
    ['junit', { outputFile: 'results.xml' }],
  ],
  outputDir: 'test-results',
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    testIdAttribute: 'data-testid',
    permissions: ['camera'],
    launchOptions: {
      args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', ...secureOriginArgs],
    },
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});

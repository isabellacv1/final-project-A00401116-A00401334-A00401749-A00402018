import { test, expect } from '@playwright/test';
import { AccessPage } from '../pages/AccessPage';
import { LoginPage } from '../pages/LoginPage';
import { getAuthBaseUrl, getCredentials, getInvalidQrToken } from '../support/env';

test.describe('Suite E2E: Validación de acceso por QR', () => {
  test.beforeEach(async ({ page }) => {
    const credentials = getCredentials();
    const loginPage = new LoginPage(page);

    await loginPage.goto();
    await loginPage.login(credentials.username, credentials.password);
    await expect(page).toHaveURL(/\/$/);
  });

  test('Prueba 1: acepta un QR vigente', async ({ page, request }) => {
    const accessPage = new AccessPage(page);
    const jwt = await accessPage.getStoredJwt();

    if (!jwt) {
      throw new Error('No se encontró el JWT en localStorage después del login');
    }

    const qrResponse = await request.get(
      `${getAuthBaseUrl()}/api/v1/auth/qr/generate`,
      { headers: { Authorization: `Bearer ${jwt}` } },
    );
    expect(qrResponse.status()).toBe(200);

    const { qrToken } = await qrResponse.json();
    expect(typeof qrToken).toBe('string');

    await accessPage.useFakeQrScanner(qrToken);
    await accessPage.goto();
    await accessPage.unlockScanner();

    await expect(accessPage.accessGranted).toBeVisible();
    await expect(accessPage.welcomeMessage).toBeVisible();
  });

  test('Prueba 2: rechaza un QR inválido o expirado', async ({ page }) => {
    const accessPage = new AccessPage(page);

    await accessPage.useFakeQrScanner(getInvalidQrToken());
    await accessPage.goto();
    await accessPage.unlockScanner();

    await expect(accessPage.accessDenied).toBeVisible();
    await expect(accessPage.invalidTokenMessage).toBeVisible();
  });
});

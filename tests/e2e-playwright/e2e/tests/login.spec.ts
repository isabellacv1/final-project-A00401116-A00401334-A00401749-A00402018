import { test, expect } from '@playwright/test';
import { LoginPage } from '../pages/LoginPage';
import { HomePage } from '../pages/HomePage';
import { getCredentials, getInvalidCredentials } from '../support/env';

test.describe('Suite E2E: Login', () => {
  test('Prueba 1: inicia sesión con credenciales válidas y muestra el QR', async ({ page }) => {
    const credentials = getCredentials();
    const loginPage = new LoginPage(page);

    await loginPage.goto();
    await loginPage.login(credentials.username, credentials.password);

    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByText(/EXPIRES IN/).filter({ visible: true })).toBeVisible();
    const homePage = new HomePage(page);
    await expect(homePage.qrContainer).toBeVisible();
  });

  test('Prueba 2: muestra error y no navega con credenciales inválidas', async ({ page }) => {
    const credentials = getInvalidCredentials();
    const loginPage = new LoginPage(page);

    await loginPage.goto();
    const dialogPromise = page.waitForEvent('dialog');
    await loginPage.login(credentials.username, credentials.password);
    const dialog = await dialogPromise;

    expect(dialog.message()).toContain('Invalid username or password');
    await dialog.dismiss();
    await expect(page).toHaveURL(/\/login$/);
    await expect(loginPage.heading).toBeVisible();
  });
});

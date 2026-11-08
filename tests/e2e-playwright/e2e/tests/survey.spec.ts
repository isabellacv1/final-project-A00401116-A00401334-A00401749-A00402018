import { test, expect} from '@playwright/test';
import { LoginPage } from '../pages/LoginPage';
import { SurveyPage } from '../pages/SurveyPage';
import { getCredentials } from '../support/env';

test.describe('Suite E2E: Reporte de síntomas', () => {
  test.beforeEach(async ({ page }) => {
    const credentials = getCredentials();
    const loginPage = new LoginPage(page);

    await loginPage.goto();
    await loginPage.login(credentials.username, credentials.password);
    await expect(page).toHaveURL(/\/$/);
  });

  test('Prueba 1: envía los síntomas seleccionados y muestra la confirmación', async ({ page }) => {
    const surveyPage = new SurveyPage(page);

    await surveyPage.goto();
    await expect(surveyPage.heading).toBeVisible();
    await surveyPage.selectSymptom('fever');
    await surveyPage.selectSymptom('cough');

    const response = await surveyPage.submitAndWaitForResponse();
    expect(response.status()).toBe(200);

    const payload = JSON.parse(response.request().postData() ?? '{}');
    expect(payload.hasFever).toBe(true);
    expect(payload.hasCough).toBe(true);
    expect(payload.hasShortnessOfBreath).toBe(false);

    await expect(surveyPage.confirmationTitle).toBeVisible();
    await expect(surveyPage.confirmationMessage).toBeVisible();
  });
});

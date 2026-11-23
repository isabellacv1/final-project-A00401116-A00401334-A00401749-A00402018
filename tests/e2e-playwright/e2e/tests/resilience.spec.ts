import { test, expect } from '@playwright/test';
import { LoginPage } from '../pages/LoginPage';
import { SurveyPage } from '../pages/SurveyPage';
import { getCredentials } from '../support/env';

test.describe('Suite E2E: Resiliencia', () => {
  test.beforeEach(async ({ page }) => {
    const credentials = getCredentials();
    const loginPage = new LoginPage(page);

    await loginPage.goto();
    await loginPage.login(credentials.username, credentials.password);
    await expect(page).toHaveURL(/\/$/);
  });

  test('Prueba 1: ante HTTP 500 muestra el error al usuario y la UI sigue operativa', async ({ page }) => {
    const surveyPage = new SurveyPage(page);

    await surveyPage.goto();
    await expect(surveyPage.heading).toBeVisible();
    await surveyPage.selectSymptom('fever');

    await page.route('**/api/v1/surveys', async (route) => {
      if (route.request().method() === 'OPTIONS') {
        await route.continue();
        return;
      }

      await route.fulfill({
        status: 500,
        contentType: 'application/json',
        headers: { 'access-control-allow-origin': '*' },
        body: JSON.stringify({ message: 'forced failure' }),
      });
    });

    const responsePromise = page.waitForResponse(
      (candidate) =>
        candidate.url().endsWith('/api/v1/surveys') &&
        candidate.request().method() === 'POST',
    );
    // The alert is dismissed as soon as it opens. Playwright's click does not return while an
    // alert is open, so waiting for the click first and dismissing afterwards deadlocks when
    // the alert appears before the click finishes (same-origin API behind the Ingress: there is
    // no CORS preflight to delay the response).
    const dialogPromise = new Promise<{ type: string; message: string }>((resolve) => {
      page.once('dialog', async (dialog) => {
        const opened = { type: dialog.type(), message: dialog.message() };
        await dialog.dismiss();
        resolve(opened);
      });
    });
    await surveyPage.submit();
    const [response, dialog] = await Promise.all([responsePromise, dialogPromise]);

    expect(response.status()).toBe(500);
    expect(dialog.type).toBe('alert');
    expect(dialog.message).toBe(
      'Submission Failed: Could not reach the health gateway. Please try again.',
    );
    await expect(surveyPage.confirmationMessage).not.toBeVisible();
    await expect(surveyPage.heading).toBeVisible();
    await expect(surveyPage.confirmButton).toBeVisible();
    await surveyPage.selectSymptom('breathing');
    await expect(surveyPage.heading).toBeVisible();
  });
});

import type { Page, Locator, Response } from '@playwright/test';

type Symptom = 'fever' | 'cough' | 'breathing';

export class SurveyPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly feverOption: Locator;
  readonly coughOption: Locator;
  readonly breathingOption: Locator;
  readonly confirmButton: Locator;
  readonly confirmationTitle: Locator;
  readonly confirmationMessage: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByText('Symptom Report', { exact: true });
    this.feverOption = page.getByText('Fever / Chills', { exact: true });
    this.coughOption = page.getByText('Persistent Cough', { exact: true });
    this.breathingOption = page.getByText('Difficult Breathing', { exact: true });
    this.confirmButton = page.getByText('CONFIRM REPORT', { exact: true });
    this.confirmationTitle = page.getByText('STATUS: SUSPECT', { exact: true });
    this.confirmationMessage = page.getByText(
      'Based on your report, your campus access has been restricted to protect the community.',
      { exact: true },
    );
  }

  async goto(): Promise<void> {
    await this.page.goto('/report');
  }

  async selectSymptom(symptom: Symptom): Promise<void> {
    const options: Record<Symptom, Locator> = {
      fever: this.feverOption,
      cough: this.coughOption,
      breathing: this.breathingOption,
    };
    await options[symptom].click();
  }

  async submit(): Promise<void> {
    await this.confirmButton.click();
  }

  async submitAndWaitForResponse(): Promise<Response> {
    const [response] = await Promise.all([
      this.page.waitForResponse(
        (candidate) =>
          candidate.url().endsWith('/api/v1/surveys') &&
          candidate.request().method() === 'POST',
      ),
      this.submit(),
    ]);
    return response;
  }
}

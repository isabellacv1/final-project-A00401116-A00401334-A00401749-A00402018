import type { Page, Locator } from '@playwright/test';

export class HomePage {
  readonly qrContainer: Locator;

  constructor(page: Page) {
    this.qrContainer = page.getByTestId('home-qr-container').filter({ visible: true });
  }
}

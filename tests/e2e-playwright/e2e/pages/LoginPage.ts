import type { Page, Locator } from '@playwright/test';

export class LoginPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly usernameInput: Locator;
  readonly passwordInput: Locator;
  readonly signInButton: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByText('Welcome Back', { exact: true });
    this.usernameInput = page.getByTestId('login-username');
    this.passwordInput = page.getByTestId('login-password');
    this.signInButton = page.getByTestId('login-submit-button');
  }

  async goto(): Promise<void> {
    await this.page.goto('/login');
  }

  async login(username: string, password: string): Promise<void> {
    await this.usernameInput.fill(username);
    await this.passwordInput.fill(password);
    await this.signInButton.click();
  }
}

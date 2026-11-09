import type { Page, Locator } from '@playwright/test';

export class AccessPage {
  readonly page: Page;
  readonly scanContainer: Locator;
  readonly resultOverlay: Locator;
  readonly unlockButton: Locator;
  readonly accessGranted: Locator;
  readonly welcomeMessage: Locator;
  readonly accessDenied: Locator;
  readonly invalidTokenMessage: Locator;

  constructor(page: Page) {
    this.page = page;
    this.scanContainer = page.getByTestId('scan-container');
    this.resultOverlay = page.getByTestId('scan-result-overlay');
    this.unlockButton = this.scanContainer.getByText('UNLOCK SCANNER', { exact: true });
    this.accessGranted = this.resultOverlay.getByText('ACCESS GRANTED', { exact: true });
    this.welcomeMessage = this.resultOverlay.getByText('WELCOME TO CAMPUS', { exact: true });
    this.accessDenied = this.resultOverlay.getByText('ACCESS DENIED', { exact: true });
    this.invalidTokenMessage = this.resultOverlay.getByText('INVALID OR EXPIRED TOKEN', { exact: true });
  }

  async goto(): Promise<void> {
    await this.page.goto('/scan');
  }

  async unlockScanner(): Promise<void> {
    await this.unlockButton.click();
  }

  async getStoredJwt(): Promise<string | null> {
    return this.page.evaluate(() => localStorage.getItem('circleguard_token'));
  }

  async useFakeQrScanner(qrValue: string): Promise<void> {
    // Simulate the camera; QR validation still uses the real gateway.
    await this.page.addInitScript((value) => {
      // Synthetic camera stream: in CI there is no real camera and the scanner only runs the
      // detector once the <video> has frames, so a canvas stream is returned by getUserMedia.
      const canvas = document.createElement('canvas');
      canvas.width = 640;
      canvas.height = 480;
      const ctx = canvas.getContext('2d');
      let tick = 0;
      setInterval(() => {
        if (ctx) {
          ctx.fillStyle = tick++ % 2 ? '#222222' : '#333333';
          ctx.fillRect(0, 0, canvas.width, canvas.height);
        }
      }, 50);
      const stream = (canvas as HTMLCanvasElement & { captureStream(fps?: number): MediaStream }).captureStream(30);
      const fakeMediaDevices = {
        getUserMedia: async () => stream,
        enumerateDevices: async () => [
          { deviceId: 'fake-camera', kind: 'videoinput', label: 'Fake camera', groupId: 'fake', toJSON() { return this; } },
        ],
        getSupportedConstraints: () => ({ facingMode: true, width: true, height: true, deviceId: true }),
        addEventListener: () => undefined,
        removeEventListener: () => undefined,
      };
      Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: fakeMediaDevices });

      class FakeBarcodeDetector {
        static getSupportedFormats(): Promise<string[]> {
          return Promise.resolve(['qr_code']);
        }

        detect(): Promise<Array<Record<string, unknown>>> {
          return Promise.resolve([
            {
              rawValue: value,
              format: 'qr_code',
              boundingBox: { x: 0, y: 0, width: 32, height: 32 },
              cornerPoints: [],
            },
          ]);
        }
      }

      Object.defineProperty(window, 'BarcodeDetector', {
        configurable: true,
        writable: true,
        value: FakeBarcodeDetector,
      });
    }, qrValue);
  }
}

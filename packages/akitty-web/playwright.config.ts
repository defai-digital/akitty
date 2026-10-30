import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './browser',
  timeout: 30_000,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  workers: 1,
  use: { baseURL: 'http://127.0.0.1:4179', viewport: { width: 800, height: 600 }, trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } },
    { name: 'firefox', use: { browserName: 'firefox' } },
    { name: 'webkit', use: { browserName: 'webkit' } }],
  webServer: { command: 'npm run browser:serve', url: 'http://127.0.0.1:4179/browser/', reuseExistingServer: false },
})

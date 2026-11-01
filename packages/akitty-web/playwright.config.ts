import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { defineConfig, firefox } from '@playwright/test'

/**
 * Playwright's patched Firefox build cannot start on some macOS releases: it exits with "Could not find profile
 * folder" before any page loads (it fails even to create a fresh profile, while a release Firefox works). Only that
 * exact failure skips the Firefox project, only outside CI, and always with a warning; any other Firefox problem,
 * and every CI run, still fails the gate.
 */
function firefoxCannotStartHere(): boolean {
  if (process.env.CI) return false
  const profile = mkdtempSync(join(tmpdir(), 'akitty-firefox-probe-'))
  try {
    const probe = spawnSync(firefox.executablePath(), ['-headless', '-no-remote', '-CreateProfile', `probe ${profile}`], {
      encoding: 'utf8',
      timeout: 20_000,
    })
    return `${probe.stdout}${probe.stderr}`.includes('Could not find profile folder')
  } catch {
    return false
  } finally {
    rmSync(profile, { recursive: true, force: true })
  }
}

const skipFirefox = firefoxCannotStartHere()
if (skipFirefox) {
  console.warn(
    '\n[akitty-web] WARNING: Playwright Firefox cannot start on this machine ("Could not find profile folder").' +
      '\n[akitty-web] Firefox browser tests are SKIPPED locally; they still run, and are required, in CI.\n'
  )
}

export default defineConfig({
  testDir: './browser',
  timeout: 30_000,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  workers: 1,
  use: { baseURL: 'http://127.0.0.1:4179', viewport: { width: 800, height: 600 }, trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } },
    ...(skipFirefox ? [] : [{ name: 'firefox', use: { browserName: 'firefox' as const } }]),
    { name: 'webkit', use: { browserName: 'webkit' } }],
  webServer: { command: 'npm run browser:serve', url: 'http://127.0.0.1:4179/browser/', reuseExistingServer: false },
})

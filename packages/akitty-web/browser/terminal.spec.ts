import { expect, test } from '@playwright/test'

// Assertions inspect real canvas pixels, so they work across OS font rasterizers
// without accepting an unreviewed platform screenshot as a golden baseline.
test.beforeEach(async ({ page }) => {
  await page.goto('/browser/')
  await page.waitForFunction(() => 'fixture' in window)
})

test('ANSI backgrounds, Unicode glyphs and erase reach the actual canvas', async ({ page }, info) => {
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  await page.evaluate(async () => {
    const f = (window as any).fixture
    await f.write('\x1b[?25l\x1b[48;2;255;0;0m        \x1b[0m\r\n\x1b[48;2;0;0;255m        \x1b[0m\r\nASCII 中 e\u0301 😀')
  })
  await expect.poll(() => page.evaluate(() => (window as any).fixture.pixels())).toMatchObject({ red: expect.any(Number) })
  const pixels = await page.evaluate(() => (window as any).fixture.pixels())
  expect(pixels.red).toBeGreaterThan(1000)
  expect(pixels.blue).toBeGreaterThan(1000)
  expect(pixels.white).toBeGreaterThan(50)
  expect((await page.evaluate(() => (window as any).fixture.lines())).join('\n')).toContain('ASCII 中')
  await info.attach('unicode-and-colors', { body: await page.locator('canvas').screenshot(), contentType: 'image/png' })
  await page.evaluate(() => (window as any).fixture.write('\x1b[0m\x1b[2J\x1b[H'))
  await expect.poll(() => page.evaluate(() => (window as any).fixture.pixels())).toMatchObject({ red: 0, blue: 0, white: 0 })
  expect(errors).toEqual([])
})

test('keyboard input and resize survive repeated reset and disposal', async ({ page }, info) => {
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  for (let round = 0; round < 12; round++) {
    await page.evaluate(async () => {
      const f = (window as any).fixture
      f.recreate(); f.terminal.resize(40, 10)
      await f.write('\x1b[?25lready 中')
      f.terminal.reset()
      await f.write('\x1b[?25lfresh')
      f.input.length = 0; f.terminal.focus()
    })
    await page.keyboard.type('hello')
    await expect.poll(() => page.evaluate(() => (window as any).fixture.input.join(''))).toBe('hello')
    expect(await page.locator('canvas').count()).toBe(1)
    expect((await page.evaluate(() => (window as any).fixture.lines()))[0]).toBe('fresh')
    expect((await page.evaluate(() => (window as any).fixture.pixels())).white).toBeGreaterThan(30)
  }
  await info.attach('after-lifecycle-cycles', { body: await page.locator('canvas').screenshot(), contentType: 'image/png' })
  expect(errors).toEqual([])
})

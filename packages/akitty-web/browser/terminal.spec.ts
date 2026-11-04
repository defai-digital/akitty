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
  await page.evaluate(() => (window as any).fixture.write('\x1b[?5h'))
  await expect.poll(() => page.evaluate(() => {
    const pixels = (window as any).fixture.pixels()
    return pixels.white / (pixels.width * pixels.height)
  })).toBeGreaterThan(0.95)
  await page.evaluate(() => (window as any).fixture.write('\x1b[?5l'))
  await expect.poll(() => page.evaluate(() => (window as any).fixture.pixels().white)).toBe(0)
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

test('Home, End and Alt input follow the terminal modes and preserve shifted text', async ({ page }) => {
  await page.evaluate(async () => {
    const f = (window as any).fixture
    await f.write('\x1b[?1h\x1b[?1036h')
    f.input.length = 0
    f.terminal.focus()
  })
  await page.keyboard.press('Home')
  await page.keyboard.press('End')
  await page.keyboard.press('Alt+Shift+KeyA')
  expect(await page.evaluate(() => (window as any).fixture.input)).toEqual(['\x1bOH', '\x1bOF', '\x1bA'])

  await page.evaluate(async () => {
    const f = (window as any).fixture
    await f.write('\x1b[?1l\x1b[?1036l')
    f.input.length = 0
  })
  await page.keyboard.press('Home')
  await page.keyboard.press('End')
  await page.keyboard.press('Alt+KeyA')
  expect(await page.evaluate(() => (window as any).fixture.input)).toEqual(['\x1b[H', '\x1b[F', 'a'])
})


test('hidden synchronized output flushes title and replies on the host deadline', async ({ page }) => {
  await page.locator('#terminal').evaluate(element => { (element as HTMLElement).style.display = 'none' })
  await expect(page.locator('#terminal')).toBeHidden()
  await page.evaluate(() => {
    const f = (window as any).fixture
    f.input.length = 0
    f.terminal.write('\x1b[?2026hhidden\x1b]2;pending\x07\x1b[6n')
    if (f.terminal.title !== '' || f.input.length !== 0) throw new Error('synchronized output escaped early')
  })
  await expect.poll(() => page.evaluate(() => (window as any).fixture.input)).toEqual(['\x1b[1;7R'])
  expect(await page.evaluate(() => (window as any).fixture.terminal.title)).toBe('pending')
  await page.locator('#terminal').evaluate(element => { (element as HTMLElement).style.display = '' })
  await expect.poll(() => page.evaluate(() => (window as any).fixture.pixels().white)).toBeGreaterThan(30)
  expect((await page.evaluate(() => (window as any).fixture.lines()))[0]).toBe('hidden')
})

test('SGR mouse down, drag and release preserve modifiers', async ({ page }) => {
  await page.evaluate(() => {
    const f = (window as any).fixture
    f.terminal.write('\x1b[?1002h\x1b[?1006h')
    f.input.length = 0
  })
  const canvas = await page.locator('canvas').boundingBox()
  if (!canvas) throw new Error('missing canvas')
  const x = canvas.x + canvas.width / 32 * 2.5
  const y = canvas.y + canvas.height / 8 * 1.5
  await page.mouse.move(x, y)
  await page.keyboard.down('Control')
  await page.mouse.down()
  await page.mouse.move(x + canvas.width / 32, y)
  await page.mouse.up()
  await page.keyboard.up('Control')
  const input = await page.evaluate(() => (window as any).fixture.input)
  expect(input).toEqual(['\x1b[<16;3;2M', '\x1b[<48;4;2M', '\x1b[<16;4;2m'])
})

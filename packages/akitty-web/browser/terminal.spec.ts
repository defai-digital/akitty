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
    f.terminal.write('\x1b[?2026;25hhidden\x1b]2;pending\x07\x1b[6n')
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


test('runtime theme changes recolor the canvas and modified editing keys reach the host', async ({ page }, info) => {
  await page.evaluate(async () => {
    const f = (window as any).fixture
    await f.write('\x1b[?25l\x1b[31mred\x1b[0m\r\nplain')
    f.terminal.options.theme = { foreground: '#00ff00', background: '#0000ff', red: '#ff0000' }
    f.input.length = 0
    f.terminal.focus()
  })
  await expect.poll(() => page.evaluate(() => (window as any).fixture.pixels().blue)).toBeGreaterThan(1000)
  expect((await page.evaluate(() => (window as any).fixture.pixels())).red).toBeGreaterThan(10)
  expect((await page.evaluate(() => (window as any).fixture.lines())).slice(0, 2)).toEqual(['red', 'plain'])
  await page.keyboard.press('Control+Alt+KeyC')
  await page.keyboard.press('Control+Enter')
  expect(await page.evaluate(() => (window as any).fixture.input)).toEqual(['\x1b\x03', '\r'])
  await info.attach('runtime-theme', { body: await page.locator('canvas').screenshot(), contentType: 'image/png' })
})


test('idle cursor pixels stay stable and OSC cursor colors reach the canvas', async ({ page }) => {
  const sample = () => page.evaluate(() => {
    const canvas = document.querySelector('canvas')!
    return Array.from(canvas.getContext('2d')!.getImageData(1, 1, 1, 1).data).slice(0, 3)
  })
  const initial = await page.evaluate(() => {
    const t = (window as any).fixture.terminal
    t.write('\x1b[2J\x1b[H\x1b[?25h')
    t.renderer.render(t.wasmTerm, true, 0, t, 0)
    const canvas = document.querySelector('canvas')!
    return Array.from(canvas.getContext('2d')!.getImageData(1, 1, 1, 1).data).slice(0, 3)
  })
  await page.evaluate(async () => { for (let i = 0; i < 12; i++) await new Promise(requestAnimationFrame) })
  expect(await sample()).toEqual(initial)
  await page.evaluate(() => (window as any).fixture.write('\x1b[2;1HX\x1b[H'))
  expect(await sample()).toEqual(initial)
  await page.evaluate(() => (window as any).fixture.write('\x1b]12;#ff0000\x07'))
  await expect.poll(sample).toEqual([initial[0], 0, 0])
  await page.evaluate(() => (window as any).fixture.write('\x1b]112\x07'))
  await expect.poll(sample).toEqual(initial)
})


test('Unicode URLs remain complete and activate from the trailing wide column', async ({ page }) => {
  const uri = 'https://example.test/中é😀'
  await page.evaluate(async value => {
    const f = (window as any).fixture
    ;(window as any).opened = []
    window.open = url => { (window as any).opened.push(String(url)); return null }
    await f.write('go ' + value + ' tail')
  }, uri)
  const point = await page.evaluate(() => {
    const t = (window as any).fixture.terminal
    const canvas = document.querySelector('canvas')!.getBoundingClientRect()
    const metrics = t.renderer.getMetrics()
    return { x: canvas.left + metrics.width * 28.5, y: canvas.top + metrics.height * 0.5 }
  })
  const modifier = process.platform === 'darwin' ? 'Meta' : 'Control'
  await page.keyboard.down(modifier)
  await page.mouse.click(point.x, point.y)
  await page.keyboard.up(modifier)
  await expect.poll(() => page.evaluate(() => (window as any).opened)).toEqual([uri])
})

test('dragging from a wide spacer copies and highlights the whole glyph', async ({ page }) => {
  const points = await page.evaluate(async () => {
    const f = (window as any).fixture, t = f.terminal
    t.resize(4, 3)
    t.options.theme = { background: '#000000', foreground: '#ffffff', selectionBackground: '#ff0000' }
    await f.write('\x1b[?25la中b')
    const bounds = document.querySelector('canvas')!.getBoundingClientRect(), metrics = t.renderer.getMetrics()
    return { start: { x: bounds.left + metrics.width * 2.5, y: bounds.top + metrics.height * 0.5 },
      end: { x: bounds.left + metrics.width * 3.5, y: bounds.top + metrics.height * 0.5 } }
  })
  await page.mouse.move(points.start.x, points.start.y)
  await page.mouse.down()
  await page.mouse.move(points.end.x, points.end.y)
  // Hold across multiple auto-scroll ticks at the scrollback boundary.
  await page.evaluate(() => new Promise(resolve => setTimeout(resolve, 150)))
  await page.mouse.up()
  expect(await page.evaluate(() => (window as any).fixture.terminal.getSelection())).toBe('中b')
  await expect.poll(() => page.evaluate(() => {
    const canvas = document.querySelector('canvas')!, context = canvas.getContext('2d')!
    return [1, 2].map(col => Array.from(context.getImageData(Math.floor(canvas.width / 4 * (col + 0.5)),
      Math.floor(canvas.height / 3 * 0.95), 1, 1).data).slice(0, 3))
  })).toEqual([[255, 0, 0], [255, 0, 0]])
  await page.evaluate(async () => {
    const f = (window as any).fixture
    f.terminal.reset()
    await f.write('ab  cd')
    f.terminal.select(0, 0, 6)
  })
  expect(await page.evaluate(() => (window as any).fixture.terminal.getSelection())).toBe('ab  cd')
})

test('keyboard event-only mode reports repeats and releases and F3 is unambiguous', async ({ page }) => {
  await page.evaluate(() => {
    const f = (window as any).fixture
    f.terminal.write('\x1b[=2u')
    f.input.length = 0
    f.terminal.focus()
  })
  await page.keyboard.down('ArrowLeft')
  await page.keyboard.down('ArrowLeft')
  await page.keyboard.up('ArrowLeft')
  expect(await page.evaluate(() => (window as any).fixture.input)).toEqual(['\x1b[D', '\x1b[1;1:2D', '\x1b[1;1:3D'])
  await page.evaluate(() => {
    const f = (window as any).fixture
    f.terminal.write('\x1b[=1u')
    f.input.length = 0
  })
  await page.keyboard.press('Control+F3')
  expect(await page.evaluate(() => (window as any).fixture.input)).toEqual(['\x1b[13;5~'])
  await page.evaluate(() => {
    const f = (window as any).fixture
    f.terminal.write('\x1b[=10u')
    f.input.length = 0
  })
  await page.keyboard.down('Shift')
  await page.keyboard.up('Shift')
  expect(await page.evaluate(() => (window as any).fixture.input)).toEqual(['\x1b[57441;2u', '\x1b[57441;1:3u'])
})

test('host shortcuts and custom key handlers keep their releases out of enhanced terminal input', async ({ page }) => {
  await page.evaluate(() => {
    const f = (window as any).fixture
    f.terminal.write('\x1b[=10u')
    f.terminal.attachCustomKeyEventHandler((event: KeyboardEvent) => event.code === 'KeyP')
    f.input.length = 0
    f.terminal.focus()
    const input = document.querySelector('textarea')!
    for (const modifiers of [{ ctrlKey: true }, { metaKey: true }]) {
      input.dispatchEvent(new KeyboardEvent('keydown', { code: 'KeyV', key: 'v', bubbles: true, ...modifiers }))
      input.dispatchEvent(new KeyboardEvent('keyup', { code: 'KeyV', key: 'v', bubbles: true }))
    }
  })
  await page.keyboard.press('p')
  expect(await page.evaluate(() => (window as any).fixture.input)).toEqual([])
  await page.evaluate(() => {
    const f = (window as any).fixture
    f.terminal.write('\x1b[=1u')
  })
  await page.keyboard.press('Control+Alt+v')
  expect(await page.evaluate(() => (window as any).fixture.input)).toEqual(['\x1b[118;7u'])
})

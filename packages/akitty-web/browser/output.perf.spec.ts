import { expect, test } from '@playwright/test'

test.skip(process.env.AKITTY_BROWSER_PERF !== '1', 'benchmark')

test('cooperative output timing probe', async ({ page }) => {
  await page.goto('/browser/')
  await page.waitForFunction(() => 'fixture' in window)
  const samples = []
  for (const mode of ['sync', 'async', 'async', 'sync', 'sync', 'async'] as const) {
    const sample = await page.evaluate(async mode => {
      const f = (window as any).fixture
      f.recreate(); f.terminal.resize(120, 40)
      await new Promise(resolve => requestAnimationFrame(resolve))
      const pattern = '\x1b[?1049h\x1b[H\x1b[2Jalternate screen 中\x1b[2;1Hsecond row\x1b[?1049lmain\r\n'
      const bytes = new TextEncoder().encode(pattern.repeat(16000))
      const calls: number[] = [], gaps: number[] = []
      const engine = f.terminal.wasmTerm, write = engine.write.bind(engine)
      engine.write = (...args: any[]) => {
        const start = performance.now()
        try { return write(...args) } finally { calls.push(performance.now() - start) }
      }
      let last = performance.now()
      const timer = setInterval(() => { const now = performance.now(); gaps.push(now - last); last = now }, 1)
      let elapsed: number
      try {
        await new Promise(resolve => setTimeout(resolve, 8))
        last = performance.now()
        const start = last
        if (mode === 'sync') f.terminal.write(bytes)
        else await f.terminal.writeAsync(bytes)
        elapsed = performance.now() - start
        await new Promise(resolve => setTimeout(resolve, 8))
      } finally { clearInterval(timer); engine.write = write }
      f.terminal.write('\x1b[2J\x1b[HOUTPUT_DONE')
      return { mode, bytes: bytes.length, elapsed_ms: elapsed!, maximum_engine_call_ms: Math.max(...calls),
        maximum_heartbeat_gap_ms: Math.max(...gaps), heartbeat_count: gaps.length, last_line: f.lines()[0] }
    }, mode)
    expect(sample.last_line).toBe('OUTPUT_DONE')
    samples.push(sample)
  }
  console.log(`OUTPUT_PERF ${JSON.stringify(samples)}`)
})

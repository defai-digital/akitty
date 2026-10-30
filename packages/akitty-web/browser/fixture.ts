import { Ghostty, Terminal } from '../lib/index'

const ghostty = await Ghostty.load('/ghostty-vt.wasm')
const parent = document.querySelector<HTMLElement>('#terminal')!
let terminal: Terminal
const input: string[] = []
function create() {
  terminal = new Terminal({ ghostty, cols: 32, rows: 8, fontSize: 18, cursorBlink: false,
    theme: { background: '#000000', foreground: '#ffffff', cursor: '#ffffff' } })
  terminal.open(parent)
  terminal.onData(data => input.push(data))
}
create()
Object.assign(window, { fixture: {
  get terminal() { return terminal }, input,
  recreate() { terminal.dispose(); create() },
  async write(text: string) {
    await new Promise<void>(resolve => terminal.write(text, resolve))
    await new Promise(requestAnimationFrame)
    await new Promise(requestAnimationFrame)
  },
  pixels() {
    const canvas = parent.querySelector('canvas')!
    const pixels = canvas.getContext('2d')!.getImageData(0, 0, canvas.width, canvas.height).data
    let red = 0, blue = 0, white = 0
    for (let i = 0; i < pixels.length; i += 4) {
      if (pixels[i]! > 200 && pixels[i + 1]! < 30 && pixels[i + 2]! < 30) red++
      if (pixels[i]! < 30 && pixels[i + 1]! < 30 && pixels[i + 2]! > 200) blue++
      if (pixels[i]! > 180 && pixels[i + 1]! > 180 && pixels[i + 2]! > 180) white++
    }
    return { red, blue, white, width: canvas.width, height: canvas.height }
  },
  lines() { return Array.from({ length: terminal.rows }, (_, row) => terminal.buffer.active.getLine(row)?.translateToString(true) ?? '') },
} })

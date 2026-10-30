// Fuzzy ranking adapted from AX TUI's CommandRegistry.search (MIT).
// Copyright (c) 2025 opentui; Copyright (c) 2026 DEFAI Digital.
// See third_party/ax-tui/NOTICE.md and LICENSE.
export interface Command {
  id: string
  title: string
  shortcut: string
  keywords: readonly string[]
}
export const commands: readonly Command[] = Object.freeze([
  { id: "new-window", title: "New Window", shortcut: "⌘N", keywords: ["terminal", "shell"] },
  { id: "new-tab", title: "New Tab", shortcut: "⌘T", keywords: ["terminal", "shell"] },
  { id: "split", title: "Split Pane", shortcut: "⌘D", keywords: ["vertical", "side by side"] },
  { id: "close-pane", title: "Close Pane", shortcut: "⌘W", keywords: ["close", "shell"] },
  { id: "copy", title: "Copy Selection", shortcut: "⌘C", keywords: ["clipboard"] },
  { id: "paste", title: "Paste Text", shortcut: "⌘V", keywords: ["clipboard"] },
  { id: "find", title: "Find in Scrollback", shortcut: "⌘F", keywords: ["search", "history"] },
  { id: "find-next", title: "Find Next", shortcut: "⌘G", keywords: ["search", "next"] },
  { id: "find-previous", title: "Find Previous", shortcut: "⌘⇧G", keywords: ["search", "previous"] },
  { id: "font-increase", title: "Increase Font Size", shortcut: "⌘+", keywords: ["zoom", "larger"] },
  { id: "font-decrease", title: "Decrease Font Size", shortcut: "⌘−", keywords: ["zoom", "smaller"] },
  { id: "font-reset", title: "Reset Font Size", shortcut: "⌘0", keywords: ["zoom", "default"] },
])
function plainLine(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ").trim()
}
export function listCommands(query: string): string {
  if (typeof query !== "string" || query.length > 512) throw new RangeError("Invalid palette query")
  const needle = Array.from(plainLine(query).normalize("NFKC").toLowerCase()).slice(0, 128)
  const ranked: { command: Command; score: number; index: number }[] = []
  for (const [index, command] of commands.entries()) {
    const haystack = Array.from([command.title, command.id, ...command.keywords].join(" ").normalize("NFKC").toLowerCase())
    let cursor = 0
    let score = 0
    let matches = true
    for (const character of needle) {
      const found = haystack.indexOf(character, cursor)
      if (found < 0) { matches = false; break }
      score += found - cursor
      cursor = found + 1
    }
    // A contiguous match (e.g. the keyword "side by side") outranks any scattered subsequence match.
    if (matches && needle.length > 0 && haystack.join("").includes(needle.join(""))) score -= 1000
    if (matches) ranked.push({ command, score, index })
  }
  ranked.sort((a, b) => a.score - b.score || a.index - b.index)
  return JSON.stringify({ version: 1, commands: ranked.map(({ command }) => command) })
}

/** Plain URL detection with an explicit UTF-16-to-cell coordinate map. */
import { cellChar } from '../codepoint';
import type { ILink, ILinkProvider } from '../types';

interface Line { length: number; getCell(column: number): { getCodepoint(): number } | undefined }
export interface ITerminalForUrlProvider { buffer: { active: { getLine(row: number): Line | undefined } } }

export class UrlRegexProvider implements ILinkProvider {
  constructor(private readonly host: ITerminalForUrlProvider) {}
  provideLinks(row: number, callback: (links: ILink[] | undefined) => void): void {
    const line = this.host.buffer.active.getLine(row);
    if (!line) { callback(undefined); return; }
    let source = '';
    const columns: number[] = [];
    for (let column = 0; column < line.length; column++) {
      const value = line.getCell(column)?.getCodepoint() ?? 0;
      const glyph = value < 32 ? ' ' : cellChar(value);
      source += glyph;
      for (let unit = 0; unit < glyph.length; unit++) columns.push(column);
    }
    const results: ILink[] = [];
    const pattern = /(?:(?:https?|ftp|ssh|git|gemini|gopher):\/\/|(?:mailto|tel|magnet|news):)[^\s<>"'`]+/gi;
    for (const match of source.matchAll(pattern)) {
      const destination = match[0].replace(/[.,;!?)\]]+$/, '');
      const scheme = /^(?:[a-z]+:\/\/|[a-z]+:)/i.exec(destination)?.[0] ?? '';
      if (destination.length <= scheme.length) continue;
      const start = match.index!;
      results.push({ text: destination, range: { start: { x: columns[start], y: row },
        end: { x: columns[start + destination.length - 1], y: row } },
        activate: event => { if (event.ctrlKey || event.metaKey) window.open(destination, '_blank', 'noopener,noreferrer'); } });
    }
    callback(results.length ? results : undefined);
  }
  dispose(): void {}
}

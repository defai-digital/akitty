/**
 * OSC 8 Hyperlink Provider
 *
 * Detects hyperlinks created with OSC 8 escape sequences and resolves each
 * link's URI by cell coordinate from the wasm engine.
 *
 * OSC 8 format: \x1b]8;;URL\x07TEXT\x1b]8;;\x07
 *
 * Cell hyperlink ids are page-local. Same-row identity uses both id and URI,
 * while multi-row ranges continue only through soft-wrap boundaries, with URI
 * matching across pages. Distinct sequences and hard newlines stay separate.
 */

import type { IBufferRange, ILink, ILinkProvider } from '../types';

/** Cell shape the provider needs from a buffer line. */
interface IHyperlinkCell {
  getHyperlinkId(): number;
}

export class OSC8LinkProvider implements ILinkProvider {
  constructor(private terminal: ITerminalForOSC8Provider) {}

  /**
   * Provide all OSC 8 links on the given row
   * Note: This may return links that span multiple rows
   */
  provideLinks(y: number, callback: (links: ILink[] | undefined) => void): void {
    const links: ILink[] = [];

    const line = this.terminal.buffer.active.getLine(y);
    if (!line) {
      callback(undefined);
      return;
    }

    // Walk the row left to right. Each resolved link consumes its whole span
    // on this row, so a run cannot be re-entered and no visited set is needed.
    let x = 0;
    while (x < line.length) {
      const cell = line.getCell(x);
      if (!cell || cell.getHyperlinkId() === 0) {
        x++;
        continue;
      }

      const uri = this.uriAt(y, x);
      if (!uri) {
        // A linked cell whose URI cannot be read yields no link (fail closed).
        x++;
        continue;
      }

      const range = this.findLinkRange(y, x, uri, cell.getHyperlinkId());
      const rowEndX = range.end.y === y ? range.end.x : line.length - 1;
      links.push({
        text: uri,
        range,
        activate: (event) => {
          // Open link if Ctrl/Cmd is pressed
          if (event.ctrlKey || event.metaKey) {
            window.open(uri, '_blank', 'noopener,noreferrer');
          }
        },
      });
      x = rowEndX + 1;
    }

    callback(links.length > 0 ? links : undefined);
  }

  /**
   * Find the full extent of a link. The starting row uses both hyperlink id and
   * URI so separate same-URI sequences stay distinct. Other rows join only at
   * genuine soft-wrap boundaries; ids may differ between pages.
   */
  private findLinkRange(startY: number, startX: number, uri: string, hyperlinkId: number): IBufferRange {
    const buffer = this.terminal.buffer.active;

    let minY = startY;
    let minX = startX;
    while (minX > 0) {
      const line = buffer.getLine(minY);
      if (!line) break;
      if (!this.cellMatches(line.getCell(minX - 1), minY, minX - 1, uri, hyperlinkId)) break;
      minX--;
    }

    if (minX === 0 && minY > 0 && buffer.getLine(minY)?.isWrapped) {
      let prevY = minY - 1;
      while (prevY >= 0) {
        const prevLine = buffer.getLine(prevY);
        if (!prevLine || prevLine.length === 0) break;

        const lastX = prevLine.length - 1;
        if (!this.cellMatches(prevLine.getCell(lastX), prevY, lastX, uri)) break;

        minY = prevY;
        minX = lastX;
        while (minX > 0) {
          if (!this.cellMatches(prevLine.getCell(minX - 1), prevY, minX - 1, uri)) break;
          minX--;
        }

        if (minX === 0) {
          if (!buffer.getLine(minY)?.isWrapped) break;
          prevY--;
        } else {
          break;
        }
      }
    }

    let maxY = startY;
    let maxX = startX;
    const currentLine = buffer.getLine(maxY);
    if (currentLine) {
      while (maxX < currentLine.length - 1) {
        if (!this.cellMatches(currentLine.getCell(maxX + 1), maxY, maxX + 1, uri, hyperlinkId)) break;
        maxX++;
      }

      if (maxX === currentLine.length - 1) {
        let nextY = maxY + 1;
        const maxBuffer = buffer.length;
        while (nextY < maxBuffer) {
          const nextLine = buffer.getLine(nextY);
          if (!nextLine || nextLine.length === 0 || !nextLine.isWrapped) break;
          if (!this.cellMatches(nextLine.getCell(0), nextY, 0, uri)) break;

          maxY = nextY;
          maxX = 0;
          while (maxX < nextLine.length - 1) {
            if (!this.cellMatches(nextLine.getCell(maxX + 1), nextY, maxX + 1, uri)) break;
            maxX++;
          }

          if (maxX === nextLine.length - 1) {
            nextY++;
          } else {
            break;
          }
        }
      }
    }

    return {
      start: { x: minX, y: minY },
      end: { x: maxX, y: maxY },
    };
  }

  /** True when a cell matches the URI and, on the starting row, the sequence id. */
  private cellMatches(
    cell: IHyperlinkCell | undefined,
    bufferY: number,
    x: number,
    uri: string,
    hyperlinkId?: number
  ): boolean {
    if (!cell || cell.getHyperlinkId() === 0) return false;
    if (hyperlinkId !== undefined && cell.getHyperlinkId() !== hyperlinkId) return false;
    return this.uriAt(bufferY, x) === uri;
  }

  /**
   * Read the URI of the cell at buffer coordinates (bufferY, x): absolute
   * buffer rows (scrollback first), matching buffer.active.
   */
  private uriAt(bufferY: number, x: number): string | null {
    const wasm = this.terminal.wasmTerm;
    if (!wasm) return null;
    const scrollback = wasm.isAlternateScreen() ? 0 : wasm.getScrollbackLength();
    return bufferY < scrollback
      ? wasm.getHyperlinkUri(bufferY, x, true)
      : wasm.getHyperlinkUri(bufferY - scrollback, x, false);
  }

  dispose(): void {
    // No resources to clean up
  }
}

/**
 * Minimal terminal interface required by OSC8LinkProvider
 */
export interface ITerminalForOSC8Provider {
  buffer: {
    active: {
      length: number;
      getLine(y: number):
        | {
            readonly length: number;
            readonly isWrapped: boolean;
            getCell(x: number): IHyperlinkCell | undefined;
          }
        | undefined;
    };
  };
  wasmTerm?: {
    /**
     * URI of the cell at (row, col): viewport row, or scrollback offset
     * (0 = oldest) when isScrollback is true. Null when the cell has no
     * hyperlink or the URI cannot be read.
     */
    getHyperlinkUri(row: number, col: number, isScrollback?: boolean): string | null;
    getScrollbackLength(): number;
    isAlternateScreen(): boolean;
  };
}

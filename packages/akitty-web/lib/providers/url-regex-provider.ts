/**
 * URL Regex Link Provider
 *
 * Detects plain text URLs using regex pattern matching.
 * Supports common protocols but excludes file paths.
 *
 * This provider runs after OSC8LinkProvider, so explicit hyperlinks
 * take precedence over regex-detected URLs.
 */

import { cellChar } from '../codepoint';
import type { IBufferRange, ILink, ILinkProvider } from '../types';

/**
 * URL Regex Provider
 *
 * Detects plain text URLs on a single line using regex.
 * Does not support multi-line URLs or file paths.
 *
 * Supported protocols:
 * - https://, http://
 * - mailto:
 * - ftp://, ssh://, git://
 * - tel:, magnet:
 * - gemini://, gopher://, news:
 */
export class UrlRegexProvider implements ILinkProvider {
  /**
   * URL regex pattern
   * Matches common protocols followed by valid URL characters
   * Excludes file paths (no ./ or ../ or bare /)
   */
  private static readonly URL_REGEX =
    /(https?:\/\/|mailto:|ftp:\/\/|ssh:\/\/|git:\/\/|tel:|magnet:|gemini:\/\/|gopher:\/\/|news:)[\w\-.~:\/?#@!$&*+,;=%]+/gi;

  /**
   * Characters to strip from end of URLs
   * Common punctuation that's unlikely to be part of the URL
   */
  private static readonly TRAILING_PUNCTUATION = /[.,;!?)\]]+$/;

  constructor(private terminal: ITerminalForUrlProvider) {}

  /**
   * Provide all regex-detected URLs on the given row
   */
  provideLinks(y: number, callback: (links: ILink[] | undefined) => void): void {
    const links: ILink[] = [];

    const line = this.terminal.buffer.active.getLine(y);
    if (!line) {
      callback(undefined);
      return;
    }

    // Convert line cells to text, keeping the cell column for every text index
    const { text: lineText, cellByTextIndex } = this.lineToText(line);

    // Reset regex state (global flag maintains state)
    UrlRegexProvider.URL_REGEX.lastIndex = 0;

    // Find all URL matches in the line
    let match: RegExpExecArray | null = UrlRegexProvider.URL_REGEX.exec(lineText);
    while (match !== null) {
      let url = match[0];
      const startIndex = match.index;
      let endIndex = startIndex + url.length - 1; // Inclusive end

      // Strip trailing punctuation
      const stripped = url.replace(UrlRegexProvider.TRAILING_PUNCTUATION, '');
      if (stripped.length < url.length) {
        url = stripped;
        endIndex = startIndex + url.length - 1;
      }

      // Regex offsets are UTF-16 code-unit indices, but link ranges are cell
      // columns; the two diverge after astral codepoints (two UTF-16 code units
      // in a single cell, and one UTF-16 code unit per spacer cell).
      const startX = cellByTextIndex[startIndex] ?? startIndex;
      const endX = cellByTextIndex[endIndex] ?? endIndex;

      // Require a destination after the scheme, including after stripping punctuation.
      if (url.length > match[1].length) {
        links.push({
          text: url,
          range: {
            start: { x: startX, y },
            end: { x: endX, y },
          },
          activate: (event) => {
            // Open link if Ctrl/Cmd is pressed
            if (event.ctrlKey || event.metaKey) {
              window.open(url, '_blank', 'noopener,noreferrer');
            }
          },
        });
      }

      // Get next match
      match = UrlRegexProvider.URL_REGEX.exec(lineText);
    }

    callback(links.length > 0 ? links : undefined);
  }

  /**
   * Convert a buffer line to plain text and record the cell column that
   * produced every UTF-16 index in that text.
   *
   * One cell contributes its codepoint's text: a single UTF-16 code unit for
   * BMP characters, two for astral codepoints. Null, missing, control, and
   * otherwise-invalid cells each contribute one space. The per-index mapping
   * is what lets regex match offsets (UTF-16 indices) be translated back to
   * cell columns.
   */
  private lineToText(line: IBufferLineForUrlProvider): {
    text: string;
    cellByTextIndex: number[];
  } {
    const chars: string[] = [];
    const cellByTextIndex: number[] = [];

    for (let x = 0; x < line.length; x++) {
      const cell = line.getCell(x);
      const codepoint = cell ? cell.getCodepoint() : 0;
      // Empty and control cells read as one space. cellChar guards the rest
      // (negative, surrogate, and above U+10FFFF raw values), so an invalid
      // codepoint still contributes exactly one space instead of throwing.
      const char = codepoint === 0 || codepoint < 32 ? ' ' : cellChar(codepoint);

      chars.push(char);
      // Astral codepoints are a surrogate pair, so both code units map to the
      // same cell column.
      for (let unit = 0; unit < char.length; unit++) {
        cellByTextIndex.push(x);
      }
    }

    return { text: chars.join(''), cellByTextIndex };
  }

  dispose(): void {
    // No resources to clean up
  }
}

/**
 * Minimal terminal interface required by UrlRegexProvider
 */
export interface ITerminalForUrlProvider {
  buffer: {
    active: {
      getLine(y: number): IBufferLineForUrlProvider | undefined;
    };
  };
}

/**
 * Minimal buffer line interface for URL detection
 */
interface IBufferLineForUrlProvider {
  length: number;
  getCell(x: number):
    | {
        getCodepoint(): number;
      }
    | undefined;
}

/**
 * Link detection and caching system
 *
 * The LinkDetector coordinates between multiple link providers and caches
 * results for performance. It uses hyperlink_id for intelligent caching
 * since the same hyperlink_id always represents the same link.
 */

import type { IBufferCellPosition, ILink, ILinkProvider } from './types';

/** Sentinel returned by a cancelled provider step. */
const ABORTED = { aborted: true } as const;

type ScanDeferred = { promise: Promise<void>; resolve: () => void };

type PendingScan = {
  generation: number;
  // Row stamp and change stamp captured when the scan started.
  rowStamp: number;
  startChange: number;
  promise: Promise<void>;
  cancel: () => void;
};

function createDeferred(): ScanDeferred {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => { resolve = r; });
  return { promise, resolve };
}

/**
 * Manages link detection across multiple providers with intelligent caching
 */
export class LinkDetector {
  private providers: ILinkProvider[] = [];
  private isDisposed = false;

  // Cache links by hyperlink_id for fast lookups
  // Key format: `h${hyperlinkId}` for OSC 8 links
  // Key format: `r${row}:${startX}-${endX}` for regex links (future)
  private linkCache = new Map<string, ILink>();

  // Rows whose provider scan completed for the current generation only.
  private scannedRows = new Set<number>();

  // In-flight provider scans keyed by row. Concurrent lookups share one entry
  // so a single provider call serves every caller waiting on that row.
  private inFlight = new Map<number, PendingScan>();

  // Bumped by every full invalidation (invalidateCache/dispose). Every cached
  // row and in-flight scan from an older generation is discarded wholesale.
  private generation = 0;

  // Monotonic row-change counter. invalidateRows advances it and records the
  // new value on each affected row, so a scan can tell whether an invalidation
  // landed on a row it touched after it started.
  private changeStamp = 0;
  private rowInvalidated = new Map<number, number>();

  // Terminal instance for buffer access
  constructor(private terminal: ITerminalForLinkDetector) {}

  /**
   * Register a link provider
   */
  registerProvider(provider: ILinkProvider): void {
    this.providers.push(provider);
    this.invalidateCache(); // New provider may detect different links
  }

  /**
   * Get link at the specified buffer position
   * @param col Column (0-based)
   * @param row Absolute row in buffer (0-based)
   * @returns Link at position, or undefined if none
   */
  async getLinkAt(col: number, row: number): Promise<ILink | undefined> {
    if (this.isDisposed) return undefined;
    // First, check if this cell has a hyperlink_id (fast path for OSC 8)
    const line = this.terminal.buffer.active.getLine(row);
    if (!line || col < 0 || col >= line.length) {
      return undefined;
    }

    const cell = line.getCell(col);
    if (!cell) {
      return undefined;
    }
    const hyperlinkId = cell.getHyperlinkId();

    if (hyperlinkId > 0) {
      // Fast path: check cache by hyperlink_id
      const cacheKey = `h${hyperlinkId}`;
      if (this.linkCache.has(cacheKey)) {
        return this.linkCache.get(cacheKey);
      }
    }

    // Slow path: scan this row once. Concurrent callers share the same
    // in-flight scan, so everyone awaits the same provider work.
    if (!this.scannedRows.has(row)) {
      const generation = this.generation;
      const rowStamp = this.rowStamp(row);
      await this.getOrStartScan(row);
      // A full invalidation, or a change to this row, landed while the scan
      // ran; its results were discarded and must not surface here. Untouched
      // rows keep their results.
      if (
        this.isDisposed ||
        generation !== this.generation ||
        rowStamp !== this.rowStamp(row)
      ) {
        return undefined;
      }
    }

    // Check cache again (hyperlinkId or position-based)
    if (hyperlinkId > 0) {
      const cacheKey = `h${hyperlinkId}`;
      const link = this.linkCache.get(cacheKey);
      if (link) return link;
    }

    // Check if any cached link contains this position
    for (const link of this.linkCache.values()) {
      if (this.isPositionInLink(col, row, link)) {
        return link;
      }
    }

    return undefined;
  }

  /**
   * Return the in-flight scan for a row, or start one. A scan from an older
   * generation or row stamp is already doomed, so it is never shared.
   */
  private getOrStartScan(row: number): Promise<void> {
    const rowStamp = this.rowStamp(row);
    const existing = this.inFlight.get(row);
    if (existing && existing.generation === this.generation && existing.rowStamp === rowStamp) {
      return existing.promise;
    }
    existing?.cancel();

    const generation = this.generation;
    const startChange = this.changeStamp;
    const abort = createDeferred();
    const pending: PendingScan = {
      generation,
      rowStamp,
      startChange,
      promise: Promise.resolve(),
      cancel: abort.resolve,
    };
    pending.promise = this.scanRow(row, pending, abort.promise).finally(() => {
      abort.resolve();
      if (this.inFlight.get(row) === pending) {
        this.inFlight.delete(row);
      }
    });
    this.inFlight.set(row, pending);
    return pending.promise;
  }

  /**
   * Scan a row for links using all registered providers, in registration order.
   * Results are published only while the scan's snapshot is still current and
   * none of its links reach into a row invalidated after the scan started.
   */
  private async scanRow(row: number, scan: PendingScan, abort: Promise<void>): Promise<void> {
    const allLinks: ILink[] = [];

    // Query all providers
    for (const provider of this.providers) {
      if (this.isScanStale(row, scan)) return;

      const links = await this.provideLinksOrAbort(provider, row, abort);
      if (links === ABORTED || this.isScanStale(row, scan)) return;
      if (Array.isArray(links)) {
        allLinks.push(...links);
      }
    }

    // Re-check just before publishing: an invalidation that raced the last
    // provider must not be overwritten by stale results. A multi-line link
    // discovered from an untouched row can still depend on invalidated rows.
    if (this.isScanStale(row, scan) || this.spansInvalidatedRow(allLinks, scan.startChange)) {
      return;
    }

    // Cache all discovered links
    for (const link of allLinks) {
      this.cacheLink(link);
    }

    // Only a fully completed scan counts as scanned.
    this.scannedRows.add(row);
  }

  /** True when the scan's generation or its own row stamp moved under it. */
  private isScanStale(row: number, scan: PendingScan): boolean {
    return (
      this.isDisposed ||
      scan.generation !== this.generation ||
      scan.rowStamp !== this.rowStamp(row)
    );
  }

  /**
   * True when any discovered link covers a row invalidated after the scan
   * started. Publishing such a link would expose stale multi-line content.
   */
  private spansInvalidatedRow(links: ILink[], startChange: number): boolean {
    if (this.rowInvalidated.size === 0) return false;
    for (const { range } of links) {
      for (let row = range.start.y; row <= range.end.y; row++) {
        if (this.rowStamp(row) > startChange) return true;
      }
    }
    return false;
  }

  /** Last change stamp that invalidated this row (0 when never invalidated). */
  private rowStamp(row: number): number {
    return this.rowInvalidated.get(row) ?? 0;
  }

  /**
   * Await one provider call, or bail out as soon as the scan is cancelled.
   */
  private provideLinksOrAbort(
    provider: ILinkProvider,
    row: number,
    abort: Promise<void>,
  ): Promise<ILink[] | undefined | typeof ABORTED> {
    const links = new Promise<ILink[] | undefined>((resolve) => {
      provider.provideLinks(row, resolve);
    });
    return Promise.race([links, abort.then(() => ABORTED)]);
  }

  /**
   * Cache a link for fast lookup
   */
  private cacheLink(link: ILink): void {
    // Try to get hyperlink_id for this link
    const { start } = link.range;
    const line = this.terminal.buffer.active.getLine(start.y);
    if (line) {
      const cell = line.getCell(start.x);
      if (!cell) {
        // Fallback: cache by position range
        const { start: s, end: e } = link.range;
        const cacheKey = `r${s.y}:${s.x}-${e.x}`;
        this.linkCache.set(cacheKey, link);
        return;
      }
      const hyperlinkId = cell.getHyperlinkId();

      if (hyperlinkId > 0) {
        // Cache by hyperlink_id (best case - stable across rows)
        this.linkCache.set(`h${hyperlinkId}`, link);
        return;
      }
    }

    // Fallback: cache by position range
    // Format: r${row}:${startX}-${endX}
    const { start: s, end: e } = link.range;
    const cacheKey = `r${s.y}:${s.x}-${e.x}`;
    this.linkCache.set(cacheKey, link);
  }

  /**
   * Check if a position is within a link's range
   */
  private isPositionInLink(col: number, row: number, link: ILink): boolean {
    const { start, end } = link.range;

    // Check if row is in range
    if (row < start.y || row > end.y) {
      return false;
    }

    // Single-line link
    if (start.y === end.y) {
      return col >= start.x && col <= end.x;
    }

    // Multi-line link
    if (row === start.y) {
      return col >= start.x; // First line: from start.x to end of line
    } else if (row === end.y) {
      return col <= end.x; // Last line: from start of line to end.x
    } else {
      return true; // Middle line: entire line is part of link
    }
  }

  /**
   * Invalidate cache when terminal content changes
   * Should be called on terminal write, resize, or clear
   */
  invalidateCache(): void {
    this.generation += 1;
    // The generation bump already dooms pre-existing scans; row stamps from the
    // old generation can never be newer than a future scan's start stamp.
    this.rowInvalidated.clear();
    this.linkCache.clear();
    this.scannedRows.clear();
    this.cancelAllScans();
  }

  /**
   * Invalidate cache for specific rows
   * Used when only part of the terminal changed
   */
  invalidateRows(startRow: number, endRow: number): void {
    this.changeStamp += 1;
    const stamp = this.changeStamp;

    const affected = new Set<number>();
    for (let row = startRow; row <= endRow; row++) affected.add(row);

    // Remove cached links in this range.
    // This is conservative - we remove any link that touches these rows.
    for (const [key, link] of this.linkCache) {
      const { start, end } = link.range;
      if (
        (start.y >= startRow && start.y <= endRow) ||
        (end.y >= startRow && end.y <= endRow) ||
        (start.y < startRow && end.y > endRow)
      ) {
        this.linkCache.delete(key);
        // A removed multi-line link may have been discovered while scanning a
        // row outside the invalidated range; those rows must rescan too.
        for (let row = start.y; row <= end.y; row++) affected.add(row);
      }
    }

    // Cancel only the scans whose row actually changed. Untouched in-flight
    // scans keep running and may publish; their links are checked at publish
    // time in case they reach into an affected row.
    for (const row of affected) {
      this.rowInvalidated.set(row, stamp);
      this.scannedRows.delete(row);
      const pending = this.inFlight.get(row);
      if (pending) {
        this.inFlight.delete(row);
        pending.cancel();
      }
    }
  }

  /**
   * Cancel every in-flight scan. Pending lookups observe the generation change
   * and resolve without returning stale links, so no lookup can hang on a
   * provider that will never call back.
   */
  private cancelAllScans(): void {
    const pendingScans = [...this.inFlight.values()];
    this.inFlight.clear();
    for (const scan of pendingScans) {
      scan.cancel();
    }
  }

  /**
   * Dispose and cleanup
   */
  dispose(): void {
    if (this.isDisposed) return;
    this.isDisposed = true;
    this.generation += 1;
    this.rowInvalidated.clear();
    this.linkCache.clear();
    this.scannedRows.clear();
    this.cancelAllScans();

    // Dispose all providers
    const failures: unknown[] = [];
    for (const provider of this.providers) {
      try { provider.dispose?.(); } catch (error) { failures.push(error); }
    }
    this.providers = [];
    if (failures.length) throw failures[0];
  }
}

/**
 * Minimal terminal interface required by LinkDetector
 * Keeps coupling low and testing easy
 */
export interface ITerminalForLinkDetector {
  buffer: {
    active: {
      getLine(y: number):
        | {
            length: number;
            getCell(x: number):
              | {
                  getHyperlinkId(): number;
                }
              | undefined;
          }
        | undefined;
    };
  };
}

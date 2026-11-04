import type { IDisposable, IEvent } from './interfaces';

function reportListenerError(error: unknown): void {
  if (typeof globalThis.reportError === 'function') {
    globalThis.reportError(error);
  } else {
    queueMicrotask(() => {
      throw error;
    });
  }
}

export class EventEmitter<T> {
  private listeners: Array<{ listener: (arg: T) => void }> = [];

  fire(arg: T): void {
    // Snapshot so a listener removing itself cannot shift iteration past its
    // successor, and listeners added during dispatch never see the current event.
    const listeners = this.listeners.slice();
    // A throwing listener (e.g. a host IPC channel already closed) must not abort the caller midway
    // through a write or keypress, nor starve the listeners after it; report it asynchronously instead.
    for (const { listener } of listeners) {
      try {
        listener(arg);
      } catch (error) {
        reportListenerError(error);
      }
    }
  }

  event: IEvent<T> = (listener) => {
    // A callback can be subscribed more than once; each disposable owns one entry.
    const entry = { listener };
    this.listeners.push(entry);
    return {
      dispose: () => {
        const index = this.listeners.indexOf(entry);
        if (index >= 0) {
          this.listeners.splice(index, 1);
        }
      },
    };
  };

  dispose(): void {
    this.listeners = [];
  }
}

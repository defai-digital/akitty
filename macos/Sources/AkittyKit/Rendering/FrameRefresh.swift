import Foundation

/// Coalesces automatic refreshes while retaining one trailing update. The interval
/// is re-evaluated when a deadline fires, so focus/visibility changes take effect.
@MainActor final class FrameRefresh {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private let now: () -> TimeInterval
    private let interval: () -> TimeInterval
    private let schedule: Scheduler
    private let perform: () -> Void
    private var last: TimeInterval = -.infinity
    private var deadline: TimeInterval?
    private var cancellation: (() -> Void)?
    private var generation: UInt64 = 0
    private var stopped = false

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         interval: @escaping () -> TimeInterval, schedule: Scheduler? = nil, perform: @escaping () -> Void) {
        self.now = now; self.interval = interval; self.perform = perform
        self.schedule = schedule ?? { delay, operation in
            let item = DispatchWorkItem(block: operation)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }
    }
    func request() {
        guard !stopped else { return }
        let time = now(), delay = max(0, interval() - (time - last))
        if delay == 0 {
            cancelPending(); last = time; perform(); return
        }
        let next = time + delay
        if let deadline, deadline <= next { return }
        cancelPending()
        deadline = next
        let token = generation
        cancellation = schedule(delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.generation == token else { return }
                self.cancellation = nil; self.deadline = nil
                self.request()
            }
        }
    }
    func invalidate() { stopped = true; cancelPending() }
    private func cancelPending() {
        generation &+= 1
        cancellation?(); cancellation = nil; deadline = nil
    }
}

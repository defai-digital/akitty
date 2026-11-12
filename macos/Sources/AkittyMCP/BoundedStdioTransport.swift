import Foundation
import Darwin
import Logging
import MCP

/// Newline framing with bounded input and queue; protocol semantics belong to the MCP SDK.
actor BoundedStdioTransport: Transport {
    nonisolated let logger = Logger(label: "akitty.mcp", factory: { _ in SwiftLogNoOpLogHandler() })
    static let messageLimit = 65_536
    private let input: Int32
    private let output: Int32
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var reader: Task<Void, Never>?
    private var connected = false
    private var oldFlags: [(Int32, Int32)] = []
    private let writer: StdioWriter

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.input = input; self.output = output
        writer = StdioWriter(output: output)
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        stream = pair.stream; continuation = pair.continuation
    }
    func connect() async throws {
        for fd in [input, output] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                await disconnect(); throw MCPError.internalError("Cannot configure MCP stdio.")
            }
            oldFlags.append((fd, flags))
        }
        connected = true
        reader = Task { await readLoop() }
    }
    func disconnect() async {
        connected = false; reader?.cancel(); reader = nil
        continuation.finish()
        writer.stop()
        await writer.drain()
        for (fd, flags) in oldFlags { _ = fcntl(fd, F_SETFL, flags) }
        oldFlags.removeAll()
    }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }

    private func readLoop() async {
        var buffer = [UInt8](repeating: 0, count: 4096), pending = Data()
        do {
            while connected && !Task.isCancelled {
                let count = Darwin.read(input, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { try await Task.sleep(for: .milliseconds(10)); continue }
                    throw MCPError.internalError("MCP input failed.")
                }
                for byte in buffer.prefix(count) {
                    if byte == 10 {
                        if !pending.isEmpty {
                            guard case .enqueued = continuation.yield(pending) else { throw MCPError.internalError("MCP input queue exceeded.") }
                            pending = Data()
                        }
                    } else {
                        guard pending.count < Self.messageLimit else { throw MCPError.invalidRequest("MCP message exceeds 64 KiB.") }
                        pending.append(byte)
                    }
                }
            }
            // An unterminated final message must never dispatch on EOF.
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }

    func send(_ data: Data) async throws {
        guard connected else { throw MCPError.internalError("MCP disconnected.") }
        do { try await writer.send(data) }
        catch {
            // A failed partial frame cannot be followed by another valid JSON line.
            await disconnect()
            throw error
        }
    }
}

/// Only this actor writes stdout, so partial frames cannot interleave. Its blocking
/// poll never occupies the reader actor; shutdown interrupts it within one poll slice.
private actor StdioWriter {
    private let output: Int32
    private nonisolated let state = WriterState()
    init(output: Int32) { self.output = output }
    nonisolated func stop() { state.stop() }
    func drain() {}
    func send(_ data: Data) throws {
        var frame = data; frame.append(10)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var offset = 0
        while offset < frame.count {
            try Task.checkCancellation()
            guard !state.stopped, ProcessInfo.processInfo.systemUptime < deadline else { throw MCPError.internalError("MCP output stopped or timed out. Dispatch outcome may be unknown; do not automatically retry.") }
            var readiness = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
            let remaining = min(50, max(1, Int32(ceil((deadline - ProcessInfo.processInfo.systemUptime) * 1000))))
            let ready = Darwin.poll(&readiness, 1, remaining)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw MCPError.internalError("MCP output failed. Dispatch outcome may be unknown; do not automatically retry.") }
            if ready == 0 { continue }
            let count = frame.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), frame.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            else { throw MCPError.internalError("MCP output closed. Dispatch outcome may be unknown; do not automatically retry.") }
        }
    }
}

private final class WriterState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func stop() { lock.lock(); value = true; lock.unlock() }
}

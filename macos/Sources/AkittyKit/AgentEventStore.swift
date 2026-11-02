import Foundation
import CryptoKit
import Darwin

/// Private, bounded local metadata. Hashes redact command text; they are not attestations or tamper protection.
/// Every file operation runs on one serial queue: `append` waits for its write (callers that need the record on disk
/// before continuing), `appendLater` does not (the periodic recorder, which must not do file I/O on the main thread),
/// `appendDurably` is the asynchronous form of `append`, and `export` waits behind any queued writes, so readers
/// always see everything recorded before them.
final class AgentEventStore: @unchecked Sendable {
    let directory: URL
    let segmentLimit: Int
    private let instance = UUID().uuidString
    private var sequence: UInt64 = 0
    private var writerLock: FileHandle?
    private let queue = DispatchQueue(label: "com.defai.akitty.agent-events")
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Akitty/agent-events"), segmentLimit: Int = 4 * 1_048_576) {
        self.directory = directory; self.segmentLimit = max(4096, segmentLimit)
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw AkittyError.core("Event directory must be owned by you with mode 0700 and cannot be a symlink.") }
    }
    private func openFile(_ url: URL, writing: Bool) throws -> (Int32, Int) {
        // Reject FIFOs at fstat without first blocking in open waiting for a peer.
        let fd = Darwin.open(url.path, (writing ? O_RDWR | O_CREAT | O_APPEND : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw AkittyError.core("Cannot open private event file.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size <= segmentLimit else {
            Darwin.close(fd); throw AkittyError.core("Unsafe or oversized event file.")
        }
        return (fd, Int(info.st_size))
    }
    func append(event: String, session: String, provenance: String, fields: [String: Any] = [:], synchronize: Bool = false) throws {
        try queue.sync { try write(event: event, session: session, provenance: provenance, fields: fields, synchronize: synchronize) }
    }
    /// `append(synchronize: true)` without blocking the caller's thread on the fsync: the record is on disk
    /// before the call returns, its queue position is kept, and a failure is thrown to the awaiting caller.
    func appendDurably(event: String, session: String, provenance: String, fields: [String: Any] = [:]) async throws {
        let fields = UncheckedFields(value: fields)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.write(event: event, session: session, provenance: provenance, fields: fields.value, synchronize: true)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// Queues an unsynchronized append and returns at once; a failure is reported to `failed` on the main queue.
    func appendLater(event: String, session: String, provenance: String, fields: [String: Any] = [:], failed: @escaping @MainActor (String) -> Void) {
        let fields = UncheckedFields(value: fields)
        queue.async {
            do { try self.write(event: event, session: session, provenance: provenance, fields: fields.value, synchronize: false) }
            catch { let message = error.localizedDescription; DispatchQueue.main.async { failed(message) } }
        }
    }
    private struct UncheckedFields: @unchecked Sendable { let value: [String: Any] }
    private func write(event: String, session: String, provenance: String, fields: [String: Any], synchronize: Bool) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try prepare()
        if writerLock == nil {
            let (lock, _) = try openFile(directory.appendingPathComponent("writer.lock"), writing: true)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lock); throw AkittyError.core("Another AkiTTY instance owns event recording.") }
            writerLock = FileHandle(fileDescriptor: lock, closeOnDealloc: true)
        }
        sequence += 1
        let object: [String: Any] = ["version": 1, "instance": instance, "sequence": sequence,
            "time_ms": Int64(Date().timeIntervalSince1970 * 1000), "session": session,
            "event": event, "provenance": provenance, "fields": fields]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10)
        guard data.count <= 8192, data.count + 512 <= segmentLimit else { throw AkittyError.core("Event exceeds its storage limit.") }
        let current = directory.appendingPathComponent("events.jsonl"), previous = directory.appendingPathComponent("previous.jsonl")
        let (fd, size) = try openFile(current, writing: true)
        if size > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, off_t(size - 1)) == 1 else { Darwin.close(fd); throw AkittyError.core("Cannot inspect event tail.") }
            if last != 10 {
                // A crash or short write may leave one incomplete JSON line. Never join a new event onto it.
                var tail = [UInt8](repeating: 0, count: min(size, 8193))
                let read = pread(fd, &tail, tail.count, off_t(size - tail.count))
                guard read == tail.count else { Darwin.close(fd); throw AkittyError.core("Cannot read incomplete event tail.") }
                let retained = tail.lastIndex(of: 10).map { size - tail.count + $0 + 1 } ?? 0
                guard ftruncate(fd, off_t(retained)) == 0 else { Darwin.close(fd); throw AkittyError.core("Cannot recover incomplete event tail.") }
                Darwin.close(fd); sequence -= 1
                try write(event: "incomplete_record_dropped", session: session, provenance: "host", fields: ["dropped_bytes": size - retained], synchronize: false)
                return try write(event: event, session: session, provenance: provenance, fields: fields, synchronize: synchronize)
            }
        }
        Darwin.close(fd)
        // Admission reserves enough room for one bounded retention marker. Do not reserve
        // those bytes again here: an admitted large event would otherwise rotate forever
        // after the marker is written, eventually overflowing the recorder's stack.
        if size + data.count > segmentLimit {
            if FileManager.default.fileExists(atPath: previous.path) {
                let (old, _) = try openFile(previous, writing: false); Darwin.close(old)
                try FileManager.default.removeItem(at: previous)
            }
            try FileManager.default.moveItem(at: current, to: previous)
            sequence -= 1
            try write(event: "retention_rotated", session: "host", provenance: "host", fields: ["older_segments_may_be_missing": true], synchronize: false)
            return try write(event: event, session: session, provenance: provenance, fields: fields, synchronize: synchronize)
        }
        let (output, _) = try openFile(current, writing: true)
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        if synchronize { try handle.synchronize() }
        try handle.close()
        if synchronize {
            // File fsync alone does not commit a newly created or rotated directory entry.
            let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw AkittyError.core("Cannot open event directory for synchronization.") }
            defer { Darwin.close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw AkittyError.core("Cannot synchronize event directory.") }
        }
    }
    func export() throws -> Data {
        try queue.sync(execute: read)
    }
    private func read() throws -> Data {
        try prepare()
        var result = Data()
        for name in ["previous.jsonl", "events.jsonl"] {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let (fd, _) = try openFile(file, writing: false)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var bytes = Data()
            while bytes.count <= segmentLimit {
                let chunk = try handle.read(upToCount: min(65_536, segmentLimit + 1 - bytes.count)) ?? Data()
                if chunk.isEmpty { break }; bytes.append(chunk)
            }
            try handle.close()
            guard bytes.count <= segmentLimit else { throw AkittyError.core("Event segment grew beyond its limit.") }
            result.append(bytes)
        }
        return result
    }
}

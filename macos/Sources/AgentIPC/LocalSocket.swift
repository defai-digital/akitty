import Foundation
import Darwin

public enum AgentIPCError: Error, LocalizedError {
    case failure(String)
    public var errorDescription: String? { if case let .failure(message) = self { return message }; return nil }
}

/// A bounded, request-only local transport. Peer credentials identify an OS account/process, not an agent brand.
public enum LocalSocket {
    public static let frameLimit = 16_384
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Akitty/agent/requests.sock").path
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentIPCError.failure("Local socket path is too long or invalid.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var value = try address(path)
        return withUnsafePointer(to: &value) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
    static func configure(_ fd: Int32, timeout: Int) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw AgentIPCError.failure("Cannot protect local socket descriptor.") }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw AgentIPCError.failure("Cannot configure local socket signal handling.") }
        var value = timeval(tv_sec: timeout, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw AgentIPCError.failure("Cannot bound local socket I/O.") }
    }
    static func descriptor() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentIPCError.failure("Cannot create local socket.") }
        do { try configure(fd, timeout: 3) } catch { Darwin.close(fd); throw error }
        return fd
    }
    public static func request(_ data: Data, path: String = defaultPath) throws -> Data {
        let fd = try descriptor(); defer { Darwin.close(fd) }
        guard try withAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else { throw AgentIPCError.failure("Cannot connect. Enable Local Agent Requests in the running AkiTTY app.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw AgentIPCError.failure("Local server is not owned by your OS account.") }
        try configure(fd, timeout: 135)
        try writeFrame(data, to: fd)
        return try readFrame(from: fd)
    }
    static func readExact(_ count: Int, from fd: Int32, deadline: TimeInterval) throws -> Data {
        var data = Data(count: count), offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw AgentIPCError.failure("Local frame deadline expired.") }
                var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&readiness, 1, Int32(max(1, ceil(remaining * 1000))))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw AgentIPCError.failure("Local frame deadline expired.") }
                let read = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw AgentIPCError.failure("Local connection closed or timed out. Dispatch outcome may be unknown; do not retry automatically.") }
                offset += read
            }
        }
        return data
    }
    public static func readFrame(from fd: Int32, timeout: TimeInterval = 135) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 135 else { throw AgentIPCError.failure("Invalid local frame timeout.") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let header = try readExact(4, from: fd, deadline: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= frameLimit else { throw AgentIPCError.failure("Invalid local request size.") }
        return try readExact(count, from: fd, deadline: deadline)
    }
    public static func writeFrame(_ data: Data, to fd: Int32) throws {
        guard !data.isEmpty, data.count <= frameLimit else { throw AgentIPCError.failure("Local frame exceeds 16 KiB.") }
        var size = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(data)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < frame.count {
                let sent = send(fd, bytes.baseAddress!.advanced(by: offset), frame.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw AgentIPCError.failure("Local response failed. Dispatch outcome may be unknown; do not retry automatically.") }
                offset += sent
            }
        }
    }
}

public struct LocalPeer: @unchecked Sendable {
    public let uid: uid_t
    public let pid: pid_t
    private let descriptor: Int32
    private let enabled: () -> Bool
    fileprivate init(uid: uid_t, pid: pid_t, descriptor: Int32, enabled: @escaping () -> Bool) {
        self.uid = uid; self.pid = pid; self.descriptor = descriptor; self.enabled = enabled
    }
    public var connected: Bool {
        guard enabled() else { return false }
        var byte: UInt8 = 0
        let result = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        // Trailing bytes are a second request, not a valid continuation of a single-request connection.
        return result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
    }
}

public final class LocalRequestServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data, LocalPeer) async -> Data
    private let path: String
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var running = false
    private var occupied = false
    private var socketIdentity: ino_t = 0
    private var lockDescriptor: Int32 = -1
    private var generation: UInt64 = 0
    public init(path: String = LocalSocket.defaultPath) { self.path = path }
    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func isActive(_ expected: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return running && generation == expected }
    private func finishRequest() { lock.lock(); occupied = false; lock.unlock() }
    public func start(handler: @escaping Handler) throws {
        guard !isRunning else { throw AgentIPCError.failure("Local request server is already running.") }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw AgentIPCError.failure("Agent socket directory must be owned by you with mode 0700 and cannot be a symlink.") }
        let ownership = Darwin.open(path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard ownership >= 0 else { throw AgentIPCError.failure("Cannot open agent server ownership lock.") }
        guard fstat(ownership, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, flock(ownership, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(ownership); throw AgentIPCError.failure("Agent server ownership lock is unsafe or held by another instance.")
        }
        var started = false
        defer { if !started { Darwin.close(ownership) } }
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw AgentIPCError.failure("Agent socket path is occupied by an unsafe file.") }
            let probe = try LocalSocket.descriptor()
            let result = try LocalSocket.withAddress(path) { Darwin.connect(probe, $0, $1) }
            let failure = errno; Darwin.close(probe)
            guard result < 0, failure == ECONNREFUSED else { throw AgentIPCError.failure("Another AkiTTY instance owns the agent socket.") }
            var current = stat()
            guard lstat(path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino else { throw AgentIPCError.failure("Agent socket changed during stale check.") }
            guard unlink(path) == 0 else { throw AgentIPCError.failure("Cannot remove stale agent socket.") }
        }
        let fd = try LocalSocket.descriptor()
        do {
            guard try LocalSocket.withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0 else { throw AgentIPCError.failure("Cannot bind agent socket.") }
            guard chmod(path, 0o600) == 0, listen(fd, 4) == 0, lstat(path, &info) == 0 else { throw AgentIPCError.failure("Cannot protect or listen on agent socket.") }
            socketIdentity = info.st_ino
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw AgentIPCError.failure("Cannot configure agent listener.") }
            lock.lock(); running = true; generation += 1; let activeGeneration = generation; lock.unlock()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in
                while let self, self.isRunning {
                    let client = accept(fd, nil, nil)
                    if client < 0 { break }
                    do { try LocalSocket.configure(client, timeout: 3) } catch { Darwin.close(client); continue }
                    guard fcntl(client, F_SETFL, 0) == 0 else { Darwin.close(client); continue }
                    self.lock.lock(); let busy = self.occupied; if !busy { self.occupied = true }; self.lock.unlock()
                    if busy { Darwin.close(client); continue }
                    Task { [weak self] in
                        guard let self else { Darwin.close(client); return }
                        defer { Darwin.close(client); self.finishRequest() }
                        do {
                            var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
                            var length = socklen_t(MemoryLayout<pid_t>.size)
                            guard getpeereid(client, &uid, &gid) == 0, uid == getuid(),
                                  getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { throw AgentIPCError.failure("Local caller credentials unavailable or not permitted.") }
                            let request = try LocalSocket.readFrame(from: client, timeout: 3)
                            let peer = LocalPeer(uid: uid, pid: pid, descriptor: client, enabled: { [weak self] in self?.isActive(activeGeneration) == true })
                            let response = await handler(request, peer)
                            try LocalSocket.writeFrame(response, to: client)
                        } catch {
                            let reply = try? JSONSerialization.data(withJSONObject: ["version": 1, "ok": false, "error": error.localizedDescription])
                            if let reply { try? LocalSocket.writeFrame(reply, to: client) }
                        }
                    }
                }
            }
            self.source = source; lockDescriptor = ownership; started = true; source.resume()
        } catch { Darwin.close(fd); throw error }
    }
    public func stop() {
        lock.lock(); running = false; lock.unlock()
        source?.cancel(); source = nil
        var info = stat()
        if socketIdentity != 0, lstat(path, &info) == 0, info.st_ino == socketIdentity { _ = unlink(path) }
        socketIdentity = 0
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor); lockDescriptor = -1 }
    }
    deinit { stop() }
}

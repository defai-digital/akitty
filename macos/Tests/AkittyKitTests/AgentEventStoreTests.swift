import XCTest
import Darwin
@testable import AgentIPC
@testable import AkittyKit

final class AgentEventStoreTests: XCTestCase {
    @MainActor func testQueuedAppendsStayOrderedWithSynchronousOnesAndAreVisibleToExport() throws {
        let root = URL(fileURLWithPath: "/tmp/akitty-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentEventStore(directory: root)
        var failures: [String] = []
        for i in 0..<20 { store.appendLater(event: "queued", session: "s", provenance: "host", fields: ["index": i]) { failures.append($0) } }
        try store.append(event: "durable", session: "s", provenance: "host", synchronize: true)
        let events = try store.export().split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        XCTAssertEqual(events.map { $0["event"] as? String }, Array(repeating: "queued", count: 20) + ["durable"])
        XCTAssertEqual(events.compactMap { ($0["fields"] as? [String: Any])?["index"] as? Int }, Array(0..<20))
        XCTAssertTrue(failures.isEmpty)
    }

    @MainActor func testBoundedRotationSurvivesReopeningAndMarksRetentionLoss() throws {
        let root = URL(fileURLWithPath: "/tmp/akitty-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentEventStore(directory: root, segmentLimit: 4096)
        for i in 0..<50 { try store.append(event: "test", session: "durable-session", provenance: "host", fields: ["index": i], synchronize: true) }
        let data = try AgentEventStore(directory: root, segmentLimit: 4096).export()
        XCTAssertLessThanOrEqual(data.count, 8192)
        let events = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        XCTAssertTrue(events.contains { $0["event"] as? String == "retention_rotated" })
        let sequences = events.map { $0["sequence"] as! Int }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual((events.last?["fields"] as? [String: Any])?["index"] as? Int, 49)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("events.jsonl").path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testLargeAdmittedEventsRotateOnceAndRemainExportable() throws {
        for largeSession in [false, true] {
            let root = URL(fileURLWithPath: "/tmp/akitty-events-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = AgentEventStore(directory: root, segmentLimit: 4096)
            try store.append(event: "before", session: "s", provenance: "host", fields: ["padding": String(repeating: "x", count: 2000)])
            let session = largeSession ? String(repeating: "s", count: 3300) : "s"
            let fields: [String: Any] = largeSession ? [:] : ["padding": String(repeating: "x", count: 3300)]
            try store.append(event: "large", session: session, provenance: "host", fields: fields, synchronize: true)
            let data = try store.export()
            let events = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
            XCTAssertLessThanOrEqual(data.count, 8192)
            XCTAssertEqual(events.map { $0["event"] as? String }, ["before", "retention_rotated", "large"])
            XCTAssertEqual(events.map { $0["sequence"] as? Int }, [1, 2, 3])
            XCTAssertEqual(events.last?["session"] as? String, session)
            XCTAssertEqual((events.last?["fields"] as? [String: String]) ?? [:], fields as! [String: String])
        }
    }

    @MainActor func testEventFilesRejectSymlinksAndUnsafePermissions() throws {
        let root = URL(fileURLWithPath: "/tmp/akitty-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent("unrelated.txt"); try Data("keep".utf8).write(to: target)
        let file = root.appendingPathComponent("events.jsonl")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try AgentEventStore(directory: root).append(event: "bad", session: "s", provenance: "host"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: file)
        try Data().write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try AgentEventStore(directory: root).export())
    }

    func testExportRejectsNamedPipesWithoutWaitingForAWriter() throws {
        let root = URL(fileURLWithPath: "/tmp/akitty-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pipe = root.appendingPathComponent("previous.jsonl")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let store = AgentEventStore(directory: root), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { _ = try store.export(); XCTFail("named pipes must be rejected") }
            catch { /* Expected: event files must be regular files. */ }
            finished.signal()
        }
        let result = finished.wait(timeout: .now() + 1)
        if result == .timedOut {
            // Release a regressed blocking reader so a failed assertion cannot hang the suite.
            let writer = Darwin.open(pipe.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { Darwin.close(writer) }
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(result, .success, "non-regular event files must fail without waiting for a FIFO peer")
    }

    func testLocalSocketRefusesOccupiedFilesAndUnboundedFrames() throws {
        let root = URL(fileURLWithPath: "/tmp/akitty-ipc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("socket"); try Data("keep".utf8).write(to: path)
        let server = LocalRequestServer(path: path.path)
        XCTAssertThrowsError(try server.start { data, _ in data })
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "keep")
        XCTAssertThrowsError(try LocalSocket.writeFrame(Data(repeating: 1, count: 16_385), to: -1))
    }

    @MainActor func testIncompleteTailIsLossMarkedAndSecondWriterCannotRotateFiles() throws {
        let root = URL(fileURLWithPath: "/tmp/akitty-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentEventStore(directory: root)
        try store.append(event: "before", session: "s", provenance: "host")
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("events.jsonl")); try handle.seekToEnd()
        try handle.write(contentsOf: Data("{partial".utf8)); try handle.close()
        try store.append(event: "after", session: "s", provenance: "host")
        let data = try store.export()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("incomplete_record_dropped"))
        for line in data.split(separator: 10) { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
        let second = AgentEventStore(directory: root)
        XCTAssertThrowsError(try second.append(event: "competing", session: "s", provenance: "host"))
    }

    func testWholeFrameDeadlineAndListenerOwnershipAreEnforced() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let reader = pair[0], writer = pair[1]
        defer { Darwin.close(reader); Darwin.close(writer) }
        try LocalSocket.configure(writer, timeout: 1)
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for byte: UInt8 in [0, 0, 0, 64, 1, 1, 1, 1] {
                var value = byte
                if send(writer, &value, 1, 0) != 1 { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LocalSocket.readFrame(from: reader, timeout: 0.07))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.3)
        // Sender scheduling/cleanup is separate from the 0.3-second read bound
        // above; loaded CI workers can take longer to resume the sender.
        _ = shutdown(reader, SHUT_RDWR); XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let root = URL(fileURLWithPath: "/tmp/akitty-listener-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("socket").path
        let first = LocalRequestServer(path: path), second = LocalRequestServer(path: path)
        try first.start { data, _ in data }; defer { first.stop() }
        XCTAssertThrowsError(try second.start { data, _ in data })
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0); XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
    }
    func testWriteDeadlineBoundsANonReadingPeer() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        try LocalSocket.configure(pair[0], timeout: 3)
        var small: Int32 = 1024
        XCTAssertEqual(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size)), 0)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LocalSocket.writeFrame(Data(repeating: 1, count: 16_384), to: pair[0], timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.3)
    }

    func testRestartAcceptsRequestsWhileOldHandlerIsStillSuspended() async throws {
        let root = URL(fileURLWithPath: "/tmp/akitty-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("socket").path
        let server = LocalRequestServer(path: path)
        let gate = AsyncStream<Void>.makeStream(), entered = DispatchSemaphore(value: 0)
        defer { gate.continuation.finish(); server.stop() }
        try server.start { data, _ in
            entered.signal()
            for await _ in gate.stream { break }
            return data
        }
        let fd = try LocalSocket.descriptor(); defer { Darwin.close(fd) }
        XCTAssertEqual(try LocalSocket.withAddress(path) { Darwin.connect(fd, $0, $1) }, 0)
        try LocalSocket.writeFrame(Data("old".utf8), to: fd)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let busy = try await Task.detached { try LocalSocket.request(Data("busy".utf8), path: path) }.value
        XCTAssertTrue(String(decoding: busy, as: UTF8.self).contains("request not dispatched"))
        server.stop()
        try server.start { data, _ in data }
        do {
            let reply = try await Task.detached { try LocalSocket.request(Data("new".utf8), path: path) }.value
            XCTAssertEqual(reply, Data("new".utf8))
        } catch { XCTFail("restarted listener must not inherit the old handler's busy slot: \(error)") }
    }

}

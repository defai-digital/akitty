import XCTest
import Darwin
@testable import AgentIPC
@testable import AkittyKit

final class AgentEventStoreTests: XCTestCase {
    @MainActor func testBoundedRotationSurvivesReopeningAndMarksRetentionLoss() throws {
        let root = URL(fileURLWithPath: "/tmp/akitty-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentEventStore(directory: root, segmentLimit: 4096)
        for i in 0..<50 { try store.append(event: "test", session: "durable-session", provenance: "host", fields: ["index": i]) }
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
        _ = shutdown(reader, SHUT_RDWR); XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        let root = URL(fileURLWithPath: "/tmp/akitty-listener-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("socket").path
        let first = LocalRequestServer(path: path), second = LocalRequestServer(path: path)
        try first.start { data, _ in data }; defer { first.stop() }
        XCTAssertThrowsError(try second.start { data, _ in data })
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0); XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
    }
}

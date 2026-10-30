import XCTest
import AppKit
@testable import AkittyKit

final class DropPolicyTests: XCTestCase {
    @MainActor func testFinderPathsAreQuotedInOrderWithoutAnExecutionNewline() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let paths = ["/tmp/a b", "/tmp/it's;$(touch bad)", "/tmp/中文"]
        XCTAssertTrue(pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }))
        XCTAssertEqual(try DropPolicy.text(from: pasteboard), "'/tmp/a b' '/tmp/it'\\''s;$(touch bad)' '/tmp/中文' ")
    }
    @MainActor func testRemoteAndOversizedDropsAreRejected() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem(); item.setString("file://remote/tmp/file",forType:.fileURL)
        pasteboard.writeObjects([item])
        XCTAssertThrowsError(try DropPolicy.text(from: pasteboard))
        pasteboard.clearContents(); pasteboard.setString(String(repeating:"x",count:65537),forType:.string)
        XCTAssertThrowsError(try DropPolicy.text(from: pasteboard))
    }
    @MainActor func testDroppedTextUsesPasteConfirmationAndRespectsAgentControl() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let terminal = try TerminalView(headless:true,forceSoftware:true)
        defer { terminal.shutdown() }
        var statuses: [String] = []; terminal.onStatus = { statuses.append($0) }
        pasteboard.setString("echo bad\n",forType:.string)
        XCTAssertTrue(terminal.acceptDrop(from:pasteboard))
        XCTAssertTrue(statuses.contains { $0.contains("confirmation") })
        let lease = try terminal.session.acquireControl(actor:"agent")
        pasteboard.clearContents(); pasteboard.setString("plain",forType:.string)
        XCTAssertFalse(terminal.acceptDrop(from:pasteboard))
        XCTAssertTrue(statuses.last?.contains("Reclaim") == true)
        try terminal.session.releaseControl(lease)
    }
}

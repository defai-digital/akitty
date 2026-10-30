import XCTest
import AppKit
import Metal
@testable import AkittyKit

final class AkittyTests: XCTestCase {
    func testABIVersionAndInvalidHandle() throws {
        let data = try CoreBridge.call(["op": "version"])
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(value?["abi"] as? Int, 1)
        XCTAssertThrowsError(try CoreBridge.call(["op":"snapshot", "id":UInt64.max]))
    }
    func testSessionSnapshotAndUTF16ColumnMapping() throws {
        let session = try TerminalSession(cols: 20, rows: 3, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text":"中😀e\u{301}"])
        let snapshot = try XCTUnwrap(session.snapshot())
        XCTAssertEqual(snapshot.cursor.col, 5)
        XCTAssertEqual(snapshot.textOffset(row: 0, col: 2), 1)
        XCTAssertEqual(snapshot.textOffset(row: 0, col: 4), 3)
        XCTAssertEqual(snapshot.textOffset(row: 0, col: 5), 5)
        XCTAssertNil(try session.snapshot(since: snapshot.revision))
    }
    func testClosedSessionCannotBeUsedAndCloseIsIdempotent() throws {
        let session = try TerminalSession(headless: true)
        try session.close(); try session.close()
        XCTAssertThrowsError(try session.snapshot())
    }
    func testClipboardBoundsAndPasteProtection() {
        XCTAssertTrue(ClipboardPolicy.acceptsText("hello"))
        XCTAssertFalse(ClipboardPolicy.acceptsText("\0"))
        XCTAssertFalse(ClipboardPolicy.acceptsText(String(repeating:"a",count:65537)))
        XCTAssertFalse(ClipboardPolicy.needsPasteConfirmation("hello"))
        for value in ["a\nb", "a\rb", "\u{1b}[201~", "\u{7f}"] { XCTAssertTrue(ClipboardPolicy.needsPasteConfirmation(value)) }
    }
    func testCompositionCommitAndCancel() {
        var composition = Composition()
        composition.mark("にほん"); XCTAssertEqual(composition.text,"にほん")
        XCTAssertEqual(composition.commit("日本"),"日本"); XCTAssertTrue(composition.text.isEmpty)
        composition.mark("中"); composition.cancel(); XCTAssertTrue(composition.text.isEmpty)
    }
    @MainActor func testRealJavaScriptCorePalette() async {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AkittyKit/Resources/features.js")
        let source = try! String(contentsOf: sourceURL, encoding: .utf8)
        let host = FeatureHost(source: source)
        XCTAssertEqual(host.search("split").first?.id, .split)
        XCTAssertEqual(host.search("ｓｐｌｉｔ").first?.id, .split)
        XCTAssertEqual(Set(host.search("").map(\.id)), Set(NativeCommand.allCases))
        XCTAssertNil(host.warning)
    }
    @MainActor func testScriptExceptionFallsBackToNativeCommands() async {
        let host = FeatureHost(source: "var AkittyFeatures = { listCommands: function() { throw new Error('test'); } };")
        XCTAssertEqual(host.search("split").first?.id,.split)
        XCTAssertNotNil(host.warning)
        XCTAssertEqual(host.search("").count,NativeCommand.allCases.count)
    }
    @MainActor func testMalformedScriptAndMissingEntryFallBack() async {
        for source in ["throw new Error('load')", "var AkittyFeatures = {}", "var AkittyFeatures = {listCommands:function(){return 'null'}}"] {
            let host = FeatureHost(source:source)
            XCTAssertEqual(host.search("").count,NativeCommand.allCases.count)
            XCTAssertNotNil(host.warning)
        }
    }
    @MainActor func testCommandSchemaRejectsUnknownIDsVersionsAndDuplicates() async throws {
        let item: [String:Any] = ["id":"split","title":"Split Pane","shortcut":"","keywords":[]]
        for envelope: [String:Any] in [
            ["version":2,"commands":[item]],
            ["version":1,"commands":[item,item]],
            ["version":1,"commands":[["id":"sh -c malicious","title":"x","shortcut":"","keywords":[]]]],
            ["version":1,"commands":[["id":"split","title":"bad\u{1b}","shortcut":"","keywords":[]]]]
        ] { XCTAssertThrowsError(try FeatureHost.decode(JSONSerialization.data(withJSONObject:envelope))) }
        XCTAssertThrowsError(try FeatureHost.decode(Data(repeating:0,count:65537)))
    }
    @MainActor func testActualRendererUnavailableFallsBackAndExposesAXText() async throws {
        _ = NSApplication.shared
        let view = try TerminalView(headless:true,forceSoftware:true)
        defer { view.shutdown() }
        _ = try view.session.call("feed",["text":"Akitty accessible 中😀"])
        view.poll()
        for _ in 0..<100 {
            if view.snapshot != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(view.health.usesSoftware)
        XCTAssertNotNil(view.health.failure)
        XCTAssertTrue((view.accessibilityValue() as? String)?.contains("Akitty accessible") == true)
        XCTAssertEqual(view.accessibilityRole(),.textArea)
        XCTAssertEqual(view.accessibilityNumberOfCharacters(),(view.accessibilityValue() as? String)?.utf16.count)
    }
    @MainActor func testShaderCompilationFailureKeepsSoftwareTerminalUsable() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Runner has no Metal device; unavailable-device fallback is tested separately") }
        _ = NSApplication.shared
        let view = try TerminalView(headless: true, forceShaderFailure: true)
        defer { view.shutdown() }
        XCTAssertTrue(view.health.usesSoftware)
        XCTAssertNotNil(view.health.failure)
        _ = try view.session.call("feed", ["text": "shader fallback survives"])
        view.poll()
        for _ in 0..<100 {
            if view.snapshot != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(view.snapshot?.text.contains("shader fallback survives") == true)
        let bitmap = try GridRasterizer.make(snapshot: XCTUnwrap(view.snapshot), size: CGSize(width: 400, height: 100), scale: 1, fontName: "Menlo", fontSize: 14, cellSize: CGSize(width: 10, height: 20), composition: "")
        XCTAssertNotNil(bitmap.makeImage())
    }
    @MainActor func testMarkedTextDoesNotEnterTerminalUntilCommit() async throws {
        _ = NSApplication.shared
        let view = try TerminalView(headless:true,forceSoftware:true)
        defer { view.shutdown() }
        let before = try view.session.snapshot()?.text
        view.setMarkedText("にほん",selectedRange:NSRange(location:3,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(try view.session.snapshot()?.text,before)
        view.unmarkText(); XCTAssertFalse(view.hasMarkedText())
    }
    @MainActor func testWideCellRasterizationAndBitmapBounds() async throws {
        _ = NSApplication.shared
        let session = try TerminalSession(cols:20,rows:3,headless:true)
        defer { try? session.close() }
        _ = try session.call("feed",["text":"中😀e\u{301}\u{1b}[31mRED"])
        let snapshot = try XCTUnwrap(session.snapshot())
        let bitmap = try GridRasterizer.make(snapshot:snapshot,size:CGSize(width:400,height:100),scale:2,fontName:"Menlo",fontSize:14,cellSize:CGSize(width:10,height:20),composition:"")
        XCTAssertEqual(bitmap.width,800)
        XCTAssertNotNil(bitmap.makeImage())
        XCTAssertThrowsError(try GridRasterizer.make(snapshot:snapshot,size:CGSize(width:20000,height:20000),scale:2,fontName:"Menlo",fontSize:14,cellSize:CGSize(width:10,height:20),composition:""))
    }
    func testMouseEncodingPreservesRawBytesAndSGRRelease() {
        XCTAssertEqual(MouseEncoding.encode(button: 0, row: 100, col: 120, release: false, sgr: false), [27,91,77,32,153,133])
        XCTAssertEqual(MouseEncoding.encode(button: 0, row: 1, col: 2, release: true, sgr: true), Array("\u{1b}[<0;3;2m".utf8))
        XCTAssertEqual(MouseEncoding.encode(button: 64, row: 0, col: 0, release: false, sgr: true), Array("\u{1b}[<64;1;1M".utf8))
        XCTAssertNil(MouseEncoding.encode(button: 0, row: -1, col: 0, release: false, sgr: true))
    }

}

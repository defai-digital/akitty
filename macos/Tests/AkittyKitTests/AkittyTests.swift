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
    func testPositionalCellsDecodePackedColoursAttributesAndTrailingFields() throws {
        let json = #"[[1,2,"x",66051,263430,831,460809,3],[0,0,"B",0,1,0,null,0],[0,1,"c",255,0,16]]"#
        let cells = try JSONDecoder().decode([Cell].self, from: Data(json.utf8))
        let full = cells[0]
        XCTAssertEqual([full.row, full.col], [1, 2])
        XCTAssertEqual(full.fg, [1, 2, 3]); XCTAssertEqual(full.bg, [4, 5, 6]); XCTAssertEqual(full.ucolor, [7, 8, 9])
        // 831 = bold, italic, underline, selected, wide, strike, underline style 3.
        XCTAssertTrue(full.bold && full.italic && full.underline && full.selected && full.wide)
        XCTAssertFalse(full.search || full.activeSearch)
        XCTAssertEqual(full.strike, true); XCTAssertEqual(full.ustyle, 3); XCTAssertEqual(full.link, 3)
        XCTAssertNil(cells[1].ucolor); XCTAssertEqual(cells[1].link, 0)
        let plain = cells[2]
        XCTAssertTrue(plain.wide && !plain.bold && !plain.selected)
        XCTAssertNil(plain.strike); XCTAssertNil(plain.ustyle); XCTAssertNil(plain.ucolor); XCTAssertNil(plain.link)
        // Encoding writes the same wire form back.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(cells), as: UTF8.self), json)
        // 192 = search (64) and active search (128). Neither bit is selection.
        let marked = try JSONDecoder().decode([Cell].self, from: Data(#"[[0,1,"a",0,0,192]]"#.utf8))
        XCTAssertTrue(marked[0].search && marked[0].activeSearch && !marked[0].selected)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(marked), as: UTF8.self), #"[[0,1,"a",0,0,192]]"#)
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
    func testClosingThroughCallReturnsTheReplyAndMarksTheSessionClosed() throws {
        let session = try TerminalSession(headless: true)
        let data = try session.call("close")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertThrowsError(try session.call("snapshot")) { error in
            XCTAssertEqual(error.localizedDescription, "Session is closed")
        }
        XCTAssertThrowsError(try session.snapshot())
        XCTAssertNoThrow(try session.close())
    }
    func testClosingSessionRejectsCallsWithoutWaitingForChildReaping() throws {
        let session = try TerminalSession(headless: true)
        let closing = expectation(description: "child cleanup started")
        let rejected = expectation(description: "late terminal event rejected")
        let finished = expectation(description: "child cleanup finished")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            try? session.close { id in
                closing.fulfill(); release.wait()
                _ = try CoreBridge.call(["op": "close", "id": id])
            }
        }
        wait(for: [closing], timeout: 2)
        DispatchQueue.global().async {
            do { _ = try session.snapshot(); XCTFail("snapshot accepted during cleanup") } catch {}
            do { try session.input("late input"); XCTFail("input accepted during cleanup") } catch {}
            XCTAssertNil(session.imagePixels(1, width: 1, height: 1))
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 0.3)
        release.signal()
        wait(for: [finished], timeout: 2)
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

    func testPreferencesValidateAndPersistWithoutExecutingShellText() throws {
        let suite = "akitty-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var value = TerminalPreferences(); value.fontName = "Menlo"; value.fontSize = 18; value.scrollback = 1000; value.optionAsAlt = true
        try value.save(to: defaults)
        XCTAssertEqual(TerminalPreferences.load(from: defaults), value)
        value.shell = "/bin/sh -c echo"
        XCTAssertThrowsError(try value.validated())
        value.shell = ""; value.fontSize = .infinity
        XCTAssertThrowsError(try value.validated())
        defaults.set(Data("bad".utf8), forKey: "terminalPreferences")
        XCTAssertEqual(TerminalPreferences.load(from: defaults), TerminalPreferences())
    }
    func testHyperlinkPolicyAllowsOnlyInertSchemes() {
        XCTAssertNotNil(LinkPolicy.url(for: "https://example.com/a?b=1"))
        XCTAssertNotNil(LinkPolicy.url(for: "mailto:a@example.com"))
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host", "x-apple.systempreferences:", "https://", "https://a\u{1b}b", "not a url", String(repeating: "a", count: 3000)] {
            XCTAssertNil(LinkPolicy.url(for: bad), bad)
        }
    }
    func testCoreReportsStyledCellsAndHyperlinksToSwift() throws {
        let session = try TerminalSession(cols: 20, rows: 3, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}[4:3mC\u{1b}[0m\u{1b}[9mS\u{1b}[0m\u{1b}]8;;https://a.test/\u{7}L\u{1b}]8;;\u{7}N"])
        let snapshot = try XCTUnwrap(try session.snapshot())
        XCTAssertEqual(snapshot.cells[0].ustyle, 3)
        XCTAssertEqual(snapshot.cells[1].strike, true)
        XCTAssertEqual(snapshot.hyperlink(row: 0, col: 2)?.absoluteString, "https://a.test/")
        XCTAssertNil(snapshot.hyperlink(row: 0, col: 3))
        _ = try GridRasterizer.make(snapshot: snapshot, size: CGSize(width: 200, height: 80), scale: 1, fontName: "Menlo", fontSize: 13, cellSize: CGSize(width: 8, height: 16), composition: "")
    }
    func testKittyGraphicsFrameReachesTheRasterizedBitmap() throws {
        let session = try TerminalSession(cols: 20, rows: 6, headless: true)
        defer { try? session.close() }
        _ = try session.call("cell_size", ["width": 8, "height": 16])
        // One opaque red 4x4 RGB image stretched over 2x2 cells at the cursor, above the text.
        let red = Data([UInt8](repeating: 0, count: 0) + (0..<16).flatMap { _ in [UInt8(255), 0, 0] }).base64EncodedString()
        _ = try session.call("feed", ["text": "ab\u{1b}_Ga=T,f=24,s=4,v=4,i=9,c=2,r=2,C=1,z=1,q=2;\(red)\u{1b}\\"])
        let snapshot = try XCTUnwrap(try session.snapshot())
        let placement = try XCTUnwrap(snapshot.images?.first)
        XCTAssertEqual([placement.id, UInt32(placement.cols), UInt32(placement.rows)], [9, 2, 2])
        let store = ImageStore()
        store.sync(snapshot.images ?? [], session: session)
        XCTAssertEqual(store.images.count, 1)
        let cell = CGSize(width: 8, height: 16), size = CGSize(width: 200, height: 120)
        let context = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 1, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "", images: store.images)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Image cell (row 0, col 2) centre in bitmap coordinates (origin bottom-left).
        let x = 8 + 2 * 8 + 8, y = 120 - 8 - 16
        let offset = (Int(size.height) - 1 - y) * context.bytesPerRow + x * 4
        XCTAssertEqual([data[offset + 2], data[offset + 1], data[offset]], [255, 0, 0], "red image pixel (BGRA)")
        // Replaced by deletion: the store drops the pixels with the placement.
        _ = try session.call("feed", ["text": "\u{1b}_Ga=d,d=I,i=9\u{1b}\\"])
        store.sync(try XCTUnwrap(try session.snapshot()).images ?? [], session: session)
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertNil(session.imagePixels(9, width: 4, height: 4))
    }
    // MARK: Kitty graphics source rects, offsets and z layers
    private func placement(id: UInt32 = 1, w: Int, h: Int, row: Int = 0, col: Int = 0, cols: Int, rows: Int, z: Int = 0,
                           sx: Int? = nil, sy: Int? = nil, sw: Int? = nil, sh: Int? = nil, ox: Int? = nil, oy: Int? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "gen": 1, "w": w, "h": h, "row": row, "col": col, "cols": cols, "rows": rows, "z": z]
        if let sx { value["sx"] = sx }; if let sy { value["sy"] = sy }; if let sw { value["sw"] = sw }; if let sh { value["sh"] = sh }
        if let ox { value["ox"] = ox }; if let oy { value["oy"] = oy }
        return value
    }
    /// A wire cell: `[row, col, text, fg, bg, attrs]` with packed 0xRRGGBB colours; attrs bit 8 is selected.
    private func testCell(_ row: Int, _ col: Int, text: String = "", fg: [Int] = [218, 226, 239], bg: [Int] = [18, 22, 29], attrs: Int = 0, selected: Bool = false) -> [Any] {
        [row, col, text, fg[0] << 16 | fg[1] << 8 | fg[2], bg[0] << 16 | bg[1] << 8 | bg[2], (selected ? 8 : 0) | attrs]
    }
    private func testSnapshot(rows: Int = 2, cols: Int = 6, cells: [[Any]] = [], images: [[String: Any]] = []) throws -> Snapshot {
        let object: [String: Any] = ["changed": true, "revision": 1, "cols": cols, "rows": rows, "title": "", "cells": cells,
            "lines": Array(repeating: String(repeating: " ", count: cols), count: rows), "links": [] as [String], "images": images,
            "cursor": ["row": 0, "col": 0, "visible": false], "bracketed_paste": false, "app_cursor": false, "mouse_mode": false,
            "mouse_sgr": false, "mouse_drag": false, "mouse_motion": false, "focus_reporting": false, "alternate": false,
            "offset": 0, "history": 0, "clipboard": [] as [String], "exited": false]
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func testImage(_ width: Int, _ height: Int, _ color: (Int, Int) -> [UInt8]) -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<height { for x in 0..<width { let value = color(x, y); bytes += [value[0], value[1], value[2], 255] } }
        return ImageStore.makeImage(Data(bytes), width: width, height: height)!
    }
    /// Samples a bitmap pixel from the top-left in points (scale 1 in these tests); returns RGB.
    /// CGBitmapContext stores scanline 0 at the top, so the from-top row is the buffer row.
    private func sample(_ context: CGContext, x: Int, yFromTop: Int) -> [UInt8] {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = yFromTop * context.bytesPerRow + x * 4
        return [data[offset + 2], data[offset + 1], data[offset]]
    }
    /// The rendered default background, which color management may shift from the source bytes.
    private func renderedBackground() throws -> [UInt8] {
        sample(try rasterize(try testSnapshot(rows: 1, cols: 1), images: [:]), x: 50, yFromTop: 50)
    }
    private func rasterize(_ snapshot: Snapshot, images: [UInt32: CGImage], size: CGSize = CGSize(width: 100, height: 120)) throws -> CGContext {
        try GridRasterizer.make(snapshot: snapshot, size: size, scale: 1, fontName: "Menlo", fontSize: 13,
                                cellSize: CGSize(width: 10, height: 20), composition: "", images: images)
    }
    func testImagePlacementDecodesSourceRectAndOffsetFields() throws {
        let json = Data(#"{"id":7,"gen":3,"w":40,"h":30,"row":1,"col":2,"cols":3,"rows":4,"z":-2,"sx":5,"sy":6,"sw":10,"sh":12,"ox":4,"oy":-3}"#.utf8)
        let value = try JSONDecoder().decode(ImagePlacement.self, from: json)
        XCTAssertEqual([value.sx, value.sy, value.sw, value.sh, value.ox, value.oy], [5, 6, 10, 12, 4, -3])
        XCTAssertEqual(value.sourceRect, CGRect(x: 5, y: 6, width: 10, height: 12))
    }
    func testImagePlacementDecodesOldSnapshotsWithoutNewFields() throws {
        let json = Data(#"{"id":9,"gen":1,"w":40,"h":30,"row":0,"col":1,"cols":2,"rows":1,"z":0}"#.utf8)
        let value = try JSONDecoder().decode(ImagePlacement.self, from: json)
        XCTAssertNil(value.sx); XCTAssertNil(value.sy); XCTAssertNil(value.sw); XCTAssertNil(value.sh); XCTAssertNil(value.ox); XCTAssertNil(value.oy)
        XCTAssertEqual(value.sourceRect, CGRect(x: 0, y: 0, width: 40, height: 30))
        // A zero source width/height means "to the image edge".
        let zero = try JSONDecoder().decode(ImagePlacement.self, from: Data(#"{"id":9,"gen":1,"w":40,"h":30,"row":0,"col":1,"cols":2,"rows":1,"z":0,"sx":10,"sy":4,"sw":0,"sh":0}"#.utf8))
        XCTAssertEqual(zero.sourceRect, CGRect(x: 10, y: 4, width: 30, height: 26))
    }
    func testRasterizerDrawsOnlyThePlacementSourceRect() throws {
        // 4x4 image: left half red, right half green.
        let image = testImage(4, 4) { x, _ in x < 2 ? [255, 0, 0] : [0, 255, 0] }
        let snapshot = try testSnapshot(rows: 5, cols: 5, images: [placement(w: 4, h: 4, cols: 4, rows: 4, sx: 2, sw: 2, sh: 4)])
        let context = try rasterize(snapshot, images: [1: image])
        XCTAssertEqual(sample(context, x: 28, yFromTop: 48), [0, 255, 0], "only the right half of the source is drawn")
        XCTAssertEqual(sample(context, x: 12, yFromTop: 8 + 8), [0, 255, 0])
    }
    func testRasterizerSourceRectYStartsAtTheImageTop() throws {
        // 4x4 image: top half red, bottom half green. Kitty sy counts from the top.
        let image = testImage(4, 4) { _, y in y < 2 ? [255, 0, 0] : [0, 255, 0] }
        let top = try rasterize(try testSnapshot(rows: 4, cols: 5, images: [placement(w: 4, h: 4, cols: 4, rows: 4, sy: 0, sw: 4, sh: 2)]), images: [1: image])
        XCTAssertEqual(sample(top, x: 28, yFromTop: 28), [255, 0, 0])
        let bottom = try rasterize(try testSnapshot(rows: 4, cols: 5, images: [placement(w: 4, h: 4, cols: 4, rows: 4, sy: 2, sw: 4, sh: 2)]), images: [1: image])
        XCTAssertEqual(sample(bottom, x: 28, yFromTop: 68), [0, 255, 0])
    }
    func testRasterizerPlacementOffsetMovesTheImage() throws {
        let image = testImage(4, 4) { _, _ in [255, 0, 0] }
        let snapshot = try testSnapshot(rows: 4, cols: 5, images: [placement(w: 4, h: 4, cols: 2, rows: 1, ox: 10)])
        let context = try rasterize(snapshot, images: [1: image])
        XCTAssertEqual(sample(context, x: 22, yFromTop: 18), [255, 0, 0])
        XCTAssertEqual(sample(context, x: 12, yFromTop: 18), try renderedBackground(), "the offset leaves the start of the cell uncovered")
    }
    func testRasterizerPaintsTheCurrentFindHitBrighterThanOtherHits() throws {
        let active = try rasterize(try testSnapshot(rows: 1, cols: 2, cells: [testCell(0, 0, attrs: 192)]), images: [:])
        let other = try rasterize(try testSnapshot(rows: 1, cols: 2, cells: [testCell(0, 0, attrs: 64)]), images: [:])
        let activePixel = sample(active, x: 13, yFromTop: 18), otherPixel = sample(other, x: 13, yFromTop: 18)
        XCTAssertGreaterThan(activePixel[0], otherPixel[0], "the current hit is the brighter amber")
        XCTAssertGreaterThan(activePixel[0], activePixel[2])
        XCTAssertGreaterThan(otherPixel[0], otherPixel[2])
        let selected = try rasterize(try testSnapshot(rows: 1, cols: 2, cells: [testCell(0, 0, attrs: 192, selected: true)]), images: [:])
        let selection = try rasterize(try testSnapshot(rows: 1, cols: 2, cells: [testCell(0, 0, selected: true)]), images: [:])
        XCTAssertEqual(sample(selected, x: 13, yFromTop: 18), sample(selection, x: 13, yFromTop: 18), "selection covers the find highlight")
    }
    func testRasterizerZLayerRespectsKittyThreshold() throws {
        let image = testImage(4, 4) { _, _ in [0, 0, 255] }
        let cells = [testCell(0, 0, bg: [255, 0, 0]), testCell(0, 1, text: ".")]
        let snapshot = try testSnapshot(rows: 2, cols: 6, cells: cells,
                                        images: [placement(w: 4, h: 4, cols: 2, rows: 1, z: -2_000_000_000)])
        let context = try rasterize(snapshot, images: [1: image])
        // Compare against a rendered red cell so color management cannot skew the expectation.
        let redCell = try rasterize(try testSnapshot(rows: 1, cols: 2, cells: [testCell(0, 0, bg: [255, 0, 0])]), images: [:])
        XCTAssertEqual(sample(context, x: 13, yFromTop: 18), sample(redCell, x: 13, yFromTop: 18),
                       "a non-default cell background hides the lowest layer")
        XCTAssertEqual(sample(context, x: 26, yFromTop: 18), [0, 0, 255], "a default-background cell leaves it visible")
    }
    func testRasterizerForegroundImageCoversText() throws {
        let image = testImage(4, 4) { _, _ in [0, 0, 255] }
        let cells = [testCell(0, 0, text: "█", fg: [255, 0, 0])]
        let textOnly = try rasterize(try testSnapshot(rows: 2, cols: 3, cells: cells), images: [:])
        XCTAssertNotEqual(sample(textOnly, x: 13, yFromTop: 18), [0, 0, 255])
        let covered = try rasterize(try testSnapshot(rows: 2, cols: 3, cells: cells,
                                                     images: [placement(w: 4, h: 4, cols: 1, rows: 1, z: 1)]), images: [1: image])
        XCTAssertEqual(sample(covered, x: 13, yFromTop: 18), [0, 0, 255], "z >= 0 draws over the glyph")
    }

    // MARK: Kitty keyboard protocol
    private func kitty(_ keyCode: UInt16, _ mods: KittyModifiers = [], _ event: KittyEventType = .press, flags: Int) -> KittyKeyResult {
        KittyKeyEncoder.encode(KittyKeyInput(keyCode: keyCode, modifiers: mods, event: event), flags: flags)
    }
    private func kitty(_ keyCode: UInt16, _ key: Character, shifted: Character? = nil, text: String = "", _ mods: KittyModifiers = [],
                       _ event: KittyEventType = .press, flags: Int) -> KittyKeyResult {
        KittyKeyEncoder.encode(KittyKeyInput(keyCode: keyCode, key: key.unicodeScalars.first?.value, shiftedKey: shifted?.unicodeScalars.first?.value,
                                             text: text.unicodeScalars.map(\.value), modifiers: mods, event: event), flags: flags)
    }
    private func esc(_ body: String) -> KittyKeyResult { .bytes(Array(("\u{1b}[" + body).utf8)) }
    func testKittyKeyboardLegacyUntilDisambiguated() {
        XCTAssertEqual(kitty(8, "c", [.ctrl], flags: 0), .legacy)
        XCTAssertEqual(kitty(0, "a", flags: 1), .legacy)
        XCTAssertEqual(kitty(0, "a", shifted: "A", [.shift], flags: 1), .legacy)
        // Releases and Enter/Tab/Backspace stay legacy until the app asks for more.
        XCTAssertEqual(kitty(0, "a", [], .release, flags: 1), .none)
        XCTAssertEqual(kitty(36, flags: 1), .legacy); XCTAssertEqual(kitty(48, flags: 1), .legacy); XCTAssertEqual(kitty(51, flags: 1), .legacy)
        XCTAssertEqual(kitty(123, flags: 1), .legacy)
        XCTAssertEqual(kitty(123, [.capsLock], flags: 1), .legacy)
    }
    func testKittyKeyboardDisambiguatesModifiedAndEscapeKeys() {
        XCTAssertEqual(kitty(8, "c", [.ctrl], flags: 1), esc("99;5u"))
        XCTAssertEqual(kitty(8, "c", shifted: "C", [.ctrl, .shift], flags: 1), esc("99;6u"))
        XCTAssertEqual(kitty(0, "a", [.alt], flags: 1), esc("97;3u"))
        XCTAssertEqual(kitty(53, flags: 1), esc("27u"))
        XCTAssertEqual(kitty(48, [.shift], flags: 1), esc("9;2u"))
        XCTAssertEqual(kitty(36, [.shift], flags: 1), esc("13;2u"))
        XCTAssertEqual(kitty(51, [.ctrl], flags: 1), esc("127;5u"))
        XCTAssertEqual(kitty(0, "a", shifted: "A", [.ctrl, .shift], flags: 5), esc("97:65;6u"))
    }
    func testKittyKeyboardFunctionalKeys() {
        XCTAssertEqual(kitty(123, [.ctrl], flags: 1), esc("1;5D"))
        XCTAssertEqual(kitty(117, [.alt], flags: 1), esc("3;3~"))
        XCTAssertEqual(kitty(96, [.ctrl], flags: 1), esc("15;5~"))
        XCTAssertEqual(kitty(122, [.ctrl], flags: 1), esc("1;5P"))
        XCTAssertEqual(kitty(123, [], .release, flags: 3), esc("1;1:3D"))
        XCTAssertEqual(kitty(123, [], .repeat, flags: 3), esc("1;1:2D"))
        XCTAssertEqual(kitty(123, flags: 3), .legacy)
        XCTAssertEqual(kitty(123, [], .release, flags: 2), esc("1;1:3D"))
    }
    func testKittyKeyboardEventTypesAndAlternates() {
        XCTAssertEqual(kitty(8, "c", [.ctrl], .release, flags: 3), esc("99;5:3u"))
        XCTAssertEqual(kitty(8, "c", [.ctrl], .repeat, flags: 3), esc("99;5:2u"))
        XCTAssertEqual(kitty(0, "a", [], .release, flags: 2), .none, "text keys are not escaped by event types alone")
        XCTAssertEqual(kitty(8, "c", [.ctrl], flags: 2), .legacy)
        XCTAssertEqual(KittyKeyEncoder.encode(KittyKeyInput(keyCode: 12, key: 0x61, shiftedKey: 0x41, baseLayoutKey: 0x71, modifiers: [.ctrl, .shift]), flags: 5),
                       esc("97:65:113;6u"))
    }
    func testKittyKeyboardReportAllKeysAndText() {
        XCTAssertEqual(kitty(0, "a", text: "a", flags: 8), esc("97u"))
        XCTAssertEqual(kitty(0, "a", shifted: "A", text: "A", [.shift], flags: 8), esc("97;2u"))
        XCTAssertEqual(kitty(0, "a", text: "a", flags: 24), esc("97;;97u"))
        XCTAssertEqual(kitty(0, "a", shifted: "A", text: "A", [.shift], flags: 24), esc("97;2;65u"))
        XCTAssertEqual(kitty(0, "a", shifted: "A", text: "A", [.shift], .release, flags: 31), esc("97:65;2:3u"))
        XCTAssertEqual(kitty(36, flags: 8), esc("13u")); XCTAssertEqual(kitty(48, flags: 8), esc("9u")); XCTAssertEqual(kitty(51, flags: 8), esc("127u"))
        XCTAssertEqual(kitty(87, "5", text: "5", flags: 8), esc("57404u"))
        XCTAssertEqual(kitty(76, flags: 8), esc("57414u"))
        XCTAssertEqual(kitty(76, flags: 1), .legacy)
    }
    func testKittyKeyboardModifierKeysNeedAllKeys() {
        XCTAssertEqual(KittyKeyEncoder.encodeModifier(keyCode: 56, modifiers: [.shift], pressed: true, flags: 8), esc("57441;2u"))
        XCTAssertEqual(KittyKeyEncoder.encodeModifier(keyCode: 56, modifiers: [], pressed: false, flags: 8), .none)
        XCTAssertEqual(KittyKeyEncoder.encodeModifier(keyCode: 59, modifiers: [], pressed: false, flags: 10), esc("57442;1:3u"))
        XCTAssertEqual(KittyKeyEncoder.encodeModifier(keyCode: 56, modifiers: [.shift], pressed: true, flags: 1), .none)
    }
    func testKittyKeyboardReviewRegressions() throws {
        XCTAssertEqual(kitty(99, [.ctrl], flags: 1), esc("13;5~"), "F3 uses the tilde form; CSI R is a cursor report")
        XCTAssertEqual(kitty(8, "c", [.ctrl, .capsLock], flags: 1), esc("99;5u"), "lock state is reported only with all-keys")
        XCTAssertEqual(kitty(8, "c", [.ctrl, .capsLock], flags: 8), esc("99;69u"))
        XCTAssertEqual(kitty(36, [.shift], .release, flags: 3), .none)
        XCTAssertEqual(kitty(36, [.shift], .repeat, flags: 3), esc("13;2u"))
        XCTAssertEqual(kitty(36, [.shift], .release, flags: 11), esc("13;2:3u"))
        XCTAssertEqual(kitty(53, [], .release, flags: 3), esc("27;1:3u"), "Escape releases are reported")
        XCTAssertEqual(kitty(105, flags: 1), esc("57376u"), "F13")
        XCTAssertEqual(kitty(114, flags: 1), .legacy)
        XCTAssertEqual(KittyKeyInput.modifiers(of: .option, optionAsAlt: false), [])
        XCTAssertEqual(KittyKeyInput.modifiers(of: [.option, .command], optionAsAlt: true), [.alt, .super])
        let command = try XCTUnwrap(KittyKeyInput(event: XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)), optionAsAlt: false, type: .press))
        XCTAssertEqual(KittyKeyEncoder.encode(command, flags: 1), esc("97;9u"))
        XCTAssertTrue(command.text.isEmpty)
    }
    func testKittyKeyInputFromRealKeyEvents() throws {
        func event(_ chars: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                           characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code))
        }
        let ctrlC = try XCTUnwrap(KittyKeyInput(event: event("\u{3}", "c", .control, 8), optionAsAlt: false, type: .press))
        XCTAssertEqual(ctrlC.key, 99); XCTAssertEqual(ctrlC.modifiers, [.ctrl]); XCTAssertTrue(ctrlC.text.isEmpty)
        // Shift+1 reports the unshifted key even though the OS hands back "!".
        let bang = try XCTUnwrap(KittyKeyInput(event: event("!", "!", .shift, 18), optionAsAlt: false, type: .press))
        XCTAssertEqual([bang.key, bang.shiftedKey, bang.text.first], [49, 33, 33])
        // Option composes text unless Option-as-Alt is on.
        XCTAssertNil(KittyKeyInput(event: try event("å", "a", .option, 0), optionAsAlt: false, type: .press))
        let alt = try XCTUnwrap(KittyKeyInput(event: event("å", "a", .option, 0), optionAsAlt: true, type: .press))
        XCTAssertEqual(alt.modifiers, [.alt]); XCTAssertEqual(alt.key, 97)
        let arrow = try XCTUnwrap(KittyKeyInput(event: event("\u{F702}", "\u{F702}", [.control], 123), optionAsAlt: false, type: .press))
        XCTAssertNil(arrow.key); XCTAssertEqual(KittyKeyEncoder.encode(arrow, flags: 1), esc("1;5D"))
    }
    func testCoreAdvertisesAndTracksKittyKeyboardFlags() throws {
        let session = try TerminalSession(cols: 20, rows: 4, headless: true)
        defer { try? session.close() }
        XCTAssertEqual(try XCTUnwrap(try session.snapshot()).kitty_flags, 0)
        _ = try session.call("feed", ["text": "\u{1b}[>5u"])
        XCTAssertEqual(try XCTUnwrap(try session.snapshot()).kitty_flags, 5)
    }
    func testWideLinkedCellSpacerResolvesToTheLink() throws {
        let session = try TerminalSession(cols: 20, rows: 3, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}]8;;https://wide.test/\u{7}中\u{1b}]8;;\u{7}x"])
        let snapshot = try XCTUnwrap(try session.snapshot())
        XCTAssertEqual(snapshot.hyperlink(row: 0, col: 0)?.absoluteString, "https://wide.test/")
        XCTAssertEqual(snapshot.hyperlink(row: 0, col: 1)?.absoluteString, "https://wide.test/")
        XCTAssertNil(snapshot.hyperlink(row: 0, col: 2))
    }
    func testTextOffsetCountsOmittedBlankCells() throws {
        let session = try TerminalSession(cols: 10, rows: 3, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "ab\r\n中c"])
        let snapshot = try XCTUnwrap(try session.snapshot())
        XCTAssertEqual(snapshot.cells.count, 5, "a, b, the wide char with its spacer, and c; no blank cells")
        XCTAssertEqual(snapshot.textOffset(row: 0, col: 2), 2)
        XCTAssertEqual(snapshot.textOffset(row: 0, col: 7), 7, "trailing blanks are one unit each")
        XCTAssertEqual(snapshot.textOffset(row: 0, col: 99), 10, "clamped to the line width")
        XCTAssertEqual(snapshot.textOffset(row: 1, col: 3), 11 + 2)
        XCTAssertEqual(snapshot.textOffset(row: 2, col: 4), 11 + 10 + 4, "row 1 is 中, c and 7 blanks: 9 units plus a newline")
    }
    func testPartialSnapshotsMergeIntoTheSameStateAsAFullOne() throws {
        let session = try TerminalSession(cols: 30, rows: 6, headless: true)
        defer { try? session.close() }
        func same(_ a: Snapshot, _ b: Snapshot, _ step: String) {
            XCTAssertEqual(a.lines, b.lines, step)
            XCTAssertEqual(a.cells.map { "\($0.row),\($0.col),\($0.text),\($0.fg),\($0.bg),\($0.bold),\($0.selected),\($0.strike ?? false)" },
                           b.cells.map { "\($0.row),\($0.col),\($0.text),\($0.fg),\($0.bg),\($0.bold),\($0.selected),\($0.strike ?? false)" }, step)
            for cell in a.cells where cell.link != nil {
                XCTAssertEqual(a.hyperlink(row: cell.row, col: cell.col), b.hyperlink(row: cell.row, col: cell.col), step)
            }
            XCTAssertEqual(a.cursor.row, b.cursor.row, step); XCTAssertEqual(a.cursor.col, b.cursor.col, step)
        }
        var held = try XCTUnwrap(try session.snapshot())
        var partials = 0
        for (index, text) in ["hello\r\nworld", "\u{1b}[2;1H\u{1b}[31mred\u{1b}[0m", "\u{1b}]8;;https://p.test/\u{7}link\u{1b}]8;;\u{7}", "\r\n\r\n\r\n\r\n\r\nscroll", "\u{1b}[3;3H中e\u{301}", "x"].enumerated() {
            _ = try session.call("feed", ["text": text])
            let merged = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
            partials += 1
            // The reference asks for a full snapshot, which also resets the server's baseline.
            let full = try XCTUnwrap(try session.snapshot())
            same(merged, full, "step \(index)")
            held = full
        }
        XCTAssertEqual(partials, 6)
        // Typing one character changes exactly one row, so the wire snapshot is tiny.
        _ = try session.call("feed", ["text": "\u{1b}[1;1Hz"])
        let wire = try session.call("snapshot", ["since": held.revision])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        XCTAssertEqual(object["partial"] as? Bool, true)
        XCTAssertEqual(object["dirty"] as? [Int], [0])
    }
    func testWrongBaselineFallsBackToAFullSnapshot() throws {
        let session = try TerminalSession(cols: 20, rows: 4, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "abc"])
        let first = try XCTUnwrap(try session.snapshot())
        _ = try session.call("feed", ["text": "d"])
        // Nothing was held on the Swift side, or the wrong revision was: still a correct, complete answer.
        let noBase = try XCTUnwrap(try session.snapshot(since: first.revision, base: nil))
        XCTAssertTrue(noBase.lines[0].hasPrefix("abcd"))
        _ = try session.call("feed", ["text": "e"])
        let wrong = try XCTUnwrap(try session.snapshot(since: first.revision, base: first))
        XCTAssertTrue(wrong.lines[0].hasPrefix("abcde"))
        XCTAssertNil(wrong.partial == true ? wrong : nil, "never hand a partial snapshot to callers")
    }
    func testStalePathsResetOnlyThemselvesOnLoad() throws {
        let suite = "akitty-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var value = TerminalPreferences(); value.fontSize = 20; value.scrollback = 2000; value.optionAsAlt = true
        value.directory = "/does-not-exist/akitty-test-dir"; value.shell = "/does-not-exist/akitty-test-shell"
        defaults.set(try JSONEncoder().encode(value), forKey: "terminalPreferences")
        let loaded = TerminalPreferences.load(from: defaults)
        XCTAssertEqual(loaded.fontSize, 20); XCTAssertEqual(loaded.scrollback, 2000); XCTAssertTrue(loaded.optionAsAlt)
        XCTAssertEqual(loaded.directory, ""); XCTAssertEqual(loaded.shell, "")
    }
    @MainActor func testVisiblePlusButtonCreatesTabAndReminderHasVersion() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let plus = try XCTUnwrap(descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "new-terminal-tab" })
        XCTAssertEqual(controller.tabs.numberOfTabViewItems, 1)
        plus.performClick(nil)
        XCTAssertEqual(controller.tabs.numberOfTabViewItems, 2)
        controller.refreshUpdateReminder("0.7.0")
        let reminder = try XCTUnwrap(controller.window?.titlebarAccessoryViewControllers.last?.view as? NSButton)
        XCTAssertEqual(reminder.title, "Update Available: 0.7.0")
        controller.refreshUpdateReminder(nil)
        XCTAssertTrue(controller.window!.titlebarAccessoryViewControllers.isEmpty)
    }
    @MainActor func testFindBarHighlightsMatchesAndMoves() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        let terminal = try XCTUnwrap(controller.active)
        _ = try terminal.session.call("feed", ["text": "one two one"])
        controller.perform(.find)
        XCTAssertTrue(controller.findBarVisible)
        controller.findQuery = "one"
        controller.runSearch("latest")
        let snapshot = try XCTUnwrap(terminal.session.snapshot())
        XCTAssertEqual(snapshot.cells.filter(\.activeSearch).map(\.col).sorted(), [8, 9, 10])
        XCTAssertEqual(snapshot.cells.filter { $0.search && !$0.activeSearch }.map(\.col).sorted(), [0, 1, 2])
        controller.perform(.findPrevious)
        let earlier = try XCTUnwrap(terminal.session.snapshot())
        XCTAssertEqual(earlier.cells.filter(\.activeSearch).map(\.col).sorted(), [0, 1, 2])
        XCTAssertEqual(controller.findStatus, "")
        controller.perform(.findPrevious)
        XCTAssertEqual(controller.findStatus, "Wrapped")
        let wrapped = try XCTUnwrap(terminal.session.snapshot())
        XCTAssertEqual(wrapped.cells.filter(\.activeSearch).map(\.col).sorted(), [8, 9, 10])
        controller.findQuery = "Nope"
        controller.runSearch("latest")
        XCTAssertEqual(controller.findStatus, "Not found")
        controller.closeFind()
        XCTAssertFalse(controller.findBarVisible)
        let cleared = try XCTUnwrap(terminal.session.snapshot())
        XCTAssertTrue(cleared.cells.allSatisfy { !$0.search && !$0.activeSearch })
    }
    @MainActor func testClosingFindClearsHighlightsInEveryPane() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.active)
        _ = try first.session.call("feed", ["text": "one two one"])
        controller.perform(.find)
        controller.findQuery = "one"
        controller.runSearch("latest")
        XCTAssertFalse(try XCTUnwrap(first.session.snapshot()).cells.filter(\.search).isEmpty)
        controller.perform(.split)
        XCTAssertEqual(controller.panes.count, 2)
        let second = controller.panes[1].terminal
        _ = try second.session.call("feed", ["text": "one second"])
        _ = try second.session.call("find", ["text": "one", "direction": "latest"])
        XCTAssertFalse(try XCTUnwrap(second.session.snapshot()).cells.filter(\.search).isEmpty)
        controller.closeFind()
        for pane in controller.panes {
            let cells = try XCTUnwrap(pane.terminal.session.snapshot()).cells
            XCTAssertTrue(cells.allSatisfy { !$0.search && !$0.activeSearch })
        }
    }
    @MainActor func testFindSearchesTheFocusedOrPalettePaneAndRestoresItsFocus() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.active)
        _ = try first.session.call("feed", ["text": "one first"])
        controller.perform(.split)
        XCTAssertEqual(controller.panes.count, 2)
        let second = controller.panes[1].terminal
        window.makeFirstResponder(second)
        XCTAssertTrue(controller.active === second)
        _ = try second.session.call("feed", ["text": "one two one"])
        // The find field takes focus; the search must still run in the pane that had it.
        controller.perform(.find)
        XCTAssertFalse(window.firstResponder === second)
        controller.findQuery = "one"
        controller.runSearch("latest")
        XCTAssertTrue(try XCTUnwrap(first.session.snapshot()).cells.allSatisfy { !$0.search && !$0.activeSearch })
        XCTAssertFalse(try XCTUnwrap(second.session.snapshot()).cells.filter(\.search).isEmpty)
        controller.perform(.findNext)
        XCTAssertFalse(try XCTUnwrap(second.session.snapshot()).cells.filter(\.activeSearch).isEmpty)
        XCTAssertTrue(try XCTUnwrap(first.session.snapshot()).cells.allSatisfy { !$0.activeSearch })
        // Retargeting a visible bar must clear the previous pane, including its active hit.
        controller.showFind(first)
        controller.runSearch("latest")
        XCTAssertTrue(try XCTUnwrap(second.session.snapshot()).cells.allSatisfy { !$0.search && !$0.activeSearch })
        XCTAssertFalse(try XCTUnwrap(first.session.snapshot()).cells.filter(\.search).isEmpty)
        controller.showFind(second)
        controller.runSearch("latest")
        controller.closeFind()
        XCTAssertTrue(window.firstResponder === second)
        // A palette command names its pane even while another pane holds focus.
        window.makeFirstResponder(first)
        controller.perform(.find, target: second)
        controller.findQuery = "one"
        controller.runSearch("latest")
        XCTAssertTrue(try XCTUnwrap(first.session.snapshot()).cells.allSatisfy { !$0.search && !$0.activeSearch })
        XCTAssertFalse(try XCTUnwrap(second.session.snapshot()).cells.filter(\.search).isEmpty)
    }

    @MainActor func testVisibleFindRetargetsWhenAnotherPaneReceivesFocus() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.active)
        _ = try first.session.call("feed", ["text": "match first"])
        controller.perform(.find); controller.findQuery = "match"; controller.runSearch("latest")
        controller.perform(.split)
        let second = controller.panes[1].terminal
        window.makeFirstResponder(second)
        controller.perform(.find)
        _ = try second.session.call("feed", ["text": "match second"])
        controller.runSearch("latest")
        XCTAssertTrue(try XCTUnwrap(first.session.snapshot()).cells.allSatisfy { !$0.search })
        XCTAssertFalse(try XCTUnwrap(second.session.snapshot()).cells.filter(\.search).isEmpty)
        controller.closeFind()
        XCTAssertTrue(window.firstResponder === second)
    }

    @MainActor func testFindNavigationAfterTabSwitchUsesTheSelectedTab() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.active)
        _ = try first.session.call("feed", ["text": "match first"])
        controller.perform(.find); controller.findQuery = "match"; controller.runSearch("latest")
        try controller.newTab()
        let second = try XCTUnwrap(controller.active)
        _ = try second.session.call("feed", ["text": "match second"])
        controller.runSearch("next")
        XCTAssertTrue(try XCTUnwrap(first.session.snapshot()).cells.allSatisfy { !$0.search })
        XCTAssertFalse(try XCTUnwrap(second.session.snapshot()).cells.filter(\.search).isEmpty)
        controller.closeFind()
        XCTAssertTrue(window.firstResponder === second)
    }

    @MainActor func testEveryTabHasACloseButtonThatClosesOnlyThatTab() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        try controller.newTab()
        try controller.newTab()
        XCTAssertEqual(controller.tabChips.count, 3)
        XCTAssertEqual(controller.tabChips.map(\.isSelected), [false, false, true])
        // The selected tab shows its close button; the others show theirs on hover, but every one is there to click.
        XCTAssertEqual(controller.tabChips.map { $0.closeButton.alphaValue }, [0, 0, 1])
        XCTAssertEqual(controller.tabChips[0].closeButton.accessibilityIdentifier(), "close-terminal-tab")
        XCTAssertEqual(controller.tabChips.map(\.shortcut), ["⌘1", "⌘2", "⌘3"])
        // Tabs share the bar equally, like native tabs, and follow the window's width.
        window.contentView?.layoutSubtreeIfNeeded()
        let widths = controller.tabChips.map(\.frame.width)
        XCTAssertEqual(widths.max()! - widths.min()!, 0, accuracy: 1)
        XCTAssertGreaterThan(widths[0], 250)
        window.setContentSize(NSSize(width: 600, height: 400)); window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThan(controller.tabChips[0].frame.width, widths[0])
        controller.selectTab(at: 0); XCTAssertEqual(controller.tabChips.map(\.isSelected), [true, false, false])
        controller.selectTab(at: 7); XCTAssertEqual(controller.tabChips.map(\.isSelected), [true, false, false])
        controller.selectTab(at: 8); XCTAssertEqual(controller.tabChips.map(\.isSelected), [false, false, true], "⌘9 is the last tab")
        controller.selectTab(at: 0)
        controller.selectTab(at: 2)
        let first = controller.tabs.tabViewItems[0], middle = controller.tabs.tabViewItems[1]
        let doomed = try XCTUnwrap(((middle.view as? NSSplitView)?.arrangedSubviews.first as? TerminalPane)?.terminal)

        // A running shell asks first, and cancelling keeps it.
        controller.tabChips[1].closeButton.performClick(nil)
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        for _ in 0..<50 where window.attachedSheet != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.tabs.numberOfTabViewItems, 3)
        XCTAssertNoThrow(try doomed.session.snapshot())

        controller.tabChips[1].closeButton.performClick(nil)
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        for _ in 0..<50 where controller.tabs.numberOfTabViewItems == 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.tabs.numberOfTabViewItems, 2)
        XCTAssertFalse(controller.tabs.tabViewItems.contains(middle))
        XCTAssertEqual(controller.tabChips.count, 2)
        XCTAssertThrowsError(try doomed.session.snapshot(), "closing the tab stops its session")

        // Clicking a chip selects its tab.
        controller.tabChips[0].mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        XCTAssertTrue(controller.tabs.selectedTabViewItem === first)
        XCTAssertEqual(controller.tabChips.map(\.isSelected), [true, false])
    }

    @MainActor func testDraggingATabReordersItAndKeepsItsSession() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        try controller.newTab(); try controller.newTab()
        for (index, name) in ["one", "two", "three"].enumerated() { controller.tabs.tabViewItems[index].label = name }
        controller.selectTab(at: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(controller.active)
        func mouse(_ type: NSEvent.EventType, _ chip: TabChip, x: CGFloat) throws -> NSEvent {
            let point = chip.superview!.convert(NSPoint(x: x, y: chip.frame.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let first = controller.tabChips[0], start = first.frame.midX
        first.mouseDown(with: try mouse(.leftMouseDown, first, x: start))
        // A 2-point wobble is still a click.
        first.mouseDragged(with: try mouse(.leftMouseDragged, first, x: start + 2))
        XCTAssertEqual(controller.tabChips.map(\.label), ["one", "two", "three"])
        // Drag past the last tab: events keep going to the chip that got the mouse-down, as in AppKit.
        first.mouseDragged(with: try mouse(.leftMouseDragged, first, x: controller.tabChips[1].frame.midX))
        XCTAssertEqual(controller.tabChips.map(\.label), ["two", "one", "three"])
        first.mouseDragged(with: try mouse(.leftMouseDragged, first, x: controller.tabChips[2].frame.maxX + 40))
        first.mouseUp(with: try mouse(.leftMouseUp, first, x: controller.tabChips[2].frame.maxX + 40))
        XCTAssertEqual(controller.tabChips.map(\.label), ["two", "three", "one"])
        XCTAssertEqual(controller.tabChips.map(\.isSelected), [false, false, true])
        XCTAssertEqual(controller.tabChips.map(\.shortcut), ["⌘1", "⌘2", "⌘3"], "shortcuts follow position")
        XCTAssertTrue(controller.active === terminal)
        XCTAssertNoThrow(try terminal.session.snapshot())
        _ = try terminal.session.call("feed", ["text": "stillhere"])
        let cells = try XCTUnwrap(try terminal.session.snapshot()).cells
        XCTAssertEqual(String(cells.filter { $0.row == 0 }.sorted { $0.col < $1.col }.map(\.text).joined().suffix(9)), "stillhere")
    }

    @MainActor func testTabContextMenuClosesOtherTabsAndTabsToTheRight() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        for _ in 0..<9 { try controller.newTab() }
        for (index, item) in controller.tabs.tabViewItems.enumerated() { item.label = "t\(index)" }
        XCTAssertEqual(controller.tabChips.map(\.shortcut), ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "", "⌘9"])
        func choose(_ title: String, on index: Int) throws {
            let menu = try XCTUnwrap(controller.tabChips[index].contextMenu?())
            let entry = try XCTUnwrap(menu.items.first { $0.title == title })
            XCTAssertTrue(entry.isEnabled)
            menu.performActionForItem(at: menu.index(of: entry))
            let sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertNotNil((sheet.contentView.map(buttons) ?? []).first { $0.title == "Close" })
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let count = controller.tabs.numberOfTabViewItems
        try choose("Close Tabs to the Right", on: 6)
        for _ in 0..<100 where controller.tabs.numberOfTabViewItems == count { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.tabChips.map(\.label), ["t0", "t1", "t2", "t3", "t4", "t5", "t6"])
        XCTAssertFalse(controller.tabChips[6].contextMenu!().items.first { $0.title == "Close Tabs to the Right" }!.isEnabled)
        try choose("Close Other Tabs", on: 2)
        for _ in 0..<100 where controller.tabs.numberOfTabViewItems > 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.tabChips.map(\.label), ["t2"])
        XCTAssertFalse(controller.tabChips[0].contextMenu!().items.first { $0.title == "Close Other Tabs" }!.isEnabled)
    }

    @MainActor func testCloseRequestsShareOneSheetAndCancelKeepsTerminalAlive() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        let terminal = controller.panes[0].terminal
        controller.perform(.closePane, target: terminal)
        let sheet = try XCTUnwrap(window.attachedSheet)
        controller.perform(.closePane, target: terminal)
        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertTrue(window.attachedSheet === sheet)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        for _ in 0..<50 where window.attachedSheet != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.panes.count, 1)
        XCTAssertNoThrow(try terminal.session.snapshot())
        // A cancelled request must release the guard, allowing the next close.
        controller.perform(.closePane, target: terminal)
        let second = try XCTUnwrap(window.attachedSheet)
        window.endSheet(second, returnCode: .alertFirstButtonReturn)
        for _ in 0..<50 where !controller.panes.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(controller.panes.isEmpty)
    }

    @MainActor func testQuitCanBeCancelledAndRetriedWithoutDuplicateSheetsOrReplies() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        let window = try XCTUnwrap(controller.window), terminals = controller.panes.map(\.terminal)
        defer { window.close(); terminals.forEach { $0.shutdown() } }
        var replies: [Bool] = []
        XCTAssertEqual(app.requestTermination(terminals: terminals, window: window) { replies.append($0) }, .terminateLater)
        let sheet = try XCTUnwrap(window.attachedSheet)
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let controls = buttons(try XCTUnwrap(sheet.contentView))
        XCTAssertNotNil(controls.first { $0.title == "Quit" })
        XCTAssertEqual(controls.first { $0.title == "Cancel" }?.keyEquivalent, "\u{1b}")
        XCTAssertEqual(app.requestTermination(terminals: terminals, window: window) { _ in XCTFail("duplicate quit reply") }, .terminateLater)
        XCTAssertTrue(sheet === window.attachedSheet)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(sheet.performKeyEquivalent(with: escape))
        for _ in 0..<50 where replies.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(replies, [false])
        XCTAssertNoThrow(try terminals[0].session.snapshot())
        XCTAssertEqual(app.requestTermination(terminals: terminals, window: window) { replies.append($0) }, .terminateLater)
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        for _ in 0..<100 where replies.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(replies, [false, true])
        XCTAssertThrowsError(try terminals[0].session.snapshot())
    }

    @MainActor func testQuitDoesNotQueueBehindAnExistingSheet() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); controller.panes.forEach { $0.terminal.shutdown() } }
        controller.perform(.closePane)
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(app.requestTermination(terminals: controller.panes.map(\.terminal), window: window) { _ in XCTFail("quit was not deferred") }, .terminateCancel)
        XCTAssertTrue(sheet === window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }

    @MainActor func testStoppedTerminalIgnoresLateInputAndMouseEvents() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        _ = try terminal.session.call("feed", ["text": "\u{1b}[?1003h\u{1b}[?1006h"])
        terminal.poll()
        for _ in 0..<100 where terminal.snapshot?.mouse_motion != true { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(terminal.snapshot?.mouse_motion, true)
        let done = expectation(description: "terminal cleanup")
        terminal.shutdown { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        var messages: [String] = []
        terminal.onStatus = { messages.append($0) }
        terminal.send("late text")
        terminal.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        XCTAssertTrue(messages.isEmpty)
    }

    @MainActor func testPlainClickClearsSelectionTextAndHighlight() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        var statuses: [String] = []
        terminal.onStatus = { statuses.append($0) }
        _ = try terminal.session.call("feed", ["text": "hello world"])
        try await waitUntil(terminal, timeout: 3) { terminal.snapshot?.text.hasPrefix("hello world") == true }
        terminal.selectCells(from: (0, 0), to: (0, 4))
        try await waitUntil(terminal, timeout: 3) {
            terminal.accessibilitySelectedText() == "hello" && terminal.snapshot?.cells.contains(where: \.selected) == true
        }
        XCTAssertEqual(statuses.filter { !$0.contains("cols") && !$0.contains("Software rendering") }, [], "status: \(statuses)")
        XCTAssertEqual(terminal.accessibilitySelectedText(), "hello")
        // A plain click starts a new selection anchor, so the old text and highlight must go.
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: click)
        XCTAssertEqual(terminal.accessibilitySelectedText(), "")
        XCTAssertEqual(terminal.accessibilitySelectedTextRange().location, NSNotFound)
        XCTAssertTrue(try XCTUnwrap(terminal.snapshot).cells.allSatisfy { !$0.selected })
        // Later polls keep the core's old mark from coming back.
        try await waitUntil(terminal, timeout: 1) { false }
        XCTAssertTrue(try XCTUnwrap(terminal.snapshot).cells.allSatisfy { !$0.selected })
    }

    @MainActor func testPasteOfControlTextWithoutAWindowFailsClosed() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        var messages: [String] = []
        terminal.onStatus = { messages.append($0) }
        terminal.paste("safe\nrm -rf /")
        XCTAssertNil(terminal.window)
        XCTAssertEqual(messages, ["Paste requires confirmation, but the terminal is not in a window"])
    }

    @MainActor func testPreferencesChangeAfterShutdownIsIgnored() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let done = expectation(description: "terminal cleanup")
        terminal.shutdown { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        var messages: [String] = []
        terminal.onStatus = { messages.append($0) }
        NotificationCenter.default.post(name: .terminalPreferencesChanged, object: nil)
        terminal.applyPreferences(TerminalPreferences())
        XCTAssertTrue(messages.isEmpty)
    }

    func testFolderOpenRequestResolvesFoldersAndCountsSkippedItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-open-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("project"); let file = folder.appendingPathComponent("README.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = folderOpenRequest(from: [folder, file, root.appendingPathComponent("missing"), URL(string: "https://example.com/")!])
        // The file resolves to its folder, which is already requested, so it is not opened twice.
        XCTAssertEqual(request, FolderOpenRequest(directories: [folder.standardizedFileURL.path], skipped: 2))
        let many = try (0..<3).map { index -> URL in
            let url = root.appendingPathComponent("many-\(index)"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        XCTAssertEqual(folderOpenRequest(from: many, limit: 2), FolderOpenRequest(directories: many.prefix(2).map(\.standardizedFileURL.path), skipped: 1))
    }
    @MainActor func testOpenedFolderWindowStartsEveryTabInThatFolder() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true, directory: directory)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        XCTAssertEqual(controller.directory, directory)
        try controller.newTab()
        XCTAssertEqual(controller.tabs.numberOfTabViewItems, 2)
    }
    @MainActor func testOpenedFolderReachesTheShell() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try TerminalView(headless: false, forceSoftware: true, directory: directory.path)
        defer { terminal.shutdown() }
        try terminal.session.input("pwd -P > akitty-cwd.txt\r")
        let marker = directory.appendingPathComponent("akitty-cwd.txt")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 50_000_000) }
        let reported = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // Both sides go through the same symlink normalization (the temp folder sits under the /var -> /private/var link).
        XCTAssertEqual(URL(fileURLWithPath: reported).resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
    }

    /// Text output and typing, not only graphics, switch to display-rate polling, so an echo or a scrolling
    /// screen is shown on the next frame instead of waiting up to 33 ms for the idle timer.
    @MainActor func testOutputAndTypingPollAtDisplayRate() async throws {
        _ = NSApplication.shared
        func hosted(_ view: TerminalView) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            return window
        }
        let output = try TerminalView(headless: true, forceSoftware: true)
        defer { output.shutdown() }
        let outputWindow = hosted(output)
        defer { outputWindow.close() }
        for _ in 0..<100 where output.snapshot == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = try output.session.call("feed", ["text": "streaming output"])
        output.poll()
        for _ in 0..<100 where output.snapshot?.text.contains("streaming output") != true { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(output.pollsAtDisplayRate, "a changed snapshot keeps polling at display rate")

        let shell = try TerminalView(headless: false, forceSoftware: true)
        defer { shell.shutdown() }
        let shellWindow = hosted(shell)
        defer { shellWindow.close() }
        // Wait until the shell has settled, so only the keystroke can restart fast polling.
        for _ in 0..<300 where shell.pollsAtDisplayRate || shell.snapshot == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try XCTSkipIf(shell.pollsAtDisplayRate, "shell kept printing; cannot isolate the keystroke")
        shell.send("x")
        XCTAssertTrue(shell.pollsAtDisplayRate, "accepted input polls at display rate at once")
    }

    @MainActor func testAViewWhoseWindowGoesAwayMidAnimationIsReleased() async throws {
        weak var released: TerminalView?
        var window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window?.isReleasedWhenClosed = false
        do {
            let view = try TerminalView(headless: true, forceSoftware: true)
            released = view
            window?.contentView = view
            for _ in 0..<100 where view.snapshot == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            _ = try view.session.call("feed", ["text": "frames moving"])
            view.poll()
            for _ in 0..<100 where !view.pollsAtDisplayRate { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(view.pollsAtDisplayRate, "the display link is live")
        }
        // Drop the window and the view without `shutdown()`: neither the display link nor its run loop may keep the view alive.
        window = nil
        for _ in 0..<100 where released != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(released, "a running display link does not keep its view alive")
    }

    @MainActor func testFailedShellStartupThrowsWithoutUninitializedNSViewCrash() async {
        var preferences = TerminalPreferences(); preferences.shell = "/does-not-exist/akitty-test-shell"
        XCTAssertThrowsError(try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences))
    }

    func testImagePixelReadRejectsOverflowingDimensions() throws {
        let session = try TerminalSession(headless: true)
        defer { try? session.close() }
        for (width, height) in [(Int.max, 2), (2, Int.max), (Int.min, -1), (0, 1), (8_388_609, 1)] {
            XCTAssertNil(session.imagePixels(0, width: width, height: height))
        }
    }

    func testSavedPreferencesWithoutProgramChromeStayEnabled() throws {
        let saved = #"{"fontName":"Menlo","fontSize":16,"shell":"","directory":"","scrollback":1000,"optionAsAlt":true}"#
        let loaded = try JSONDecoder().decode(TerminalPreferences.self, from: Data(saved.utf8))
        XCTAssertTrue(loaded.programChrome)
        XCTAssertEqual(loaded.fontName, "Menlo")
        XCTAssertEqual(loaded.fontSize, 16)
        var disabled = loaded
        disabled.programChrome = false
        let again = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(disabled))
        XCTAssertFalse(again.programChrome)
        XCTAssertEqual(again.fontName, "Menlo")
    }

    @MainActor func testChromeStatusDoesNotReplaceWindowOrTabTitle() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        let sequence = "\u{1b}[22t\u{1b}]2;vim\u{07}OK\u{1b}]771;{\"status\":{\"text\":\"building\",\"tone\":\"info\"},\"progress\":0.5}\u{07}"
        _ = try pane.terminal.session.call("feed", ["text": sequence])
        try await waitUntil(pane.terminal, timeout: 3) {
            pane.status.stringValue.contains("building") && pane.status.stringValue.contains("50%") && controller.window?.title == "vim — Akitty"
        }
        XCTAssertEqual(controller.window?.title, "vim — Akitty")
        XCTAssertEqual(controller.tabs.tabViewItems.first?.label, "vim")
        XCTAssertEqual(tabLabel(controller), "vim")
        XCTAssertFalse(controller.window?.title.contains("building") == true)
        XCTAssertEqual(pane.status.stringValue.contains("building"), true)
        XCTAssertEqual(pane.status.stringValue.contains("50%"), true)
        XCTAssertTrue(pane.terminal.snapshot?.text.hasPrefix("OK") == true)
        XCTAssertFalse(pane.terminal.snapshot?.text.contains("771") == true)
        _ = try pane.terminal.session.call("feed", ["text": "\u{1b}[23t"])
        try await waitUntil(pane.terminal, timeout: 3) { controller.window?.title == "Akitty" }
        XCTAssertEqual(controller.window?.title, "Akitty")
        XCTAssertEqual(controller.tabs.tabViewItems.first?.label, "Akitty")
        XCTAssertEqual(tabLabel(controller), "Akitty")
        XCTAssertEqual(pane.status.stringValue.contains("building"), true)
    }

    @MainActor func testChromeStatusAndProgressShowUntilClearOrExpiry() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        _ = try pane.terminal.session.call("chrome", [
            "status": ["text": "packing", "tone": "info"],
            "progress": "indeterminate"
        ])
        try await waitUntil(pane.terminal, timeout: 2) { pane.status.stringValue.contains("packing") && pane.status.stringValue.contains("…") }
        XCTAssertEqual(pane.status.stringValue.contains("packing"), true, pane.status.stringValue)
        XCTAssertEqual(pane.status.stringValue.contains("…"), true, pane.status.stringValue)
        let shown = pane.terminal.snapshot?.chrome
        _ = try pane.terminal.session.call("feed", ["text": "x"])
        try await waitUntil(pane.terminal, timeout: 2) { pane.terminal.snapshot?.text.contains("x") == true }
        XCTAssertEqual(pane.terminal.snapshot?.chrome, shown)
        _ = try pane.terminal.session.call("chrome", ["clear": true])
        try await waitUntil(pane.terminal, timeout: 2) { !pane.status.stringValue.contains("packing") }
        XCTAssertFalse(pane.status.stringValue.contains("packing"), pane.status.stringValue)
        XCTAssertNil(pane.terminal.snapshot?.chrome)
        let expires = Int(Date().timeIntervalSince1970 * 1000) + 2_000
        _ = try pane.terminal.session.call("chrome", [
            "status": ["text": "expiring", "tone": "warn", "expires": expires],
            "progress": 0.5
        ])
        try await waitUntil(pane.terminal, timeout: 1.5) {
            pane.status.stringValue.contains("expiring") && pane.status.stringValue.contains("50%")
        }
        XCTAssertEqual(pane.status.stringValue.contains("expiring"), true, pane.status.stringValue)
        XCTAssertEqual(pane.status.stringValue.contains("50%"), true, pane.status.stringValue)
        try await waitUntil(pane.terminal, timeout: 4) { !pane.status.stringValue.contains("expiring") }
        XCTAssertFalse(pane.status.stringValue.contains("expiring"), pane.status.stringValue)
        XCTAssertFalse(pane.status.stringValue.contains("50%"), pane.status.stringValue)
    }

    @MainActor func testSpriteMarkUsesFrameZeroWhenReduceMotionIsOn() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        let frame0 = Data([0x10, 0x20, 0x30, 0xFF])
        let frame1 = Data([0x40, 0x50, 0x60, 0xFF])
        controller.reduceMotion = false
        _ = try pane.terminal.session.call("chrome", [
            "mark": 1,
            "sprite": ["w": 1, "h": 1, "frames": [frame0.base64EncodedString(), frame1.base64EncodedString()]]
        ])
        try await waitUntil(pane.terminal, timeout: 3) { chromeMark(controller)?.chromePixels == frame1 }
        let moving = try XCTUnwrap(chromeMark(controller))
        XCTAssertEqual(moving.chromePixels, frame1)
        XCTAssertEqual(moving.bitmapPixels, frame1)
        XCTAssertEqual(moving.view.accessibilityIdentifier(), "chrome-sprite")
        XCTAssertEqual(moving.layoutAttribute, .left)
        controller.reduceMotion = true
        let still = try XCTUnwrap(chromeMark(controller))
        XCTAssertEqual(still.chromePixels, frame0)
        XCTAssertEqual(still.bitmapPixels, frame0)
        controller.refreshUpdateReminder("0.7.0")
        let identifiers = controller.window?.titlebarAccessoryViewControllers.map { $0.view.accessibilityIdentifier() } ?? []
        XCTAssertTrue(identifiers.contains("chrome-sprite"))
        XCTAssertTrue(identifiers.contains("update-reminder"))
        XCTAssertEqual(controller.window?.titlebarAccessoryViewControllers.count, 2)
        controller.refreshUpdateReminder(nil)
        XCTAssertEqual(controller.window?.titlebarAccessoryViewControllers.map { $0.view.accessibilityIdentifier() }, ["chrome-sprite"])
        XCTAssertEqual(chromeMark(controller)?.chromePixels, frame0)
    }

    func testChromeSpriteDecodingEnforcesABIBoundsWithoutTrapping() throws {
        func decode(_ object: [String: Any]) -> ChromeSprite? {
            try? JSONDecoder().decode(ChromeSprite.self, from: JSONSerialization.data(withJSONObject: object))
        }
        func frame(_ w: Int, _ h: Int) -> String { Data(count: w * h * 4).base64EncodedString() }
        XCTAssertEqual(decode(["w": 1, "h": 1, "frames": [frame(1, 1)]])?.frames.count, 1)
        XCTAssertEqual(decode(["w": 32, "h": 32, "frames": Array(repeating: frame(32, 32), count: 4)])?.w, 32)
        let invalid: [[String: Any]] = [
            ["w": -1, "h": 1, "frames": [frame(1, 1)]],
            ["w": 0, "h": 1, "frames": [frame(1, 1)]],
            ["w": 33, "h": 1, "frames": [frame(33, 1)]],
            ["w": 1, "h": 33, "frames": [frame(1, 33)]],
            ["w": 1, "h": 1, "frames": [String]()],
            ["w": 1, "h": 1, "frames": Array(repeating: frame(1, 1), count: 5)],
            ["w": 1, "h": 1, "frames": [Data(count: 3).base64EncodedString()]],
            ["w": Int.max, "h": Int.max, "frames": [frame(1, 1)]]
        ]
        for object in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(ChromeSprite.self, from: JSONSerialization.data(withJSONObject: object))) { error in
                XCTAssertTrue(error is DecodingError, "\(object) threw \(error)")
            }
        }
    }

    @MainActor func testProgramChromeOffIgnoresTerminalSequenceButNotAbi() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        var preferences = TerminalPreferences()
        preferences.programChrome = false
        pane.terminal.applyPreferences(preferences)
        _ = try pane.terminal.session.call("feed", ["text": "\u{1b}]771;{\"status\":{\"text\":\"hidden-osc\",\"tone\":\"error\"},\"progress\":1}\u{07}NO"])
        try await waitUntil(pane.terminal, timeout: 3) { pane.terminal.snapshot?.text.hasPrefix("NO") == true }
        XCTAssertFalse(pane.status.stringValue.contains("hidden-osc"), pane.status.stringValue)
        XCTAssertNil(pane.terminal.snapshot?.chrome?.presentation)
        XCTAssertFalse(pane.terminal.snapshot?.text.contains("771") == true)
        _ = try pane.terminal.session.call("chrome", [
            "status": ["text": "from-abi", "tone": "info"],
            "progress": "indeterminate"
        ])
        try await waitUntil(pane.terminal, timeout: 3) {
            pane.status.stringValue.contains("from-abi") && pane.status.stringValue.contains("…")
        }
        XCTAssertEqual(pane.status.stringValue.contains("from-abi"), true, pane.status.stringValue)
        XCTAssertEqual(pane.status.stringValue.contains("…"), true, pane.status.stringValue)
        let revision = pane.terminal.snapshot?.revision
        _ = try pane.terminal.session.call("feed", ["text": "\u{1b}]771;{\"clear\":true}\u{07}"])
        try await waitUntil(pane.terminal, timeout: 2) { pane.terminal.snapshot?.revision != revision }
        XCTAssertEqual(pane.status.stringValue.contains("from-abi"), true, pane.status.stringValue)
        XCTAssertEqual(pane.terminal.snapshot?.chrome?.status?.text, "from-abi")
    }

    @MainActor private func waitUntil(_ view: TerminalView, timeout: TimeInterval, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            view.poll()
            try await Task.sleep(nanoseconds: 20_000_000)
            if predicate() { return }
        }
    }

    @MainActor private func tabLabel(_ controller: TerminalWindow) -> String? { controller.tabChips.first?.label }

    @MainActor private func chromeMark(_ controller: TerminalWindow) -> ChromeMarkAccessory? {
        controller.window?.titlebarAccessoryViewControllers.compactMap { $0 as? ChromeMarkAccessory }.first
    }

}

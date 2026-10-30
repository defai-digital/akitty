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

    @MainActor func testFailedShellStartupThrowsWithoutUninitializedNSViewCrash() async {
        var preferences = TerminalPreferences(); preferences.shell = "/does-not-exist/akitty-test-shell"
        XCTAssertThrowsError(try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences))
    }

}

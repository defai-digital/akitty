import XCTest
import AppKit
@testable import AkittyKit

final class ProfileTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "akitty-profiles-" + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testPreferencesWithoutProfilesKeepTheBuiltInLook() throws {
        let older = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"fontName":"Menlo","fontSize":18}"#.utf8))
        XCTAssertEqual(older.theme, TerminalTheme.defaultID)
        XCTAssertEqual(older.cursorStyle, .outline)
        XCTAssertTrue(older.profiles.isEmpty)
        XCTAssertEqual(older.effective(profile: UUID()), older, "an unknown profile falls back to the defaults")
        XCTAssertEqual(TerminalTheme.named(older.theme).appearance(cursorStyle: older.cursorStyle), .standard)
        XCTAssertTrue(TerminalTheme.named("akitty-dark").request.isEmpty, "the default theme restores the core's baseline")
    }

    func testProfilesRoundTripAndOverrideOnlyTheirOwnFields() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        var settings = TerminalPreferences(); settings.silentMode = true; settings.cjkFont = ""
        var profile = TerminalProfile(name: "Light Work", from: settings)
        profile.theme = "akitty-light"; profile.cursorStyle = .bar; profile.fontSize = 20; profile.scrollback = 1000
        profile.directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        settings.profiles = [profile]
        try settings.save(to: store)
        let loaded = TerminalPreferences.load(from: store)
        XCTAssertEqual(loaded.profiles, [profile])
        let effective = loaded.effective(profile: profile.id)
        XCTAssertEqual(effective.theme, "akitty-light"); XCTAssertEqual(effective.cursorStyle, .bar)
        XCTAssertEqual(effective.fontSize, 20); XCTAssertEqual(effective.scrollback, 1000)
        XCTAssertEqual(effective.directory, profile.directory)
        XCTAssertTrue(effective.silentMode, "settings a profile does not name follow the defaults")
        XCTAssertEqual(effective.profiles, loaded.profiles)
    }

    func testSavingRejectsDuplicateOrEmptyNamesAndUnknownThemes() throws {
        var settings = TerminalPreferences()
        settings.profiles = [TerminalProfile(name: "Work", from: settings), TerminalProfile(name: " work ", from: settings)]
        XCTAssertThrowsError(try settings.validated())
        settings.profiles = [TerminalProfile(name: "  ", from: settings)]
        XCTAssertThrowsError(try settings.validated())
        settings.profiles = [TerminalProfile(name: "Work", from: settings)]
        settings.profiles[0].theme = "neon"
        XCTAssertThrowsError(try settings.validated())
        settings.profiles[0].theme = "solarized-dark"
        XCTAssertNoThrow(try settings.validated())
        XCTAssertEqual(settings.unusedProfileName("Work"), "Work 2")
        XCTAssertEqual(settings.unusedProfileName(), "Profile")
    }

    func testLoadRepairsABrokenProfileWithoutDroppingOthers() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let good = UUID(), broken = UUID()
        let json = """
        {"fontName":"Menlo","theme":"akitty-light","profiles":[
          {"id":"\(good.uuidString)","name":"Good","fontName":"Menlo","fontSize":15,"theme":"solarized-dark","cursorStyle":"underline","shell":"","directory":"","scrollback":2000},
          {"id":"\(broken.uuidString)","name":"good","fontName":"No Such Font 123","fontSize":99,"theme":"gone","cursorStyle":"sparkle","shell":"/no/such/shell","directory":"/no/such/dir","scrollback":-4}
        ]}
        """
        store.set(Data(json.utf8), forKey: "terminalPreferences")
        let loaded = TerminalPreferences.load(from: store)
        XCTAssertEqual(loaded.theme, "akitty-light", "valid defaults survive a broken profile")
        XCTAssertEqual(loaded.profiles.map(\.id), [good, broken])
        XCTAssertEqual(loaded.profiles[0].theme, "solarized-dark"); XCTAssertEqual(loaded.profiles[0].cursorStyle, .underline)
        let repaired = loaded.profiles[1]
        XCTAssertEqual(repaired.name, "good 2", "names are made unique")
        XCTAssertEqual(repaired.fontName, "Menlo"); XCTAssertEqual(repaired.theme, "akitty-light")
        XCTAssertEqual(repaired.cursorStyle, .outline); XCTAssertEqual(repaired.shell, "")
        XCTAssertEqual(repaired.directory, ""); XCTAssertEqual(repaired.scrollback, TerminalPreferences().scrollback)
        XCTAssertEqual(repaired.fontSize, TerminalPreferences().fontSize)
        XCTAssertNoThrow(try loaded.validated())
    }

    @MainActor func testPaneUsesItsProfileThemeAndFallsBackWhenTheProfileIsDeleted() async throws {
        _ = NSApplication.shared
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        var settings = TerminalPreferences()
        var profile = TerminalProfile(name: "Light", from: settings); profile.theme = "akitty-light"; profile.cursorStyle = .block
        settings.profiles = [profile]
        try settings.save(to: store)
        let terminal = try TerminalView(headless: true, forceSoftware: true, forceShaderFailure: false,
                                        initial: settings.effective(profile: profile.id), defaults: store, profile: profile.id)
        defer { terminal.shutdown() }
        XCTAssertEqual(terminal.renderAppearance.background, [0xfa, 0xfa, 0xfa])
        XCTAssertEqual(terminal.renderAppearance.cursorStyle, .block)
        _ = try terminal.session.call("feed", ["text": "x"])
        let cell = try XCTUnwrap(terminal.session.snapshot()?.cells.first { $0.text == "x" })
        XCTAssertEqual(cell.bg, [0xfa, 0xfa, 0xfa], "the core resolves cell colours from the profile theme")
        XCTAssertEqual(cell.fg, [0x1f, 0x23, 0x28])
        // Deleting the profile in Settings returns the open pane to the default look.
        settings.profiles = []; try settings.save(to: store)
        XCTAssertEqual(terminal.renderAppearance, .standard)
        let reset = try XCTUnwrap(terminal.session.snapshot()?.cells.first { $0.text == "x" })
        XCTAssertEqual(reset.bg, RenderAppearance.standard.background)
    }

    @MainActor func testRasterizerPaintsThemeBackgroundAndEachCursorStyle() throws {
        _ = NSApplication.shared
        let session = try TerminalSession(headless: true); defer { try? session.close() }
        let theme = TerminalTheme.named("akitty-light")
        _ = try session.call("theme", theme.request)
        let snapshot = try XCTUnwrap(session.snapshot())
        let size = CGSize(width: 200, height: 60), cell = CGSize(width: 10, height: 20)
        func render(_ style: CursorStyle) throws -> CGContext {
            try GridRasterizer.make(snapshot: snapshot, size: size, scale: 1, fontName: "Menlo", fontSize: 14, cellSize: cell, composition: "",
                                    appearance: theme.appearance(cursorStyle: style))
        }
        /// Device RGB of a pixel, with y measured from the top of the bitmap.
        func rgb(_ context: CGContext, _ x: Int, _ y: Int) -> [UInt8] {
            let data = context.data!.assumingMemoryBound(to: UInt8.self), offset = y * context.bytesPerRow + x * 4
            return [data[offset + 2], data[offset + 1], data[offset]]
        }
        /// A theme colour as the device-RGB bitmap stores it, so the comparison does not depend on the display profile.
        func device(_ value: [UInt8]) -> [UInt8] {
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(value[0]) / 255, green: CGFloat(value[1]) / 255, blue: CGFloat(value[2]) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            return rgb(context, 0, 0)
        }
        let background = device([0xfa, 0xfa, 0xfa]), cursor = device([0x09, 0x69, 0xda])
        let outline = try render(.outline)
        XCTAssertEqual(rgb(outline, 150, 50), background, "the frame clears to the theme background")
        // The cursor cell at (0,0) spans x 8..<18, y 8..<28 below the 8 pt margin.
        let bar = try render(.bar), underline = try render(.underline), block = try render(.block)
        XCTAssertEqual(rgb(bar, 8, 18), cursor); XCTAssertEqual(rgb(bar, 15, 18), background)
        XCTAssertEqual(rgb(underline, 13, 27), cursor); XCTAssertEqual(rgb(underline, 13, 15), background)
        XCTAssertNotEqual(rgb(block, 13, 18), background); XCTAssertNotEqual(rgb(block, 13, 18), cursor, "a filled block is translucent")
        XCTAssertEqual(rgb(outline, 13, 18), background, "an outline leaves the cell interior clear")
    }

    @MainActor func testTabsAndSplitsInheritTheFocusedPaneProfile() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(), work = UUID()
        let controller = try TerminalWindow(app: app, headless: true, profile: work)
        let window = try XCTUnwrap(controller.window)
        defer { controller.panes.forEach { $0.terminal.shutdown() }; window.close() }
        XCTAssertEqual(controller.panes.map(\.terminal.profileID), [work])
        let split = try controller.splitPane(containing: controller.panes[0].terminal)
        XCTAssertEqual(split.profileID, work, "a split keeps the profile of the pane it splits")
        try controller.newTab()
        XCTAssertEqual(controller.selectedPane?.profileID, work)
        // An explicit default-settings tab stays on the defaults, and so do tabs opened from it.
        try controller.newTab(profile: nil)
        let plain = try XCTUnwrap(controller.selectedPane)
        XCTAssertNil(plain.profileID)
        window.makeFirstResponder(plain)
        try controller.newTab()
        XCTAssertNil(controller.selectedPane?.profileID, "a defaults pane does not fall back to the window's profile")
    }

    func testOneMalformedSavedProfileDoesNotDropTheOthers() throws {
        let json = #"{"profiles":[{"name":"Good","fontSize":15},{"name":"Bad","fontSize":"twenty"},{"name":"Also good","theme":"high-contrast"}]}"#
        let decoded = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.profiles.map(\.name), ["Good", "Also good"])
    }

    func testGeneratedProfileNamesStayWithinTheLimit() throws {
        var settings = TerminalPreferences()
        let long = String(repeating: "n", count: TerminalProfile.maximumNameLength)
        settings.profiles = [TerminalProfile(name: long, from: settings)]
        let copy = settings.unusedProfileName(long + " Copy")
        XCTAssertLessThanOrEqual(copy.count, TerminalProfile.maximumNameLength)
        XCTAssertNotEqual(copy.lowercased(), long.lowercased())
        settings.profiles.append(TerminalProfile(name: copy, from: settings))
        XCTAssertNoThrow(try settings.validated(), "a duplicated long-named profile can still be applied")
    }

    func testThemeAppearanceCarriesItsForegroundForComposedText() {
        XCTAssertEqual(TerminalTheme.named("akitty-light").appearance(cursorStyle: .outline).foreground, [0x1f, 0x23, 0x28])
        XCTAssertEqual(TerminalTheme.named("akitty-dark").appearance(cursorStyle: .outline).foreground, RenderAppearance.standard.foreground)
    }

    @MainActor func testTabChosenWithAProfileDoesNotCopyTheFocusedFolder() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(), opened = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let controller = try TerminalWindow(app: app, headless: true, directory: opened)
        let window = try XCTUnwrap(controller.window)
        defer { controller.panes.forEach { $0.terminal.shutdown() }; window.close() }
        try controller.newTab()
        XCTAssertEqual(controller.panes.last?.launchDirectory, opened, "⌘T keeps following the window's folder")
        try controller.newTab(profile: UUID(), copyDirectory: false)
        XCTAssertNil(controller.panes.first { $0.terminal === controller.selectedPane }?.launchDirectory,
                     "a profile tab starts in the profile's folder, not the focused pane's")
    }
}

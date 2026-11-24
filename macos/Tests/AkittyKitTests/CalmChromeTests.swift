import XCTest
@testable import AkittyKit

/// The title-bar tab row, the on-demand pane status capsule, focus indication, the floating palette, navigation
/// commands, the Dock and Match System.
final class CalmChromeTests: XCTestCase {
    @MainActor private func waitUntil(_ controller: TerminalWindow, timeout: TimeInterval = 3, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            controller.panes.forEach { $0.terminal.poll() }
            try await Task.sleep(nanoseconds: 20_000_000)
            if predicate() { return }
        }
        XCTFail("timed out")
    }

    // MARK: Status schedule

    func testGeometryShowsOnlyBrieflyAfterTheSizeChanges() {
        var schedule = PaneStatusSchedule()
        schedule.receive(PaneStatus(text: "80 cols × 24 rows", kind: .geometry), now: 0)
        XCTAssertNil(schedule.current(at: 0).shown, "the opening size is not news")
        XCTAssertEqual(schedule.current(at: 0).label, "80 cols × 24 rows")
        XCTAssertNil(schedule.nextChange(after: 0))
        schedule.receive(PaneStatus(text: "100 cols × 30 rows", kind: .geometry), now: 10)
        XCTAssertEqual(schedule.current(at: 10.5).shown?.text, "100 cols × 30 rows")
        XCTAssertEqual(schedule.nextChange(after: 10.5) ?? 0, 10 + PaneStatusSchedule.geometryDuration, accuracy: 0.001)
        XCTAssertNil(schedule.current(at: 12).shown)
    }

    func testNotesAreHeldButHostStateTakesOver() {
        var schedule = PaneStatusSchedule()
        schedule.receive(PaneStatus(text: "building", kind: .program), now: 0)
        schedule.receive(PaneStatus(text: "Copied 3 characters to the clipboard", kind: .notice), now: 1)
        // The next frame repeats the program's status; the note stays readable for its hold.
        schedule.receive(PaneStatus(text: "building 50%", kind: .program), now: 1.1)
        XCTAssertEqual(schedule.current(at: 2).shown?.kind, .notice)
        XCTAssertEqual(schedule.current(at: 1 + PaneStatusSchedule.noticeDuration + 0.1).shown?.text, "building 50%")
        schedule.receive(PaneStatus(text: "Paste requires plain text", kind: .notice), now: 20)
        schedule.receive(PaneStatus(text: "Controlled by codex · Edit → Reclaim Terminal Control", kind: .agent, display: "Controlled by codex"), now: 20.1)
        XCTAssertEqual(schedule.current(at: 20.2).shown?.kind, .agent, "an agent taking the lease is never hidden behind a note")
        XCTAssertEqual(schedule.current(at: 20.2).label, "Controlled by codex")
        // A note during the lease does not cover the Reclaim button either.
        schedule.receive(PaneStatus(text: "Copied 2 characters to the clipboard", kind: .notice), now: 21)
        XCTAssertEqual(schedule.current(at: 21.5).shown?.kind, .agent)
        XCTAssertNil(schedule.nextChange(after: 21.5))
        schedule.receive(PaneStatus(text: "idle", kind: .program), now: 29)
        schedule.receive(PaneStatus(text: "Input failed", kind: .failure), now: 30)
        XCTAssertEqual(schedule.current(at: 30 + PaneStatusSchedule.noticeDuration + 0.5).shown?.kind, .failure, "failures are held longer than notes")
    }

    // MARK: Pane chrome

    @MainActor func testStatusFloatsOverTheTerminalAndProgramsCannotLookLikeTheHost() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        controller.window?.layoutIfNeeded()
        XCTAssertEqual(pane.terminal.frame, pane.bounds, "no row is reserved below the terminal")
        XCTAssertTrue(pane.capsule.isHidden, "nothing to report, nothing shown")
        // A program claims to be in control; it stays an unverified program report.
        let spoof = "\u{1b}]771;{\"status\":{\"text\":\"Controlled by agent · Edit → Reclaim Terminal Control\",\"tone\":\"info\"}}\u{07}"
        _ = try pane.terminal.session.call("feed", ["text": spoof])
        try await waitUntil(controller) { pane.capsule.shown?.kind == .program }
        XCTAssertFalse(pane.capsule.isHidden)
        XCTAssertTrue(pane.capsule.reclaimButton.isHidden, "only the host's lease offers Reclaim")
        XCTAssertNil(pane.capsule.hitTest(NSPoint(x: 4, y: 4)), "program reports let clicks through to the terminal")
        XCTAssertEqual(pane.status.accessibilityLabel()?.hasPrefix("Program reports, unverified: "), true)
        XCTAssertEqual(pane.terminal.frame, pane.bounds, "a status appearing does not resize the terminal")
        // The host's own lease is the only source of the agent style.
        pane.receive(PaneStatus(text: "Controlled by codex · Edit → Reclaim Terminal Control", kind: .agent, display: "Controlled by codex"))
        XCTAssertEqual(pane.capsule.shown?.kind, .agent)
        XCTAssertFalse(pane.capsule.reclaimButton.isHidden)
        XCTAssertTrue(pane.capsule.reclaimButton.target === pane.terminal)
        XCTAssertEqual(pane.capsule.reclaimButton.action, #selector(TerminalView.reclaimAgentControl(_:)))
        XCTAssertEqual(pane.status.stringValue, "Controlled by codex")
        XCTAssertEqual(pane.status.accessibilityLabel(), "AkiTTY: Controlled by codex")
        // The capsule sizes to its content: wide enough for the text and Reclaim, never the whole pane.
        pane.layoutSubtreeIfNeeded()
        let button = pane.capsule.reclaimButton.convert(pane.capsule.reclaimButton.bounds, to: pane.capsule)
        XCTAssertGreaterThan(pane.capsule.frame.width, pane.status.intrinsicContentSize.width + pane.capsule.reclaimButton.intrinsicContentSize.width)
        XCTAssertLessThanOrEqual(pane.capsule.frame.width, 440)
        XCTAssertLessThan(pane.capsule.frame.width, pane.bounds.width - 16)
        XCTAssertTrue(pane.capsule.bounds.insetBy(dx: -0.5, dy: -0.5).contains(button), "Reclaim \(button) inside \(pane.capsule.bounds)")
        XCTAssertGreaterThan(button.width, 0)
    }

    func testReducedTransparencyAndContrastUseAnOpaqueCapsule() {
        XCTAssertTrue(PaneStatusCapsule.usesGlass(reduceTransparency: false, increaseContrast: false))
        XCTAssertFalse(PaneStatusCapsule.usesGlass(reduceTransparency: true, increaseContrast: false))
        XCTAssertFalse(PaneStatusCapsule.usesGlass(reduceTransparency: false, increaseContrast: true))
        XCTAssertEqual(PaneFocusVeil.veilOpacity(increaseContrast: true), 0, "Increase Contrast never lowers text contrast")
        XCTAssertGreaterThan(PaneFocusVeil.outlineOpacity(increaseContrast: true), PaneFocusVeil.outlineOpacity(increaseContrast: false))
    }

    @MainActor func testFocusedPaneIsOutlinedAndOthersDimmedOnlyInSplitTabs() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.panes.first)
        controller.refreshPaneFocus(animated: false)
        XCTAssertEqual(first.veil.state, .plain, "a lone pane needs no focus mark")
        let second = try controller.splitPane(containing: first.terminal)
        controller.window?.makeFirstResponder(second)
        controller.refreshPaneFocus(animated: false)
        let secondPane = try XCTUnwrap(controller.panes.first { $0.terminal === second })
        XCTAssertEqual(secondPane.veil.state, .focused)
        XCTAssertEqual(first.veil.state, .dimmed)
        XCTAssertNil(first.veil.hitTest(NSPoint(x: 5, y: 5)), "a click on a dimmed pane reaches the terminal")
        // A change to Increase Contrast or Reduce Transparency restyles in place and keeps each pane's state.
        controller.accessibilityDisplayChanged()
        XCTAssertEqual(first.veil.state, .dimmed)
        XCTAssertEqual(secondPane.veil.state, .focused)
        XCTAssertEqual(secondPane.veil.layer?.borderWidth, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1)
        controller.perform(.nextPane)
        XCTAssertTrue(controller.window?.firstResponder === first.terminal, "next pane wraps to the first")
        XCTAssertEqual(first.veil.state, .focused)
        XCTAssertEqual(secondPane.veil.state, .dimmed)
        controller.perform(.previousPane)
        XCTAssertTrue(controller.window?.firstResponder === second)
        // Another tab with one pane shows no marks; the split tab keeps its own.
        try controller.newTab()
        XCTAssertEqual(controller.panes.last?.veil.state, .plain)
    }

    @MainActor func testTabNavigationWrapsAtBothEnds() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        try controller.newTab(); try controller.newTab()
        let index = { controller.tabs.selectedTabViewItem.map { controller.tabs.indexOfTabViewItem($0) } }
        XCTAssertEqual(index(), 2)
        controller.perform(.nextTab)
        XCTAssertEqual(index(), 0)
        controller.perform(.previousTab)
        XCTAssertEqual(index(), 2)
        controller.perform(.previousTab)
        XCTAssertEqual(index(), 1)
    }

    // MARK: Title bar

    @MainActor func testTabsSitInTheTitleBarAndStayClickable() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let window = try XCTUnwrap(controller.window)
        try controller.newTab()
        window.layoutIfNeeded()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.title, "AkiTTY", "the title stays set for the Window menu and assistive technology")
        let chip = try XCTUnwrap(controller.tabChips.first)
        let chipFrame = chip.convert(chip.bounds, to: nil)
        XCTAssertGreaterThan(chipFrame.minY, window.contentLayoutRect.maxY - 1, "the tab row shares the title bar")
        if let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview {
            XCTAssertGreaterThan(chipFrame.minX, superview.convert(zoom.frame, to: nil).maxX, "tabs clear the window buttons")
        }
        // The title bar must not swallow clicks meant for the tabs.
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let hit = frameView.hitTest(frameView.convert(NSPoint(x: chipFrame.midX, y: chipFrame.midY), from: nil))
        XCTAssertTrue(hit === chip || hit?.isDescendant(of: chip) == true, "hit \(String(describing: hit))")
        // Terminal content starts below the title bar.
        let tabsFrame = controller.tabs.convert(controller.tabs.bounds, to: nil)
        XCTAssertLessThanOrEqual(tabsFrame.maxY, window.contentLayoutRect.maxY + 0.5)
    }

    @MainActor func testTabsLeaveTitleBarSpaceToMoveTheWindow() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        let chip = try XCTUnwrap(controller.tabChips.first)
        XCTAssertEqual(chip.frame.width, TabChip.maximumWidth, accuracy: 1, "a lone tab takes a tab's width, not the whole bar")
        // The space past the tabs and the + button belongs to the window.
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let chipFrame = chip.convert(chip.bounds, to: nil)
        let empty = NSPoint(x: window.frame.width - 60, y: chipFrame.midY)
        let hit = try XCTUnwrap(frameView.hitTest(frameView.convert(empty, from: nil)))
        XCTAssertTrue(hit is TitlebarDragArea || hit is TitlebarStrip, "hit \(hit)")
        XCTAssertFalse(hit.mouseDownCanMoveWindow, "the strip handles the drag so a double-click can zoom")
        XCTAssertTrue(hit.acceptsFirstMouse(for: nil), "a background window moves on its first click, as with a title bar")
        // Many tabs share the bar and shrink below the cap.
        for _ in 0..<6 { try controller.newTab() }
        window.layoutIfNeeded()
        XCTAssertTrue(controller.tabChips.allSatisfy { $0.frame.width < TabChip.maximumWidth && $0.frame.width >= 64 })
        let widths = controller.tabChips.map(\.frame.width)
        XCTAssertLessThan((widths.max() ?? 0) - (widths.min() ?? 0), 1.5, "tabs stay equal")
    }

    @MainActor func testChromeTakesTheFocusedPaneBackground() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        let background = try XCTUnwrap(NSColor(cgColor: pane.terminal.renderAppearance.backgroundColor))
        XCTAssertEqual(controller.chromeBackground, background)
        XCTAssertEqual(controller.window?.backgroundColor, background)
        XCTAssertEqual(controller.window?.appearance?.name, TerminalWindow.isDark(background) ? .darkAqua : .aqua)
        XCTAssertTrue(TerminalWindow.isDark(TerminalTheme.named("akitty-dark").backgroundColor))
        XCTAssertFalse(TerminalWindow.isDark(TerminalTheme.named("akitty-light").backgroundColor))
        XCTAssertTrue(TerminalWindow.isDark(TerminalTheme.named("solarized-dark").backgroundColor))
    }

    func testDoubleClickFollowsTheSystemSetting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "akitty-double-click-\(UUID().uuidString)"))
        XCTAssertEqual(TitlebarStrip.doubleClickAction(defaults), .zoom)
        defaults.set("Minimize", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitlebarStrip.doubleClickAction(defaults), .minimize)
        defaults.set("None", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitlebarStrip.doubleClickAction(defaults), .none)
        defaults.set("Fill", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitlebarStrip.doubleClickAction(defaults), .zoom)
    }

    @MainActor func testOnlyTabReadsAsTheWindowTitle() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        XCTAssertEqual(controller.tabChips.first?.isSole, true)
        XCTAssertEqual(controller.tabChips.first?.shortcut, "")
        XCTAssertEqual(controller.tabChips.first?.label, "AkiTTY")
        try controller.newTab()
        XCTAssertEqual(controller.tabChips.map(\.isSole), [false, false])
        XCTAssertEqual(controller.tabChips.map(\.shortcut), ["⌘1", "⌘2"])
    }

    // MARK: Commands

    @MainActor func testRustCatalogAndNativeCommandsStayInStep() {
        let provider = CommandProvider()
        let ids = provider.search("").map(\.id)
        XCTAssertNil(provider.warning)
        XCTAssertEqual(Set(ids), Set(NativeCommand.allCases), "every Rust descriptor has a native action and vice versa")
        XCTAssertEqual(ids.count, NativeCommand.allCases.count)
        for descriptor in provider.search("") {
            XCTAssertEqual(descriptor.title, descriptor.id.title, "menus and the palette use one name")
            XCTAssertNotNil(NSImage(systemSymbolName: descriptor.id.symbolName, accessibilityDescription: nil), descriptor.id.symbolName)
        }
    }

    @MainActor func testNavigationShortcutsReachTheMenu() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let app = AkittyApplication()
        app.makeMenu()
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func key(_ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code))
        }
        let arrow = { (code: Int) in AkittyApplication.arrowKey(code) }
        // US layout: Shift turns ] and [ into } and {.
        XCTAssertTrue(menu.performKeyEquivalent(with: try key("}", "}", [.command, .shift], code: 30)), "⇧⌘] shows the next tab")
        XCTAssertTrue(menu.performKeyEquivalent(with: try key("{", "{", [.command, .shift], code: 33)), "⇧⌘[ shows the previous tab")
        // A layout where the brace needs no Shift still reaches the same command.
        XCTAssertTrue(menu.performKeyEquivalent(with: try key("}", "}", [.command], code: 30)))
        XCTAssertTrue(menu.performKeyEquivalent(with: try key(arrow(NSRightArrowFunctionKey), arrow(NSRightArrowFunctionKey), [.command, .option, .function, .numericPad], code: 124)))
        XCTAssertTrue(menu.performKeyEquivalent(with: try key(arrow(NSLeftArrowFunctionKey), arrow(NSLeftArrowFunctionKey), [.command, .option, .function, .numericPad], code: 123)))
        // Plain ⌥→ (word motion) stays with the terminal.
        XCTAssertFalse(menu.performKeyEquivalent(with: try key(arrow(NSRightArrowFunctionKey), arrow(NSRightArrowFunctionKey), [.option, .function, .numericPad], code: 124)))
        let window = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "Window" })
        XCTAssertNotNil(window.items.first { $0.title == NativeCommand.nextPane.title })
        XCTAssertEqual(window.items.first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }?.keyEquivalentModifierMask, [.control, .command])
    }

    @MainActor func testPaletteFloatsOverItsWindowAndStepsAsideForSheets() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let window = try XCTUnwrap(controller.window)
        controller.showPalette()
        let palette = try XCTUnwrap(controller.paletteController)
        let panel = try XCTUnwrap(palette.window)
        XCTAssertTrue(panel.parent === window)
        XCTAssertTrue(palette.isPresented)
        XCTAssertNil(window.attachedSheet, "the palette is not a sheet, so it never blocks the window")
        XCTAssertTrue(palette.warning.isHidden, "no implementation note while Rust ranking works")
        XCTAssertEqual(palette.entries.first?.id, .newWindow)
        palette.searchField.stringValue = "next pane"
        palette.refresh()
        XCTAssertEqual(palette.entries.first?.id, .nextPane)
        palette.searchField.stringValue = "zzzz-no-match"
        palette.refresh()
        XCTAssertFalse(palette.emptyState.isHidden)
        // An approval or confirmation sheet arriving on the window dismisses the palette first.
        let alert = NSAlert(); alert.messageText = "Sheet"; alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
        XCTAssertFalse(palette.isPresented)
        XCTAssertNil(panel.parent)
        window.endSheet(alert.window)
        // With no palette showing, the command opens one; while one shows, it closes it.
        controller.showPalette()
        let second = try XCTUnwrap(controller.paletteController)
        XCTAssertTrue(second.isPresented)
        controller.showPalette()
        XCTAssertFalse(second.isPresented)
    }

    @MainActor func testDismissedPaletteCannotRunAnotherCommand() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let window = try XCTUnwrap(controller.window)
        var commands: [NativeCommand] = []
        let palette = PaletteController { commands.append($0) }
        palette.present(over: window)
        XCTAssertTrue(palette.isPresented)
        palette.runSelected()
        XCTAssertFalse(palette.isPresented)
        XCTAssertEqual(commands, [.newWindow])
        palette.runSelected()
        XCTAssertEqual(commands, [.newWindow], "a queued action from the dismissed panel cannot dispatch again")
    }

    // MARK: Attention and appearance

    @MainActor func testAccessibilityDisplayChangeReloadsReduceMotionForOpenTabs() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let workspace = NSWorkspace.shared
        let current = workspace.accessibilityDisplayShouldReduceMotion
        controller.reduceMotion = !current
        workspace.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(controller.reduceMotion, current, "open windows refresh the setting used for every tab's sprite")
    }

    @MainActor func testDockBadgeCountsPendingApprovals() {
        _ = NSApplication.shared
        let tile = NSApp.dockTile
        let previous = tile.badgeLabel
        defer { tile.badgeLabel = previous }
        AkittyApplication.showPendingApprovals(2, on: tile)
        XCTAssertEqual(tile.badgeLabel, "2")
        AkittyApplication.showPendingApprovals(0, on: tile)
        XCTAssertNil(tile.badgeLabel)
        XCTAssertEqual(AkittyApplication().agentRequests.pendingCount, 0)
    }

    func testMatchSystemResolvesToTheLightOrDarkTheme() throws {
        XCTAssertEqual(TerminalTheme.resolved(TerminalTheme.systemID, systemDark: true).id, TerminalTheme.defaultID)
        XCTAssertEqual(TerminalTheme.resolved(TerminalTheme.systemID, systemDark: false).id, TerminalTheme.lightID)
        XCTAssertEqual(TerminalTheme.resolved("solarized-dark", systemDark: false).id, "solarized-dark", "explicit themes ignore the system")
        XCTAssertEqual(TerminalTheme.named("removed-theme").id, TerminalTheme.defaultID)
        var preferences = TerminalPreferences()
        preferences.theme = TerminalTheme.systemID
        XCTAssertNoThrow(try preferences.validated())
    }
}

import XCTest
import AppKit
@testable import AkittyKit

final class TabTransferTests: XCTestCase {
    /// Hit-test against this process's windows only, as if no other app covered them.
    @MainActor override func setUp() {
        super.setUp()
        TerminalWindow.windowNumberAtPoint = { point in
            NSApp.orderedWindows.first { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point) }?.windowNumber ?? 0
        }
    }
    @MainActor override func tearDown() {
        TerminalWindow.windowNumberAtPoint = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
        super.tearDown()
    }
    @MainActor private func cleanUp(_ app: AkittyApplication) {
        for controller in app.windows {
            controller.panes.forEach { $0.terminal.shutdown() }; controller.window?.close()
        }
    }
    @MainActor private func mouse(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @MainActor private func chipPoint(_ chip: TabChip) throws -> NSPoint {
        let window = try XCTUnwrap(chip.window)
        window.contentView?.layoutSubtreeIfNeeded()
        return window.convertPoint(toScreen: chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil))
    }
    @MainActor private func waitUntil(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<250 {
            if try predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("tab transfer did not settle")
    }

    @MainActor func testTransferPreservesSplitObjectsSessionsControlAndContent() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        let item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        _ = try source.splitPane(containing: source.selectedPane)
        let panes = source.panes, sessions = panes.map { $0.terminal.session.id }
        let identities = panes.map { app.intentID(for: $0.terminal) }
        for (index, pane) in panes.enumerated() { _ = try pane.terminal.session.call("feed", ["text": "kept-\(index) 中文"] ) }
        let lease = try panes[1].terminal.session.acquireControl(actor: "transfer-test")
        try source.newTab()
        source.tabs.selectTabViewItem(item); source.window?.makeFirstResponder(panes[1].terminal)
        let split = try XCTUnwrap(item.view as? NSSplitView)
        source.window?.layoutIfNeeded(); split.adjustSubviews(); split.setPosition(split.bounds.width * 0.7, ofDividerAt: 0)
        let originalShare = source.captureLayout().tabs[0].fractions[0]
        XCTAssertTrue(source.transferTab(item, to: target, at: 1))
        XCTAssertTrue(target.tabs.selectedTabViewItem === item)
        XCTAssertEqual(target.panes.suffix(2).map { $0.terminal.session.id }, sessions)
        XCTAssertTrue(target.panes[1] === panes[0]); XCTAssertTrue(target.panes[2] === panes[1])
        XCTAssertEqual(panes.map { app.intentID(for: $0.terminal) }, identities)
        XCTAssertTrue(target.window?.firstResponder === panes[1].terminal)
        XCTAssertFalse(source.window?.firstResponder === panes[1].terminal)
        XCTAssertEqual(target.captureLayout().tabs[1].fractions[0], originalShare, accuracy: 0.02)
        XCTAssertEqual(try panes[1].terminal.session.snapshot()?.control?.agent, true)
        try panes[1].terminal.session.releaseControl(lease)
        for (index, pane) in panes.enumerated() { XCTAssertTrue(try pane.terminal.session.recentText().contains("kept-\(index) 中文")) }
        XCTAssertEqual(source.panes.count, 1)
    }

    @MainActor func testMovedCallbacksAndUnreadBellBelongToDestination() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        let item = try XCTUnwrap(source.tabs.selectedTabViewItem), terminal = try XCTUnwrap(source.selectedPane)
        try source.newTab(); target.window?.orderOut(nil)
        terminal.onTitle?("build"); terminal.onBell?()
        XCTAssertEqual(source.tabChips[0].activity, .bell)
        XCTAssertTrue(source.transferTab(item, to: target, at: 1))
        XCTAssertEqual(target.tabChips[1].activity, .bell)
        XCTAssertEqual(source.tabChips[0].activity, .none)
        terminal.onTitle?("moved build")
        XCTAssertEqual(target.tabs.tabViewItems[1].label, "moved build")
        XCTAssertNotEqual(source.tabs.tabViewItems[0].label, "moved build")
        target.selectTab(at: 0); terminal.onBell?()
        XCTAssertEqual(target.tabChips[1].activity, .bell)
        terminal.onExit?()
        XCTAssertNotNil(target.window?.attachedSheet, "exit and close actions must use the new owner")
        XCTAssertNil(source.window?.attachedSheet)
        if let sheet = target.window?.attachedSheet { target.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    }

    @MainActor func testMovingATabWithFindOpenKeepsTheSearchedSplitFocused() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        _ = try source.splitPane(containing: source.selectedPane)
        let searched = source.panes[1].terminal, item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        source.window?.makeFirstResponder(searched)
        source.showFind(searched)
        XCTAssertTrue(source.findBarVisible)
        XCTAssertFalse(source.window?.firstResponder === searched)
        XCTAssertTrue(source.transferTab(item, to: target, at: 1))
        XCTAssertTrue(target.window?.firstResponder === searched, "moving a tab must preserve the Find bar's pane target")
        XCTAssertFalse(source.findBarVisible)
        XCTAssertFalse(searched.isShutdown)
    }

    @MainActor func testMovingABackgroundTabThatOwnsFindFocusesTheSearchedSplit() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        _ = try source.splitPane(containing: source.selectedPane)
        let searched = source.panes[1].terminal, item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        source.showFind(searched)
        try source.newTab()
        let remaining = try XCTUnwrap(source.tabs.selectedTabViewItem)
        XCTAssertFalse(remaining === item)
        XCTAssertTrue(source.findBarVisible)
        XCTAssertTrue(source.transferTab(item, to: target, at: 1))
        XCTAssertTrue(target.window?.firstResponder === searched, "a background tab must keep its Find target focused")
        XCTAssertTrue(source.findBarVisible, "Find stays open for the tab still on screen")
        XCTAssertTrue(source.tabs.selectedTabViewItem === remaining)
    }

    @MainActor func testMovingAnotherTabKeepsTheFindFieldFocused() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        let item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        try source.newTab()
        source.showFind()
        XCTAssertTrue(source.window?.firstResponder is NSTextView)
        XCTAssertTrue(source.transferTab(item, to: target, at: 1))
        XCTAssertTrue(source.findBarVisible)
        XCTAssertTrue(source.window?.firstResponder is NSTextView, "moving a background tab must not steal the Find field's focus")
    }

    @MainActor func testMovingABackgroundTabKeepsTheRemainingSplitFocused() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        let item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        try source.newTab()
        let focused = try source.splitPane(containing: source.selectedPane)
        source.window?.makeFirstResponder(focused)
        XCTAssertTrue(source.transferTab(item, to: target, at: 1))
        XCTAssertTrue(source.window?.firstResponder === focused, "moving a background tab must not redirect typing to the first split")
        XCTAssertFalse(focused.isShutdown)
    }

    @MainActor func testReorderingTheSelectedTabKeepsItsFocusedSplit() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true)
        try source.newTab()
        let item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        let focused = try source.splitPane(containing: source.selectedPane)
        source.window?.makeFirstResponder(focused)
        source.moveTab(item, to: 0)
        XCTAssertTrue(source.tabs.selectedTabViewItem === item)
        XCTAssertTrue(source.window?.firstResponder === focused, "reordering a tab must not redirect typing to the first split")
    }

    @MainActor func testLastTabMovesWithoutShuttingDownOrChangingSessionIdentity() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        let item = try XCTUnwrap(source.tabs.selectedTabViewItem), terminal = try XCTUnwrap(source.selectedPane)
        let id = terminal.session.id
        XCTAssertTrue(source.transferTab(item, to: target, at: 0))
        XCTAssertFalse(app.windows.contains { $0 === source })
        XCTAssertNil(source.window?.attachedSheet)
        XCTAssertFalse(terminal.isShutdown)
        XCTAssertEqual(terminal.session.id, id)
        _ = try terminal.session.call("feed", ["text": "survived"])
        XCTAssertTrue(try terminal.session.recentText().contains("survived"))
        XCTAssertFalse(source.transferTab(item, to: target, at: 0), "stale source actions cannot move it twice")
    }

    @MainActor func testContextMenuDetachesEntireTabWithoutOpeningANewSession() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true)
        _ = try source.splitPane(containing: source.selectedPane)
        let original = source.panes.map { $0.terminal.session.id }
        let focused = source.panes[1].terminal
        source.window?.makeFirstResponder(focused)
        let menu = source.tabMenu(for: try XCTUnwrap(source.tabs.selectedTabViewItem))
        let action = try XCTUnwrap(menu.items.first { $0.title == "Move Tab to New Window" })
        XCTAssertTrue(action.isEnabled)
        menu.performActionForItem(at: menu.index(of: action))
        XCTAssertEqual(app.windows.count, 1)
        let destination = try XCTUnwrap(app.windows.first)
        XCTAssertFalse(destination === source)
        XCTAssertEqual(destination.panes.map { $0.terminal.session.id }, original)
        XCTAssertTrue(destination.panes.allSatisfy { !$0.terminal.isShutdown })
        XCTAssertTrue(destination.window?.firstResponder === focused)
        XCTAssertEqual(destination.window?.tabbingMode, .disallowed)
    }

    @MainActor func testQuickTerminalsForeignAppsAndInvalidIndicesRejectTransfer() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(), foreign = AkittyApplication(); defer { cleanUp(app); cleanUp(foreign) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        let other = try foreign.createTerminalWindow(headless: true)
        let item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        XCTAssertFalse(source.transferTab(item, to: target, at: -1))
        XCTAssertFalse(source.transferTab(item, to: target, at: 2))
        XCTAssertFalse(source.transferTab(item, to: other, at: 0))
        source.quickDismiss = {}
        XCTAssertFalse(source.transferTab(item, to: target, at: 0))
        XCTAssertFalse(source.tabMenu(for: item).items.first { $0.title == "Move Tab to New Window" }!.isEnabled)
        XCTAssertNil(try app.moveTabToNewWindow(item, from: source))
        source.quickDismiss = nil; target.quickDismiss = {}
        XCTAssertFalse(source.transferTab(item, to: target, at: 0))
        XCTAssertTrue(source.tabs.selectedTabViewItem === item)
    }

    @MainActor func testApprovalOrCloseSheetBlocksBothTransferDirections() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        let item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        for owner in [source, target] {
            let alert = NSAlert(); alert.messageText = "Pending approval"
            owner.window?.beginSheet(alert.window, completionHandler: nil)
            try await waitUntil { owner.window?.attachedSheet != nil }
            XCTAssertFalse(source.transferTab(item, to: target, at: 0))
            if owner === source { XCTAssertNil(try app.moveTabToNewWindow(item, from: source)) }
            XCTAssertTrue(source.tabs.selectedTabViewItem === item)
            owner.window?.endSheet(alert.window); alert.window.orderOut(nil)
            try await waitUntil { owner.window?.attachedSheet == nil }
        }
    }

    @MainActor func testVerticalDragIntoSourceContentDetachesOnRelease() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true)
        try source.newTab()
        let chip = source.tabChips[0], window = try XCTUnwrap(source.window)
        let item = source.tabs.tabViewItems[0]
        let start = try chipPoint(chip), end = NSPoint(x: start.x, y: start.y - 120)
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        XCTAssertEqual(app.windows.count, 1, "passing outside the strip must not detach before the drop")
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertEqual(source.tabs.numberOfTabViewItems, 1)
        XCTAssertTrue(app.windows.last?.tabs.selectedTabViewItem === item)
    }

    @MainActor func testDragIntoAnotherWindowKeepsTheSameTabAndCancelRestoresOrder() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        try source.newTab(); try source.newTab()
        let window = try XCTUnwrap(source.window), targetWindow = try XCTUnwrap(target.window)
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        window.setFrame(NSRect(x: origin.x + 20, y: origin.y + 20, width: 450, height: 300), display: true)
        targetWindow.setFrame(NSRect(x: origin.x + 500, y: origin.y + 20, width: 450, height: 300), display: true)
        source.selectTab(at: 2)
        let original = source.tabs.tabViewItems, chip = source.tabChips[0]
        let start = try chipPoint(chip), reordered = try chipPoint(source.tabChips[2])
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: reordered))
        XCTAssertTrue(source.tabs.tabViewItems.last === original[0])
        chip.cancelDrag()
        XCTAssertEqual(source.tabs.tabViewItems, original)
        XCTAssertTrue(source.tabs.selectedTabViewItem === original[2])
        let end = try chipPoint(target.tabChips[0])
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertEqual(source.tabs.numberOfTabViewItems, 2)
        XCTAssertTrue(target.tabs.selectedTabViewItem === original[0])
    }

    @MainActor func testRealShellKeepsEnvironmentAndAcceptsInputAfterLastTabMoves() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(), target = try app.createTerminalWindow(headless: true)
        let terminal = try XCTUnwrap(source.selectedPane), item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        let id = terminal.session.id
        try terminal.session.input("export AKITTY_TAB_TRANSFER_VALUE=retained\n")
        try await waitUntil { try terminal.session.recentText().contains("AKITTY_TAB_TRANSFER_VALUE=retained") }
        XCTAssertTrue(source.transferTab(item, to: target, at: 1))
        try terminal.session.input("printf 'TAB_%s_OK' \"$AKITTY_TAB_TRANSFER_VALUE\"\n")
        try await waitUntil { try terminal.session.recentText().contains("TAB_retained_OK") }
        XCTAssertEqual(terminal.session.id, id)
        XCTAssertFalse(terminal.isShutdown)
        XCTAssertFalse(app.windows.contains { $0 === source })
    }

    @MainActor func testDeactivationCancelsVerticalDragWithoutCreatingAWindow() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true)
        let chip = source.tabChips[0], item = source.tabs.tabViewItems[0], window = try XCTUnwrap(source.window)
        let start = try chipPoint(chip), end = NSPoint(x: start.x, y: start.y - 120)
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(source.tabs.selectedTabViewItem === item)
    }

    @MainActor func testStaleDraggedItemCannotCreateAnEmptyWindow() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true)
        try source.newTab()
        let item = source.tabs.tabViewItems[0], chip = source.tabChips[0], window = try XCTUnwrap(source.window)
        let terminal = try XCTUnwrap((item.view as? NSSplitView)?.arrangedSubviews.first as? TerminalPane).terminal
        defer { terminal.shutdown() }
        let start = try chipPoint(chip), end = NSPoint(x: start.x, y: start.y - 120)
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        source.tabs.removeTabViewItem(item)
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(source.tabs.numberOfTabViewItems, 1)
        XCTAssertNil(try app.moveTabToNewWindow(item, from: source))
    }

    @MainActor func testRemovingTheDraggingChipCancelsItsPreviewAndDrop() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true)
        let chip = source.tabChips[0], window = try XCTUnwrap(source.window)
        let start = try chipPoint(chip), end = NSPoint(x: start.x, y: start.y - 120)
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        XCTAssertTrue(NSApp.windows.contains { $0 is TabDragPreview && $0.isVisible })
        chip.removeFromSuperview()
        XCTAssertFalse(NSApp.windows.contains { $0 is TabDragPreview && $0.isVisible })
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor func testMovedTabKeepsTheWindowsOpenedFolderAndProfile() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let folder = FileManager.default.temporaryDirectory.path, profile = UUID()
        let source = try app.createTerminalWindow(directory: folder, headless: true, profile: profile)
        try source.newTab()
        let moved = try XCTUnwrap(app.moveTabToNewWindow(source.tabs.tabViewItems[0], from: source))
        XCTAssertEqual(moved.directory, folder)
        XCTAssertEqual(moved.profile, profile)
    }

    @MainActor func testDroppingTheOnlyTabOnItsOwnContentKeepsTheWindow() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true)
        let chip = source.tabChips[0], window = try XCTUnwrap(source.window)
        let frame = window.frame, item = try XCTUnwrap(source.tabs.selectedTabViewItem)
        let start = try chipPoint(chip), end = NSPoint(x: start.x, y: start.y - 120)
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(app.windows.first === source)
        XCTAssertTrue(source.tabs.selectedTabViewItem === item)
        XCTAssertEqual(window.frame, frame)
    }

    @MainActor func testStripHeightBesideTheWindowDetachesInsteadOfReordering() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true)
        try source.newTab()
        let window = try XCTUnwrap(source.window), screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        window.setFrame(NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 450, height: 300), display: true)
        let original = source.tabs.tabViewItems, chip = source.tabChips[0]
        let start = try chipPoint(chip), end = NSPoint(x: window.frame.maxX + 200, y: start.y)
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        XCTAssertEqual(source.tabs.tabViewItems, original, "strip height outside the window must not reorder")
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertTrue(app.windows.last?.tabs.selectedTabViewItem === original[0])
    }

    @MainActor func testDropOnAWindowCoveredByAnotherAppDetachesInsteadOfJoiningIt() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        try source.newTab()
        let window = try XCTUnwrap(source.window), targetWindow = try XCTUnwrap(target.window)
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        window.setFrame(NSRect(x: origin.x + 20, y: origin.y + 20, width: 450, height: 300), display: true)
        targetWindow.setFrame(NSRect(x: origin.x + 500, y: origin.y + 20, width: 450, height: 300), display: true)
        let item = source.tabs.tabViewItems[0], chip = source.tabChips[0]
        let start = try chipPoint(chip), end = try chipPoint(target.tabChips[0])
        TerminalWindow.windowNumberAtPoint = { _ in -1 }  // another app's window is on top
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(target.tabs.numberOfTabViewItems, 1, "a covered window must not take the drop")
        XCTAssertEqual(app.windows.count, 3)
        XCTAssertTrue(app.windows.last?.tabs.selectedTabViewItem === item)
    }

    @MainActor func testRejectedDropRestoresOriginalOrderAndSelection() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); defer { cleanUp(app) }
        let source = try app.createTerminalWindow(headless: true), target = try app.createTerminalWindow(headless: true)
        try source.newTab(); try source.newTab()
        let window = try XCTUnwrap(source.window), targetWindow = try XCTUnwrap(target.window)
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        window.setFrame(NSRect(x: origin.x + 20, y: origin.y + 20, width: 450, height: 300), display: true)
        targetWindow.setFrame(NSRect(x: origin.x + 500, y: origin.y + 20, width: 450, height: 300), display: true)
        source.selectTab(at: 2)
        let original = source.tabs.tabViewItems, chip = source.tabChips[0]
        let start = try chipPoint(chip), reordered = try chipPoint(source.tabChips[2])
        let end = NSPoint(x: targetWindow.frame.midX, y: targetWindow.frame.midY)
        chip.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: reordered))
        XCTAssertTrue(source.tabs.tabViewItems.last === original[0])
        chip.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: end))
        chip.mouseUp(with: try mouse(.leftMouseUp, in: window, at: end))
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertEqual(source.tabs.tabViewItems, original)
        XCTAssertTrue(source.tabs.selectedTabViewItem === original[2])
    }
}

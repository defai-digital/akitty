import AppKit
import AppIntents
import XCTest
@testable import AkittyKit

final class SiriIntentTests: XCTestCase {
    @MainActor private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true")
    }

    @MainActor func testEntityQueriesFocusBackgroundTabsAndRejectOldInstances() async throws {
        _ = NSApplication.shared
        let previous = NSApp.delegate
        let app = AkittyApplication(); NSApp.delegate = app
        let window = try app.createTerminalWindow(headless: true)
        defer {
            window.panes.forEach { $0.terminal.shutdown() }; window.window?.close()
            NSApp.delegate = previous
        }
        let first = try XCTUnwrap(window.active)
        _ = try first.session.call("feed", ["text": "\u{1b}]2;Siri Project\u{7}PRIVATE_SCROLLBACK"])
        first.poll()
        try await waitUntil { first.snapshot?.title == "Siri Project" }
        try window.newTab()
        let all = try await TerminalEntityQuery().allEntities()
        XCTAssertEqual(all.count, 2)
        let named = try await TerminalEntityQuery().entities(matching: "siri project")
        let entity = try XCTUnwrap(named.first)
        XCTAssertEqual(named.count, 1)
        XCTAssertFalse(entity.summary.contains("PRIVATE_SCROLLBACK"))
        XCTAssertEqual(first.appEntityIdentifier, EntityIdentifier(for: entity))
        let focus = FocusTerminalIntent(); focus.terminal = entity
        _ = try await focus.perform()
        XCTAssertTrue(window.active === first)
        XCTAssertTrue(window.tabs.selectedTabViewItem?.view?.subviews.contains(where: { ($0 as? TerminalPane)?.terminal === first }) == true)
        let listing = try await ListTerminalsIntent().perform()
        XCTAssertEqual(listing.value?.count, 2)
        let stale = AkittyApplication().intentID(for: first)
        XCTAssertThrowsError(try app.resolveIntentTerminal(stale))
        let unresolved = try await TerminalEntityQuery().entities(for: [stale, entity.id])
        XCTAssertEqual(unresolved.map(\.id), [entity.id])
        first.shutdown()
        let closed = try await TerminalEntityQuery().entities(for: [entity.id])
        XCTAssertTrue(closed.isEmpty)
        XCTAssertThrowsError(try app.resolveIntentTerminal(entity.id))
    }

    @MainActor func testStatusRefreshesCoreDataAndDoesNotTrustAnOldEntity() async throws {
        _ = NSApplication.shared
        let previous = NSApp.delegate
        let app = AkittyApplication(); NSApp.delegate = app
        let window = try app.createTerminalWindow(headless: true)
        let terminal = try XCTUnwrap(window.active)
        defer {
            terminal.shutdown(); window.window?.close(); NSApp.delegate = previous
        }
        let action = GetTerminalStatusIntent()
        action.terminal = TerminalEntity(id: app.intentID(for: terminal), name: "Old Name", reportedStatus: "Verified success")
        _ = try terminal.session.call("feed", ["text": "\u{1b}]2;Speech Pane\u{7}\u{1b}]7;file:///private/siri-test\u{7}\u{1b}]133;A\u{7}\u{1b}]7501;state=blocked:kind=permission:app=private-agent\u{7}PRIVATE_OUTPUT"])
        _ = try terminal.session.acquireControl(actor: "private-agent")
        let result = try await action.perform()
        let entity = try XCTUnwrap(result.value)
        XCTAssertEqual(entity.name, "Speech Pane")
        XCTAssertEqual(entity.reportedStatus, "Program reports blocked; result not verified")
        XCTAssertEqual(entity.inputOwnership, "Agent-controlled input")
        XCTAssertEqual(entity.shellReadiness, "Shell reports an idle prompt")
        for privateText in ["PRIVATE_OUTPUT", "private-agent", "/private/siri-test", "Verified success"] {
            XCTAssertFalse(entity.summary.contains(privateText))
        }
        _ = try terminal.session.call("feed", ["text": "\u{1b}]2;Fresh Pane\u{7}\u{1b}]133;C\u{7}"])
        try terminal.session.reclaimControl()
        let refreshed = try await action.perform()
        XCTAssertEqual(refreshed.value?.name, "Fresh Pane")
        XCTAssertEqual(refreshed.value?.inputOwnership, "Human-controlled input")
        XCTAssertEqual(refreshed.value?.shellReadiness, "Shell does not report an idle prompt")
        terminal.shutdown()
        do { _ = try await action.perform(); XCTFail("Closed pane must not resolve") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer open")) }
    }

    func testSpokenListHandlesEmptySingleAndManyPanesWithoutReadingAllMetadata() {
        XCTAssertEqual(TerminalSpeech.list([]), "No AkiTTY terminal panes are open.")
        let entities = (0..<7).map {
            TerminalEntity(id: String($0), name: "Pane \($0)", reportedStatus: String(repeating: "private", count: 1000))
        }
        XCTAssertEqual(TerminalSpeech.list([entities[0]]), "One AkiTTY terminal pane is open: Pane 0.")
        let spoken = TerminalSpeech.list(entities)
        XCTAssertTrue(spoken.contains("7 open")); XCTAssertTrue(spoken.contains("4 more"))
        XCTAssertFalse(spoken.contains("Pane 3")); XCTAssertFalse(spoken.contains("private"))
        XCTAssertLessThan(spoken.count, 200)
    }

    @MainActor func testQuickTerminalShowIsIdempotentAndReusesHiddenWindow() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        var made: [TerminalWindow] = []
        let quick = QuickTerminalController {
            let window = try app.createTerminalWindow(headless: true); made.append(window); return window
        }
        quick.restoreFocus = {}
        defer { quick.stop(); made.forEach { $0.panes.forEach { $0.terminal.shutdown() }; $0.window?.close() } }
        try quick.show(); let first = try XCTUnwrap(quick.terminalWindow)
        try quick.show()
        XCTAssertEqual(made.count, 1); XCTAssertTrue(first.window?.isVisible == true)
        quick.hide(); XCTAssertFalse(first.window?.isVisible == true)
        try quick.show()
        XCTAssertEqual(made.count, 1); XCTAssertTrue(first.window?.isVisible == true)
        try quick.toggle(); XCTAssertFalse(first.window?.isVisible == true)
    }

    @MainActor func testIntentLaunchDoesNotCreateAnExtraDefaultShell() throws {
        _ = NSApplication.shared
        for defaultLaunch in [false, true] {
            let app = AkittyApplication()
            defer { app.windows.forEach { $0.panes.forEach { $0.terminal.shutdown() }; $0.window?.close() } }
            try app.createInitialWindowIfNeeded(defaultLaunch: defaultLaunch, headless: true)
            XCTAssertEqual(app.windows.count, defaultLaunch ? 1 : 0)
            // An action arriving before didFinishLaunching owns the initial
            // terminal; startup must not add another shell afterward.
            if !defaultLaunch { try app.createTerminalWindow(headless: true) }
            try app.createInitialWindowIfNeeded(defaultLaunch: true, headless: true)
            XCTAssertEqual(app.windows.count, 1)
        }
    }

    @MainActor func testIntentWithoutAppAndCancelledActionsFailWithoutSideEffects() async throws {
        _ = NSApplication.shared
        let previous = NSApp.delegate; NSApp.delegate = nil
        defer { NSApp.delegate = previous }
        do { _ = try await ShowAgentOverviewIntent().perform(); XCTFail("Missing app must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("installed AkiTTY")) }
        let app = AkittyApplication(); NSApp.delegate = app
        let action = Task { @MainActor in _ = try await NewTerminalIntent().perform() }
        action.cancel()
        do { try await action.value; XCTFail("Cancelled action must fail") } catch is CancellationError {}
        XCTAssertTrue(app.windows.isEmpty)
        XCTAssertEqual(NewTerminalIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(RequestCommandIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
    }

    @MainActor func testSiriRequestDenialCancellationAndSerializationWithoutLocalSocket() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-siri-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        let socket = root.appendingPathComponent("requests.sock")
        let requests = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: socket.path)
        requests.cooldownInterval = 0
        defer { requests.stop(); terminal.shutdown(); window.close() }
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        for invalid in ["", "echo one\necho two", "echo \u{202e}hidden", String(repeating: "x", count: 4097)] {
            do { _ = try await requests.request(invalid, in: terminal, origin: .siri); XCTFail("Invalid command must fail") }
            catch {}
            XCTAssertNil(window.attachedSheet)
        }
        for outcome in ["deny", "cancel", "stop"] {
            let pending = Task { try await requests.request("echo private-command", in: terminal, origin: .siri) }
            try await waitUntil { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertEqual(sheet.defaultButtonCell?.title, "Deny")
            do { _ = try await requests.request("echo second", in: terminal, origin: .siri); XCTFail("Concurrent request must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("awaiting approval")) }
            if outcome == "cancel" { pending.cancel() }
            else if outcome == "stop" { requests.stop() }
            else { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            do { _ = try await pending.value; XCTFail("Denied or cancelled request must fail") } catch {}
            XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
        }
        let events = String(decoding: try requests.store.export(), as: UTF8.self)
        XCTAssertTrue(events.contains("siri_shortcuts")); XCTAssertTrue(events.contains("denied"))
        XCTAssertFalse(events.contains("private-command")); XCTAssertFalse(events.contains("\"event\":\"dispatched\""))
        XCTAssertFalse(requests.enabled); XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        do { _ = try await requests.request("echo after-stop", in: terminal, origin: .siri); XCTFail("Stopped service must reject requests") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
    }

    @MainActor func testSiriApprovalDispatchesOnceToRealPTYAndRetainsLease() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-siri-pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try "#!/bin/sh\nexec /bin/zsh -d -f -i\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        var preferences = TerminalPreferences(); preferences.shell = shell.path; preferences.directory = root.path; preferences.shellIntegration = false
        let terminal = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        let requests = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        defer { requests.stop(); terminal.shutdown(); window.close() }
        let integration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AkittyKit/Resources/shell-integration/akitty.zsh")
        try terminal.session.input("AKITTY_FOLDER_HISTORY=0; source '\(integration.path)'\r")
        try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
        let marker = root.appendingPathComponent("executed")
        let pending = Task { try await requests.request("printf once >> '\(marker.path)'", in: terminal, origin: .siri) }
        try await waitUntil { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let receipt = try await pending.value
        XCTAssertEqual(receipt["accepted"] as? Bool, true)
        XCTAssertEqual(receipt["completion_untrusted"] as? Bool, true)
        XCTAssertEqual(receipt["input_remains_leased"] as? Bool, true)
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "once")
        XCTAssertThrowsError(try terminal.session.input("human"))
        try terminal.session.reclaimControl()
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
        XCTAssertFalse(requests.enabled)
    }
}

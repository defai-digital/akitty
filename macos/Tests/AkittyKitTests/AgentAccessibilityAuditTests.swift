import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import AgentIPC
@testable import AkittyKit

/// Walks the accessibility tree VoiceOver reads for the approval sheets: a request from another pane and an agent's
/// permission prompt. Every control must have a spoken name, and the facts a person decides on must be readable.
/// This is an automated audit, not a VoiceOver user session. Settings → Agents is SwiftUI, whose tree is only built
/// for a connected assistive client, so it is read through the system accessibility API, as VoiceOver reads it;
/// that test needs the Accessibility permission for the app running the tests and is skipped without it.
final class AgentAccessibilityAuditTests: XCTestCase {
    struct Element { let role: String; let label: String; let value: String; let help: String }

    @MainActor static func elements(of root: Any) -> [Element] {
        var result: [Element] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ node: Any, depth: Int) {
            guard depth < 40, let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted,
                  let element = node as? NSAccessibilityProtocol else { return }
            if element.isAccessibilityElement() {
                let value = element.accessibilityValue().map { "\($0)" } ?? ""
                let label = element.accessibilityLabel() ?? (element.accessibilityTitle() ?? "")
                result.append(Element(role: element.accessibilityRole()?.rawValue ?? "", label: label,
                                      value: value, help: element.accessibilityHelp() ?? ""))
            }
            for child in element.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return result
    }
    static func spoken(_ elements: [Element]) -> String {
        elements.map { "\($0.role) \($0.label) \($0.value)" }.joined(separator: "\n")
    }
    static func assertEveryControlIsNamed(_ elements: [Element], file: StaticString = #filePath, line: UInt = #line) {
        let controls: Set<String> = [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.checkBox.rawValue,
                                     NSAccessibility.Role.popUpButton.rawValue, NSAccessibility.Role.link.rawValue]
        let unnamed = elements.filter { controls.contains($0.role) && $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue(unnamed.isEmpty, "controls without a spoken name: \(unnamed)", file: file, line: line)
    }

    @MainActor func testCrossPaneApprovalSheetReadsSourceTargetAndCommandAndDefaultsToDeny() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/akitty-a11y-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try TerminalView(headless: true, forceSoftware: true)
        _ = try pane.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane; window.orderFront(nil)
        let service = AgentRequests(source: { [pane] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); pane.shutdown(); window.close() }
        let task = Task { @MainActor () -> Error? in
            do { _ = try await service.request("echo spoken", in: pane, origin: .siri, requestID: "a11y", source: .pane(99)); return nil } catch { return error }
        }
        for _ in 0..<300 where window.attachedSheet == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let elements = Self.elements(of: sheet)
        let spoken = Self.spoken(elements)
        Self.assertEveryControlIsNamed(elements)
        XCTAssertTrue(spoken.contains("Requested by a program started in another pane, Terminal 99"), spoken)
        XCTAssertTrue(spoken.contains("Terminal \(pane.session.id)"), spoken)
        XCTAssertTrue(spoken.contains("echo spoken"), "the exact command is readable: \(spoken)")
        XCTAssertEqual(sheet.defaultButtonCell?.title, "Deny")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        _ = await task.value
    }

    @MainActor func testAgentPermissionSheetNamesTheAgentAndExplainsEachButton() throws {
        _ = NSApplication.shared
        for agent in ["claude-code", "codex"] {
            let request = AgentRequests.PermissionRequest(agent: agent, tool: "Bash", command: "rm -rf build\nmake", cwd: "/tmp/project", reason: "clean build")
            let alert = AgentRequests.decisionAlert(request, pane: 4)
            alert.layout()
            let elements = Self.elements(of: alert.window)
            let spoken = Self.spoken(elements)
            let name = AgentRequests.agentNames[agent]!
            Self.assertEveryControlIsNamed(elements)
            XCTAssertTrue(spoken.contains("Allow \(name) to run this Bash command?"), spoken)
            XCTAssertTrue(spoken.contains("rm -rf build\nmake"), "the whole multi-line command is readable: \(spoken)")
            XCTAssertTrue(spoken.contains("Complete exact command"), spoken)
            XCTAssertTrue(spoken.contains("Terminal 4"), spoken)
            for title in ["Allow Once", "Deny"] {
                let button = elements.first { $0.role == NSAccessibility.Role.button.rawValue && $0.label == title }
                XCTAssertFalse(button?.help.isEmpty ?? true, "\(title) explains what it answers")
            }
            XCTAssertEqual(alert.window.defaultButtonCell?.title, "Deny")
        }
    }

    /// Reads an AX element tree in this process from a background thread, so the main thread can answer.
    nonisolated static func axElements(window title: String) -> [Element]? {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 5)
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []) + (attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        guard let window = windows.first(where: { attribute($0, kAXTitleAttribute) as? String == title }) else { return nil }
        var result: [Element] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 40, result.count < 2000 else { return }
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            // The system scroll bar's arrow and page parts are AppKit's, and VoiceOver names them by their subrole.
            if role == kAXScrollBarRole as String { return }
            let label = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { attribute(element, $0) as? String }.first { !$0.isEmpty } ?? ""
            let value = attribute(element, kAXValueAttribute).map { "\($0)" } ?? ""
            result.append(Element(role: role, label: label, value: value, help: attribute(element, kAXHelpAttribute) as? String ?? ""))
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return result
    }

    @MainActor func testAgentsSettingsTabReadsEveryAgentAndNamesEveryControl() async throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Needs the Accessibility permission (System Settings → Privacy & Security → Accessibility) for the app running the tests")
        }
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.accessory)
        // AppKit serves the system accessibility API only once the app has finished launching.
        NSApplication.shared.finishLaunching()
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "akitty-a11y-\(UUID().uuidString)"))
        let title = "Agents audit \(UUID().uuidString.prefix(6))"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentIntegrationsView(defaults: defaults)); window.orderFront(nil)
        defer { window.close() }
        var elements: [Element] = []
        for _ in 0..<40 {
            elements = await Task.detached { Self.axElements(window: title) ?? [] }.value
            if Self.spoken(elements).contains("AX Code") && elements.contains(where: { $0.role == kAXButtonRole as String }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let spoken = Self.spoken(elements)
        print("AKITTY_A11Y_AGENTS \(elements.count) elements, \(elements.filter { $0.role == kAXButtonRole as String }.map(\.label))")
        Self.assertEveryControlIsNamed(elements)
        for text in ["Local Agent Requests", "Turn on when AkiTTY starts", "Claude Code", "Codex", "AX Code", "Grok", "Muse Code", "Kimi Code", "AGY"] {
            XCTAssertTrue(spoken.contains(text), "\(text) is readable: \(spoken)")
        }
        XCTAssertFalse(elements.filter { $0.role == kAXButtonRole as String }.isEmpty, spoken)
    }
}

import AppKit
import XCTest
@testable import AgentIPC
@testable import AkittyKit

/// Walks the accessibility tree VoiceOver reads for the approval sheets: a request from another pane and an agent's
/// permission prompt. Every control must have a spoken name, and the facts a person decides on must be readable.
/// This is an automated audit, not a VoiceOver user session. Settings → Agents is SwiftUI, whose tree is only built
/// for a connected assistive client, so it is left to a VoiceOver session.
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
}

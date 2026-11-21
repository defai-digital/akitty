import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import AkittyKit

final class DefaultTerminalTests: XCTestCase {
    func testLaunchLineQuotesThePathAndRefusesHiddenCharacters() {
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/tool"), "'/tmp/tool' || true\n")
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/my file"), "'/tmp/my file' || true\n")
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/it's"), "'/tmp/it'\\''s' || true\n")
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/Foo\u{15}ls"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/photo\u{202E}gnp.command"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/run\u{200B}.command"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/line\u{2028}break"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "relative"))
        XCTAssertFalse(DefaultTerminal.shouldSendLaunchCommand(ready: false, elapsed: 0))
        XCTAssertTrue(DefaultTerminal.shouldSendLaunchCommand(ready: true, elapsed: 0))
        XCTAssertFalse(DefaultTerminal.shouldSendLaunchCommand(ready: false, elapsed: 1.9))
        XCTAssertTrue(DefaultTerminal.shouldSendLaunchCommand(ready: false, elapsed: 2))
        XCTAssertFalse(DefaultTerminal.isHandler(nil, for: URL(fileURLWithPath: "/Applications/Akitty.app")))
        let app = URL(fileURLWithPath: "/Applications/Akitty.app")
        XCTAssertTrue(DefaultTerminal.isHandler(app, for: app))
        XCTAssertFalse(DefaultTerminal.isHandler(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), for: app))
        XCTAssertNotNil(DefaultTerminal.shellScriptType)
    }

    func testRunnableFilesAreExecutablesAndTerminalScripts() {
        XCTAssertTrue(DefaultTerminal.isRunnableFile(URL(fileURLWithPath: "/tmp/tool"), contentType: .unixExecutable))
        XCTAssertTrue(DefaultTerminal.isRunnableFile(URL(fileURLWithPath: "/tmp/run.command"), contentType: .plainText))
        XCTAssertTrue(DefaultTerminal.isRunnableFile(URL(fileURLWithPath: "/tmp/run.tool"), contentType: .plainText))
        XCTAssertFalse(DefaultTerminal.isRunnableFile(URL(fileURLWithPath: "/tmp/README.md"), contentType: .plainText))
        XCTAssertFalse(DefaultTerminal.isRunnableFile(URL(fileURLWithPath: "/tmp/script.sh"), contentType: .shellScript))
    }

    func testDocumentOpenRunsAnExecutableCommandAndKeepsAnOrdinaryFileAsItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-open-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("project")
        let file = folder.appendingPathComponent("README.md")
        let command = folder.appendingPathComponent("run.command")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try Data("echo hi\n".utf8).write(to: command)
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = documentOpen(from: [folder, file, command, root.appendingPathComponent("missing"), URL(string: "https://example.com/")!])
        XCTAssertEqual(plain.folders, FolderOpenRequest(directories: [folder.standardizedFileURL.path], skipped: 2))
        XCTAssertEqual(plain.runnable, [])
        XCTAssertEqual(plain.skippedRunnables, 0)
        XCTAssertFalse(DefaultTerminal.isRunnable(file))
        XCTAssertFalse(DefaultTerminal.isRunnable(command))
        XCTAssertFalse(DefaultTerminal.isRunnable(folder))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let opened = documentOpen(from: [folder, file, command])
        XCTAssertEqual(opened.folders.directories, [folder.standardizedFileURL.path])
        XCTAssertEqual(opened.runnable, [command.standardizedFileURL.path])
        XCTAssertTrue(DefaultTerminal.isRunnable(command))
        let before = try XCTUnwrap(DefaultTerminal.fileIdentity(command.path))
        try Data("echo changed\n".utf8).write(to: command)
        let after = try XCTUnwrap(DefaultTerminal.fileIdentity(command.path))
        XCTAssertNotEqual(before, after)
        XCTAssertNil(DefaultTerminal.fileIdentity(root.appendingPathComponent("missing").path))
    }

    func testDocumentOpenSharesOneCapAcrossFoldersAndPrograms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var folders: [URL] = []
        for index in 0..<8 {
            let url = root.appendingPathComponent("dir-\(index)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            folders.append(url)
        }
        let command = root.appendingPathComponent("run.command")
        try Data("echo hi\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let foldersFirst = documentOpen(from: folders + [command])
        XCTAssertEqual(foldersFirst.folders.directories.count, 8)
        XCTAssertEqual(foldersFirst.runnable, [])
        XCTAssertEqual(foldersFirst.skippedRunnables, 1)
        let programFirst = documentOpen(from: [command] + folders)
        XCTAssertEqual(programFirst.runnable, [command.standardizedFileURL.path])
        XCTAssertEqual(programFirst.folders.directories.count, 7)
        XCTAssertEqual(programFirst.folders.skipped, 1)
    }

    func testInfoPlistClaimsUnixExecutablesAndTerminalShellScripts() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plist)
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(root["CFBundleDocumentTypes"] as? [[String: Any]])
        let shells = types.filter { $0["CFBundleTypeRole"] as? String == "Shell" }
        let identifiers = shells.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertEqual(identifiers, ["public.unix-executable", "com.apple.terminal.shell-script"])
        let scripts = try XCTUnwrap(shells.first { ($0["LSItemContentTypes"] as? [String])?.contains("com.apple.terminal.shell-script") == true })
        XCTAssertEqual(scripts["LSHandlerRank"] as? String, "Alternate")
        let executables = try XCTUnwrap(shells.first { ($0["LSItemContentTypes"] as? [String])?.contains("public.unix-executable") == true })
        XCTAssertNil(executables["LSHandlerRank"])
    }

    @MainActor func testDockMenuAndDefaultTerminalItem() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let app = AkittyApplication()
        app.makeMenu()
        let dock = app.applicationDockMenu(NSApp)
        XCTAssertEqual(dock?.items.map(\.title), ["New Window", "New Tab"])
        XCTAssertEqual(dock?.items.map { $0.target === app }, [true, true])
        XCTAssertEqual(dock?.items.map(\.action), [#selector(AkittyApplication.newWindowFromDock(_:)), #selector(AkittyApplication.newTabFromDock(_:))])
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Akitty" })
        XCTAssertTrue(menu.autoenablesItems)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Make Akitty the Default Terminal" })
        app.defaultTerminalApplication = { URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app") }
        XCTAssertTrue(app.validateMenuItem(item))
        app.defaultTerminalApplication = { Bundle.main.bundleURL }
        XCTAssertFalse(app.validateMenuItem(item))
        let about = try XCTUnwrap(menu.items.first { $0.title == "About Akitty" })
        XCTAssertTrue(app.validateMenuItem(about))
        about.isEnabled = false
        XCTAssertFalse(app.validateMenuItem(about))
    }

    @MainActor func testDockTabUsesTheFrontVisibleTerminalAndSkipsAHiddenQuickTerminal() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let quick = try TerminalWindow(app: app, headless: true)
        let front = try TerminalWindow(app: app, headless: true)
        defer {
            quick.panes.forEach { $0.terminal.shutdown() }
            front.panes.forEach { $0.terminal.shutdown() }
            quick.window?.close()
            front.window?.close()
        }
        quick.window?.orderOut(nil)
        front.window?.orderFrontRegardless()
        if front.window?.isVisible == true, quick.window?.isVisible != true {
            let visible = AkittyApplication.dockTabWindow(orderedFrontToBack: [quick, front], quick: quick)
            XCTAssertTrue(visible === front)
        }
        quick.window?.orderOut(nil)
        front.window?.orderOut(nil)
        XCTAssertNotEqual(quick.window?.isVisible, true)
        XCTAssertNotEqual(front.window?.isVisible, true)
        let minimized = AkittyApplication.dockTabWindow(orderedFrontToBack: [quick, front], quick: quick)
        XCTAssertTrue(minimized === front)
    }
}

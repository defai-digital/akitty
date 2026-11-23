import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import AkittyKit

final class DefaultTerminalTests: XCTestCase {
    func testLaunchLineQuotesThePathAndRefusesHiddenCharacters() {
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/tool"), "'/tmp/tool' || true\r")
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/my file"), "'/tmp/my file' || true\r")
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/it's"), "'/tmp/it'\\''s' || true\r")
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/a\\'b"), "'/tmp/a\\'\\''b' || true\r")
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/Foo\u{15}ls"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/photo\u{202E}gnp.command"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/run\u{200B}.command"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/line\u{2028}break"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "relative"))
        XCTAssertNil(DefaultTerminal.launchLine(for: "/tmp/x\r", shell: .fish))
        // A combining mark after the quote makes one grapheme cluster. The quote is still escaped.
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/a'\u{0301}; echo x; #"), "'/tmp/a'\\''\u{0301}; echo x; #' || true\r")
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/a\\\u{0301}'\u{0301}", shell: .fish), "'/tmp/a\\\\\u{0301}\\'\u{0301}' || true\r")
    }

    func testPosixLaunchLinePassesAdversarialPathsAsOneWord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-quote-\(UUID().uuidString)")
        // File names cannot hold "/", so the payload touches a relative marker; each shell runs in `root`.
        let marker = root.appendingPathComponent("injected")
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["it's", "a'\u{0301}; touch injected; #", "Tools\\'; touch injected; #", "$(touch injected) `touch injected` 中文", "é'\u{0301}\u{0301}"]
        for (index, name) in names.enumerated() {
            let folder = root.appendingPathComponent("\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let program = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\necho ran-\(index)\n".utf8).write(to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            let line = try XCTUnwrap(DefaultTerminal.launchLine(for: program.path))
            for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: shell)
                process.currentDirectoryURL = root
                process.arguments = ["-c", String(line.dropLast())]
                process.standardOutput = output
                try process.run(); process.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(text, "ran-\(index)\n", "\(shell) \(name)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFishLaunchLineEscapesBackslashAndQuote() {
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/it's", shell: .fish), "'/tmp/it\\'s' || true\r")
        // A backslash before a quote cannot end fish's single-quoted string.
        XCTAssertEqual(DefaultTerminal.launchLine(for: "/tmp/Tools\\'; curl x|sh; #/tool", shell: .fish),
                       "'/tmp/Tools\\\\\\'; curl x|sh; #/tool' || true\r")
        XCTAssertEqual(DefaultTerminal.launchShell("/bin/zsh"), .posix)
        XCTAssertEqual(DefaultTerminal.launchShell("/bin/bash"), .posix)
        XCTAssertEqual(DefaultTerminal.launchShell("/bin/sh"), .posix)
        XCTAssertEqual(DefaultTerminal.launchShell("/bin/dash"), .posix)
        XCTAssertEqual(DefaultTerminal.launchShell("/bin/ksh"), .posix)
        XCTAssertEqual(DefaultTerminal.launchShell("/opt/homebrew/bin/fish"), .fish)
        XCTAssertNil(DefaultTerminal.launchShell("/opt/homebrew/bin/nu"))
        XCTAssertNil(DefaultTerminal.launchShell("/usr/local/bin/xonsh"))
        XCTAssertEqual(DefaultTerminal.resolvedShell("", environment: ["SHELL": "/opt/homebrew/bin/fish"]), "/opt/homebrew/bin/fish")
        XCTAssertEqual(DefaultTerminal.resolvedShell("", environment: [:]), "/bin/zsh")
        XCTAssertEqual(DefaultTerminal.resolvedShell("/bin/bash", environment: ["SHELL": "/bin/zsh"]), "/bin/bash")
    }

    func testIntegratedLaunchWaitsForThePromptAndTimesOutPlainLaunchSendsAfterTwoSeconds() {
        XCTAssertEqual(DefaultTerminal.launchStep(ready: true, integrated: true, elapsed: 0), .send)
        XCTAssertEqual(DefaultTerminal.launchStep(ready: false, integrated: true, elapsed: 2), .wait)
        XCTAssertEqual(DefaultTerminal.launchStep(ready: false, integrated: true, elapsed: 29.9), .wait)
        XCTAssertEqual(DefaultTerminal.launchStep(ready: false, integrated: true, elapsed: 30), .timedOut)
        XCTAssertEqual(DefaultTerminal.launchStep(ready: false, integrated: false, elapsed: 0), .wait)
        XCTAssertEqual(DefaultTerminal.launchStep(ready: false, integrated: false, elapsed: 1.9), .wait)
        XCTAssertEqual(DefaultTerminal.launchStep(ready: false, integrated: false, elapsed: 2), .send)
    }

    func testLaunchClockPausesWhileHeld() {
        var clock = DefaultTerminal.LaunchClock(now: 100)
        XCTAssertEqual(clock.tick(now: 101, paused: false), 1)
        XCTAssertEqual(clock.tick(now: 160, paused: true), 1)
        XCTAssertEqual(clock.tick(now: 161.5, paused: false), 2.5)
        XCTAssertEqual(clock.tick(now: 150, paused: false), 2.5)
    }

    func testDuplicateKeyFollowsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appendingPathComponent("run.command")
        try Data("echo hi\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let link = root.appendingPathComponent("link.command")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: program)
        XCTAssertEqual(DefaultTerminal.duplicateKey(link.path), DefaultTerminal.duplicateKey(program.path))
        let viaTmp = "/tmp/akitty-dup-\(UUID().uuidString)"
        try Data().write(to: URL(fileURLWithPath: viaTmp))
        defer { try? FileManager.default.removeItem(atPath: viaTmp) }
        XCTAssertEqual(DefaultTerminal.duplicateKey(viaTmp), DefaultTerminal.duplicateKey("/private" + viaTmp))
        XCTAssertEqual(DefaultTerminal.duplicateKey("/missing/./a"), "/missing/a")
        let open = documentOpen(from: [program, link])
        XCTAssertEqual(open.runnable, [program.standardizedFileURL.path])
    }

    func testUserCancelIsRecognised() {
        XCTAssertTrue(DefaultTerminal.isUserCancel(CocoaError(.userCancelled)))
        XCTAssertTrue(DefaultTerminal.isUserCancel(NSError(domain: NSOSStatusErrorDomain, code: -128)))
        XCTAssertFalse(DefaultTerminal.isUserCancel(CocoaError(.fileNoSuchFile)))
        let wrapped = NSError(domain: "com.apple.LaunchServices", code: -54, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -128)])
        XCTAssertTrue(DefaultTerminal.isUserCancel(wrapped))
        XCTAssertFalse(DefaultTerminal.isUserCancel(NSError(domain: NSOSStatusErrorDomain, code: -10814)))
    }

    func testHandlerIdentity() {
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
        let repeated = documentOpen(from: [command, command, folder.appendingPathComponent("./run.command")])
        XCTAssertEqual(repeated.runnable, [command.standardizedFileURL.path])
        XCTAssertEqual(repeated.skippedRunnables, 0)
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

    func testOnlyAnAppRequestRunsAProgram() throws {
        XCTAssertTrue(DefaultTerminal.isAppSender(bundleIdentifier: "com.apple.finder", bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")))
        XCTAssertFalse(DefaultTerminal.isAppSender(bundleIdentifier: nil, bundleURL: nil), "the open tool")
        XCTAssertFalse(DefaultTerminal.isAppSender(bundleIdentifier: "com.example.tool", bundleURL: URL(fileURLWithPath: "/usr/local/bin")))
        // The sender PID is set by the system when an event is sent, so the process check is tested directly.
        XCTAssertFalse(DefaultTerminal.isOpenedByApp(nil))
        XCTAssertFalse(DefaultTerminal.isApp(0))
        XCTAssertFalse(DefaultTerminal.isApp(Int32.max), "a sender that already exited")
        XCTAssertFalse(DefaultTerminal.isApp(ProcessInfo.processInfo.processIdentifier), "a test runner outside an app bundle")
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            XCTAssertTrue(DefaultTerminal.isApp(finder.processIdentifier))
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-sender-\(UUID().uuidString)")
        let command = root.appendingPathComponent("gradlew")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        XCTAssertEqual(documentOpen(from: [command]).runnable, [command.standardizedFileURL.path])
        let commandLine = documentOpen(from: [command], runPrograms: false)
        XCTAssertEqual(commandLine.runnable, [])
        XCTAssertEqual(commandLine.folders.directories, [root.standardizedFileURL.path], "a command line opens the program's folder")
    }

    func testPendingOpensKeepOneCapAndAskAboutAProgramOnce() {
        func programs(_ range: Range<Int>) -> [String] { range.map { "/missing/akitty-merge/run-\($0).command" } }
        var pending = DocumentOpen()
        pending.merge(DocumentOpen(folders: FolderOpenRequest(directories: [], skipped: 1), runnable: programs(0..<6), skippedRunnables: 0))
        pending.merge(DocumentOpen(runnable: programs(4..<10), skippedRunnables: 2))
        XCTAssertEqual(pending.runnable, programs(0..<8), "a repeated program is held once and the cap spans deliveries")
        XCTAssertEqual(pending.skippedRunnables, 2 + 2)
        XCTAssertEqual(pending.folders.skipped, 1)
        pending.merge(DocumentOpen(runnable: ["/missing/akitty-merge/./run-0.command"]))
        XCTAssertEqual(pending.runnable.count, 8)
        XCTAssertEqual(pending.skippedRunnables, 4, "a repeat is not counted as skipped")
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
        XCTAssertEqual(executables["LSHandlerRank"] as? String, "Alternate")
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
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        app.defaultTerminalApplication = { _ in terminal }
        XCTAssertTrue(app.validateMenuItem(item))
        // Half done: Unix executables changed, shell scripts did not. The item stays available to finish it.
        app.defaultTerminalApplication = { $0 == .unixExecutable ? Bundle.main.bundleURL : terminal }
        XCTAssertTrue(app.validateMenuItem(item))
        app.defaultTerminalApplication = { $0 == .unixExecutable ? terminal : Bundle.main.bundleURL }
        XCTAssertTrue(app.validateMenuItem(item))
        app.defaultTerminalApplication = { $0 == .unixExecutable ? Bundle.main.bundleURL : terminal }
        XCTAssertEqual(app.defaultTerminalTypesToChange().map(\.identifier), ["com.apple.terminal.shell-script"])
        app.defaultTerminalApplication = { _ in Bundle.main.bundleURL }
        XCTAssertFalse(app.validateMenuItem(item))
        XCTAssertEqual(app.defaultTerminalTypesToChange(), [])
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
        let back = try TerminalWindow(app: app, headless: true)
        let all = [quick, front, back]
        defer {
            for window in all { window.panes.forEach { $0.terminal.shutdown() }; window.window?.close() }
        }
        // Visibility is injected, so the check runs the same without a window server.
        let visible = AkittyApplication.dockTabWindow(orderedFrontToBack: all, quick: quick, isVisible: { $0 === front || $0 === back })
        XCTAssertTrue(visible === front)
        let behind = AkittyApplication.dockTabWindow(orderedFrontToBack: all, quick: quick, isVisible: { $0 === back })
        XCTAssertTrue(behind === back)
        let minimized = AkittyApplication.dockTabWindow(orderedFrontToBack: all, quick: quick, isVisible: { _ in false })
        XCTAssertTrue(minimized === front)
        XCTAssertNil(AkittyApplication.dockTabWindow(orderedFrontToBack: [quick], quick: quick, isVisible: { _ in false }))
        XCTAssertNil(AkittyApplication.dockTabWindow(orderedFrontToBack: [], quick: nil))
    }
}

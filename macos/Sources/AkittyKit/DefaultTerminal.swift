import AppKit
import Darwin
import UniformTypeIdentifiers

/// macOS has no separate "default terminal" setting. The default terminal is the
/// Launch Services shell handler for `public.unix-executable`. Finder opens `.command`
/// and `.tool` files through the separate `com.apple.terminal.shell-script` type.
/// The app menu sets both handlers.
enum DefaultTerminal {
    static let shellScriptType = UTType("com.apple.terminal.shell-script")

    /// True when `candidate` is the same app bundle as `bundleURL`.
    static func isHandler(_ candidate: URL?, for bundleURL: URL) -> Bool {
        guard let candidate else { return false }
        return candidate.resolvingSymlinksInPath().standardizedFileURL.path == bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A Unix executable or an executable Terminal script. A file without the executable bit stays on the
    /// folder-open path, including a project file AX Code opens with `open -a Akitty`.
    static func isRunnable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var directory = ObjCBool(false)
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return false }
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return isRunnableFile(url, contentType: type)
    }

    static func isRunnableFile(_ url: URL, contentType: UTType?) -> Bool {
        switch url.pathExtension.lowercased() {
        case "command", "tool": return true
        default: return contentType?.conforms(to: .unixExecutable) == true
        }
    }

    /// Identity of the file the confirmation showed. A replacement while the alert is open does not match.
    struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
        var size: UInt64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        /// The status-change time cannot be set back by a process, unlike the modification time.
        var changedSeconds: Int64
        var changedNanoseconds: Int64
    }

    static func fileIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: UInt64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    /// Control and format characters, plus line and paragraph separators, can hide the path in the
    /// confirmation or act as typed input before the shell reads quotes. A path that contains one is refused.
    static func containsUnsafePathCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format: return true
            default: return scalar.value == 0x2028 || scalar.value == 0x2029
            }
        }
    }

    /// How a launch line is quoted for the pane's shell. Any other shell is not typed into.
    enum LaunchShell: Equatable {
        /// sh, bash, zsh, dash and ksh: inside single quotes every byte is literal.
        case posix
        /// fish reads `\\` and `\'` as escapes inside single quotes, so both are escaped.
        case fish
    }

    /// The shell the core starts for `configured`: the configured path, else `$SHELL`, else `/bin/zsh`.
    static func resolvedShell(_ configured: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        configured.isEmpty ? environment["SHELL"] ?? "/bin/zsh" : configured
    }

    static func launchShell(_ path: String) -> LaunchShell? {
        switch (path as NSString).lastPathComponent {
        case "sh", "bash", "zsh", "dash", "ksh": return .posix
        case "fish": return .fish
        default: return nil
        }
    }

    /// One shell line that runs `path` and returns to the prompt. Nil when the path is not safe.
    /// `|| true` keeps an interactive zsh with `errexit` from exiting, which would close the pane and drop the output.
    /// The line ends with CR, as the Return key does, so line editors read it as accept-line rather than Ctrl-J.
    static func launchLine(for path: String, shell: LaunchShell = .posix) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0"), !containsUnsafePathCharacters(path) else { return nil }
        // Escape by Unicode scalar. String replacement compares grapheme clusters, so a quote followed by a combining
        // mark would not match, yet the shell reads that quote byte and the path would leave the quotes.
        var quoted = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            switch (shell, scalar) {
            case (.posix, "'"): quoted.append(contentsOf: "'\\''".unicodeScalars)
            case (.fish, "'"): quoted.append(contentsOf: "\\'".unicodeScalars)
            case (.fish, "\\"): quoted.append(contentsOf: "\\\\".unicodeScalars)
            default: quoted.append(scalar)
            }
        }
        return "'" + String(quoted) + "' || true\r"
    }

    /// What a pending launch does on one timer tick.
    enum LaunchStep: Equatable { case wait, send, timedOut }

    /// Without integration nothing reports a prompt, so the line is sent after `plainTimeout`.
    static let plainTimeout: TimeInterval = 2
    /// With integration the line waits for the prompt. A startup question (an update prompt, `read`) can hold it, and
    /// typing into that would answer it, so after `integratedTimeout` the launch is abandoned rather than sent.
    static let integratedTimeout: TimeInterval = 30

    static func launchStep(ready: Bool, integrated: Bool, elapsed: TimeInterval) -> LaunchStep {
        if ready { return .send }
        if integrated { return elapsed >= integratedTimeout ? .timedOut : .wait }
        return elapsed >= plainTimeout ? .send : .wait
    }

    /// Time a launch has waited, not counting time a confirmation or a sheet held it, so a slow second
    /// confirmation does not use up the first launch's wait.
    struct LaunchClock: Equatable {
        private(set) var elapsed: TimeInterval = 0
        private var last: TimeInterval
        init(now: TimeInterval) { last = now }
        mutating func tick(now: TimeInterval, paused: Bool) -> TimeInterval {
            if !paused { elapsed += max(0, now - last) }
            last = now
            return elapsed
        }
    }

    /// Key for spotting the same program twice in one request, through `/tmp` → `/private/tmp` and other links.
    /// `realpath` is used because `resolvingSymlinksInPath` maps `/private/tmp` back to `/tmp`, not to one form.
    static func duplicateKey(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when declining the macOS confirmation produced `error`. The rest of the change is then skipped quietly.
    /// A wrapped cancel (`NSUnderlyingErrorKey`) counts too, up to four levels deep.
    static func isUserCancel(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let error = current else { return false }
            if (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
                || (error.domain == NSOSStatusErrorDomain && error.code == userCanceledErr) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// One Finder or `open -a` delivery, split into folder windows and programs to run.
/// Folders and programs share one cap, in the order they were handed over.
struct DocumentOpen: Equatable {
    var folders = FolderOpenRequest()
    var runnable: [String] = []
    var skippedRunnables = 0

    /// Adds a delivery that arrived before launch, while programs wait for the app to come to the front. The held
    /// programs keep one cap across deliveries, and one that is already held is asked about once.
    mutating func merge(_ other: DocumentOpen, limit: Int = 8) {
        var held = Set(runnable.map(DefaultTerminal.duplicateKey))
        for path in other.runnable where held.insert(DefaultTerminal.duplicateKey(path)).inserted {
            if runnable.count < limit { runnable.append(path) } else { skippedRunnables += 1 }
        }
        skippedRunnables += other.skippedRunnables
        folders.skipped += other.folders.skipped
    }
}

func documentOpen(from urls: [URL], limit: Int = 8) -> DocumentOpen {
    var open = DocumentOpen()
    var slots = limit
    var seen: Set<String> = []
    var seenRunnable: Set<String> = []
    for url in urls {
        if DefaultTerminal.isRunnable(url) {
            // A repeated program is asked about and run once.
            guard seenRunnable.insert(DefaultTerminal.duplicateKey(url.standardizedFileURL.path)).inserted else { continue }
            if slots > 0 { open.runnable.append(url.standardizedFileURL.path); slots -= 1 }
            else { open.skippedRunnables += 1 }
            continue
        }
        let one = folderOpenRequest(from: [url], limit: 1)
        if let directory = one.directories.first {
            guard seen.insert(directory).inserted else { continue }
            if slots > 0 { open.folders.directories.append(directory); slots -= 1 }
            else { open.folders.skipped += 1 }
        } else {
            open.folders.skipped += one.skipped
        }
    }
    return open
}

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
    }

    static func fileIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: UInt64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
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

    /// One POSIX shell line that runs `path` and returns to the prompt. Nil when the path is not safe.
    /// `|| true` keeps an interactive zsh with `errexit` from exiting, which would close the pane and drop the output.
    /// The quote is for sh, bash and zsh. The line is sent after the prompt so startup does not consume it.
    static func launchLine(for path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0"), !containsUnsafePathCharacters(path) else { return nil }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' || true\n"
    }

    /// Send once the integrated prompt is up. Without integration, send after `timeout` so startup can finish.
    static func shouldSendLaunchCommand(ready: Bool, elapsed: TimeInterval, timeout: TimeInterval = 2) -> Bool {
        ready || elapsed >= timeout
    }
}

/// One Finder or `open -a` delivery, split into folder windows and programs to run.
/// Folders and programs share one cap, in the order they were handed over.
struct DocumentOpen: Equatable {
    var folders = FolderOpenRequest()
    var runnable: [String] = []
    var skippedRunnables = 0
}

func documentOpen(from urls: [URL], limit: Int = 8) -> DocumentOpen {
    var open = DocumentOpen()
    var slots = limit
    var seen: Set<String> = []
    for url in urls {
        if DefaultTerminal.isRunnable(url) {
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

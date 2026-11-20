import AppKit
import Darwin
import QuartzCore
import CryptoKit
@testable import AkittyKit

/// Explicitly opt-in: opens a window and drives real PTYs and the normal snapshot/raster/Metal path.
/// Reports synthetic Enter/scroll dispatch to GPU completion. Presentation timestamp availability is separate.
@MainActor final class NativePipelineProbe {
    static let allScenes = ["single-typing", "single-unicode-typing", "single-narrow-typing", "single-decorated-typing", "single-cjk-typing", "four-ascii-typing", "four-unicode-typing", "four-unicode-scroll", "four-ascii-burst", "four-unicode-burst", "four-box-typing", "four-box-burst"]

    @MainActor private final class Trace {
        weak var terminal: TerminalView?
        var enabled = false, softwareFallback = false
        var snapshots = 0, rasters = 0, presents = 0, fullUploads = 0, partialUploads = 0, bytes = 0
        var uploadCounts: [String: Int] = [:], uploadBytes: [String: Int] = [:]
        var snapshotStart: Double?, rasterStart: Double?, uploadStart: Double?
        var snapshotMS: [Double] = [], rasterMS: [Double] = [], uploadMS: [Double] = []
        var inputs = NativeInputTrace(), marker: String?
        var changedSnapshots = 0, unchangedSnapshots = 0
        var positivePresentationTimes = 0, zeroPresentationTimes = 0
        func event(_ event: NativeFrameEvent) {
            let now = CACurrentMediaTime()
            switch event {
            case .snapshotStarted:
                if enabled { snapshots += 1; snapshotStart = now }
            case .snapshotFinished(let revision):
                if enabled, let start = snapshotStart, snapshotMS.count < 5000 { snapshotMS.append((now - start) * 1000) }
                snapshotStart = nil
                if enabled { if revision == nil { unchangedSnapshots += 1 } else { changedSnapshots += 1 } }
                if let revision, marker == nil || terminal?.snapshot?.text.contains(marker!) == true { inputs.identify(revision: revision) }
            case .rasterStarted:
                if enabled { rasters += 1; rasterStart = now }
            case .rasterReady:
                if enabled, let start = rasterStart, rasterMS.count < 5000 { rasterMS.append((now - start) * 1000) }
                rasterStart = nil; uploadStart = now
            case .rasterCompleted(let revision):
                if softwareFallback { inputs.receive(.softwareTerminal, revision: revision, frame: revision, time: now) }
            case .uploaded(let count, let full, let resource):
                if enabled {
                    bytes += count; if full { fullUploads += 1 } else { partialUploads += 1 }
                    uploadCounts[resource.rawValue, default: 0] += 1
                    uploadBytes[resource.rawValue, default: 0] += count
                }
            case .handedOff:
                if enabled, let start = uploadStart, uploadMS.count < 5000 { uploadMS.append((now - start) * 1000) }
                uploadStart = nil
            case .drawStarted(let revision, let frame, let time):
                inputs.receive(.drawStart, revision: revision, frame: frame, time: time)
            case .commandCommitted(let revision, let frame, let time):
                inputs.receive(.commit, revision: revision, frame: frame, time: time)
            case .presented(let revision, let frame, let time):
                if enabled { if time.isFinite && time > 0 { positivePresentationTimes += 1 } else { zeroPresentationTimes += 1 } }
                inputs.receive(.presentation, revision: revision, frame: frame, time: time)
            case .gpuCompleted(let revision, let frame, let time):
                if enabled { presents += 1 }
                inputs.receive(.gpu, revision: revision, frame: frame, time: time)
            }
        }
        var object: [String: Any] {
            ["snapshot_builds": snapshots, "changed_snapshots": changedSnapshots, "unchanged_snapshots": unchangedSnapshots, "raster_builds": rasters, "gpu_completions": presents, "positive_presentation_timestamps": positivePresentationTimes, "zero_presentation_timestamps": zeroPresentationTimes,
             "full_uploads": fullUploads, "partial_uploads": partialUploads, "uploaded_bytes": bytes,
             "upload_counts_by_resource": uploadCounts, "upload_bytes_by_resource": uploadBytes,
             "snapshot_ms": snapshotMS, "raster_ms": rasterMS, "upload_ms": uploadMS]
        }
    }
    private func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 5
        while !condition(), CACurrentMediaTime() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard condition() else { throw AkittyError.core("native pipeline probe timed out") }
    }
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let samples = Int(environment["AKITTY_NATIVE_PROBE_SAMPLES"] ?? "60") ?? 0
        guard (3...100).contains(samples), let output = environment["AKITTY_NATIVE_PROBE_OUTPUT"] else {
            throw AkittyError.core("probe needs an output path and 3...100 samples")
        }
        let suite = "akitty.native-pipeline-probe.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scenes = Self.allScenes
        let selected = environment["AKITTY_NATIVE_PROBE_SCENES"].flatMap { $0.isEmpty ? nil : $0 }?.split(separator: ",").map(String.init) ?? scenes
        guard !selected.isEmpty, selected.count == Set(selected).count, selected.allSatisfy(scenes.contains) else { throw AkittyError.core("unknown or repeated native probe scene") }
        let profile = environment["AKITTY_NATIVE_PROBE_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
        var results: [[String: Any]] = []
        for condition in selected {
            let lines = condition.hasSuffix("burst") ? 8 : 1
            let count = condition.hasPrefix("single-") ? 1 : 4
            var preferences = TerminalPreferences()
            preferences.shell = "/bin/sh"; preferences.shellIntegration = false
            preferences.fontName = "Menlo"; preferences.fontSize = 13; preferences.scrollback = 512
            preferences.silentMode = true; preferences.folderHistory = false
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1360, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.isRestorable = false; window.title = "AkiTTY native pipeline probe"
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1360, height: 900)); window.contentView = host
            var terminals: [TerminalView] = [], traces: [Trace] = []
            defer { for terminal in terminals { terminal.onNativeFrameEvent = nil; terminal.shutdown() }; window.close() }
            let forceSoftware = environment["AKITTY_NATIVE_PROBE_FORCE_SOFTWARE"] == "1"
            for pane in 0..<count {
                let terminal = try TerminalView(headless: false, forceSoftware: forceSoftware, forceShaderFailure: false, initial: preferences, defaults: defaults)
                let trace = Trace(); trace.terminal = terminal; trace.softwareFallback = forceSoftware
                terminal.onNativeFrameEvent = { trace.event($0) }
                terminal.frame = count == 1 ? host.bounds : NSRect(x: (pane % 2) * 680, y: (1 - pane / 2) * 450, width: 680, height: 450)
                terminals.append(terminal); traces.append(trace); host.addSubview(terminal)
            }
            window.makeKeyAndOrderFront(nil); NSApp.activate(); window.makeFirstResponder(terminals[0])
            for pane in 0..<count {
                var program = "/usr/bin/awk '{printf \"%s\\r\\n\", $0; fflush()}'"
                if condition.contains("decorated") { program = "/usr/bin/awk '{printf \"%s \\033[4méñßα\\033[0m →Ⅲ\\r\\n\", $0; fflush()}'" }
                else if condition.contains("narrow") { program = "/usr/bin/awk '{printf \"%s éñßαλ€ →Ⅲ\\r\\n\", $0; fflush()}'" }
                // Renderer-stable CJK: wide ideographs, hangul and fullwidth forms in three foreground
                // colours, with no emoji, combining mark or cluster that would force the CPU path.
                else if condition.contains("cjk") { program = "/usr/bin/awk '{printf \"%s \\033[38;2;90;180;240m漢字日本語\\033[0m\\033[38;2;240;180;90m中文한글\\033[0m、。「」ＡＢ\\r\\n\", $0; fflush()}'" }
                else if condition.contains("unicode") { program = "/usr/bin/awk '{printf \"%s 漢字 emoji 😀\\r\\n\", $0; fflush()}'" }
                else if condition.contains("box") { program = "/usr/bin/awk '{printf \"%s █▓▒░ ⠿⠋⠙⠸\\r\\n\", $0; fflush()}'" }
                if pane > 0 {
                    let pattern: String
                    if condition.contains("unicode") { pattern = "\u{1b}[38;2;90;180;240m漢字かな한글 👩🏽‍💻 e\u{301} log output\u{1b}[0m\r\n" }
                    else if condition.contains("box") { pattern = "\u{1b}[38;2;90;180;240m╭─┬─╮ │ █▓▒░ ⠿⠋⠙⠸ ⣿⣷⣦ ╰─┴─╯\u{1b}[0m\r\n" }
                    else { pattern = "\u{1b}[32mbuild log 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\u{1b}[0m\r\n" }
                    let literal = String(data: try JSONSerialization.data(withJSONObject: [pattern]), encoding: .utf8)!
                    let ready = String(data: try JSONSerialization.data(withJSONObject: ["\u{1b}]2;probe-ready\u{7}"]), encoding: .utf8)!
                    let js = "const s=\(literal)[0];let ready=true,n=0;process.stdout.write(\(ready)[0]);process.stdout.on('drain',()=>ready=true);setInterval(()=>{if(ready){let t='';for(let j=0;j<\(lines);j++)t+=String(n++).padStart(8,'0')+' '+s;ready=process.stdout.write(t)}},8)"
                    guard let node = environment["AKITTY_NATIVE_PROBE_NODE"], node.hasPrefix("/") else { throw AkittyError.core("probe requires an absolute Node executable") }
                    program = "'\(node.replacingOccurrences(of: "'", with: "'\\''"))' -e '\(js.replacingOccurrences(of: "'", with: "'\\''"))'"
                }
                let seedText = condition.contains("narrow") || condition.contains("decorated") ? "seed éñßαλ€ →Ⅲ"
                    : condition.contains("cjk") ? "seed 漢字日本語"
                    : condition.contains("unicode") ? "seed 漢字 emoji 😀"
                    : condition.contains("box") ? "seed █▓▒░ ⠿⠋⠙⠸" : "seed ASCII"
                let seed = pane == 0 ? "i=0; while [ $i -lt 100 ]; do printf '\(seedText) line %s\\r\\n' $i; i=$((i+1)); done; " : ""
                let title = pane == 0 ? "printf '\\033]2;probe-ready\\007'; " : ""
                let command = "stty -echo -onlcr; PS1=; printf '\\033[2J\\033[H'; \(seed)\(title)\(program)\r"
                guard command.utf8.count <= 900 else { throw AkittyError.core("probe command exceeds the canonical PTY line bound") }
                terminals[pane].send(command)
            }
            try await wait { terminals.allSatisfy { $0.snapshot?.title == "probe-ready" } }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let allowSoftware = forceSoftware
            guard window.isKeyWindow, window.firstResponder === terminals[0], allowSoftware || terminals.allSatisfy({ !$0.health.usesSoftware }) else {
                throw allowSoftware ? AkittyError.core("probe lost foreground focus") : AkittyError.core("probe requires a focused visible Metal window")
            }
            let foreground = terminals[0], trace = traces[0]
            var sampler: Process?
            var cpuStart = cpuSeconds(), start = CACurrentMediaTime(), nextInput = CACurrentMediaTime()
            let intervals: [Double] = [0.083, 0.097, 0.113, 0.091, 0.109, 0.101]
            for i in 0..<(samples + 3) {
                guard window.isKeyWindow, window.firstResponder === foreground else { throw AkittyError.core("probe lost foreground focus") }
                if i == 3 {
                    for trace in traces { trace.enabled = true }
                    cpuStart = cpuSeconds(); start = CACurrentMediaTime(); nextInput = start
                    if let profile {
                        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "4", "1", "-file", "\(profile).\(condition).sample.txt"]
                        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                        try process.run(); sampler = process
                    }
                }
                let delay = nextInput - CACurrentMediaTime()
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
                let marker = condition.hasSuffix("scroll") ? nil : String(format: "NATIVE_FRAME_%04d", i)
                trace.marker = marker
                guard trace.inputs.begin(base: foreground.snapshot?.revision ?? 0, time: CACurrentMediaTime()) else {
                    throw AkittyError.core("native input trace requires serialized GPU-completed submissions")
                }
                // Echo is disabled and awk emits complete lines only, so the marker
                // cannot satisfy the target before Enter submits the input line.
                if let marker { foreground.send(marker) }
                if condition.hasSuffix("scroll") {
                    let cg = try require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                                   wheel1: i % 2 == 0 ? 3 : -3, wheel2: 0, wheel3: 0))
                    foreground.scrollWheel(with: try require(NSEvent(cgEvent: cg)))
                } else {
                    let event = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    NSApp.sendEvent(event)
                    let release = try require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                        timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    NSApp.sendEvent(release)
                }
                try await wait { trace.inputs.samples.last?.isTerminated == true }
                nextInput = max(nextInput + intervals[i % intervals.count], CACurrentMediaTime())
            }
            let wall = CACurrentMediaTime() - start, cpu = cpuSeconds() - cpuStart
            for trace in traces { trace.enabled = false }
            guard forceSoftware || terminals.allSatisfy({ !$0.health.usesSoftware }) else {
                throw AkittyError.core("a pane fell back to software rendering during the measured scene")
            }
            // Presentation may arrive after GPU completion; retain all denominators
            // and nulls rather than silently treating an unavailable callback as fast.
            if !forceSoftware {
                let presentationDeadline = CACurrentMediaTime() + 1
                while trace.inputs.samples.contains(where: { $0.presentation == nil }), CACurrentMediaTime() < presentationDeadline {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            if let sampler {
                try await wait { !sampler.isRunning }
                guard sampler.terminationStatus == 0 else { throw AkittyError.core("native CPU sampler failed") }
            }
            let measured = Array(trace.inputs.samples.dropFirst(3))
            let gpu = measured.compactMap(\.gpuMS)
            let softwareTerminal = measured.compactMap(\.softwareTerminalMS)
            let terminalMS = measured.map { forceSoftware ? $0.softwareTerminalMS : $0.gpuMS }
            let terminal = terminalMS.compactMap { $0 }
            guard measured.count == samples, terminal.count == samples, trace.inputs.overflowBeforeTarget == 0 else { throw AkittyError.core("missing or overflowed native input samples") }
            let records: [[String: Any]] = measured.map { sample in
                ["base_revision": sample.base, "target_revision": sample.target as Any? ?? NSNull(),
                 "draw_started_revision": sample.drawStart?.revision as Any? ?? NSNull(), "draw_started_frame": sample.drawStart?.frame as Any? ?? NSNull(), "draw_started_ms": sample.drawStartMS as Any? ?? NSNull(),
                 "commit_revision": sample.commit?.revision as Any? ?? NSNull(), "commit_frame": sample.commit?.frame as Any? ?? NSNull(), "commit_ms": sample.commitMS as Any? ?? NSNull(),
                 "gpu_revision": sample.gpu?.revision as Any? ?? NSNull(), "gpu_frame": sample.gpu?.frame as Any? ?? NSNull(), "gpu_ms": sample.gpuMS as Any? ?? NSNull(),
                 "software_terminal_revision": sample.softwareTerminal?.revision as Any? ?? NSNull(), "software_terminal_ms": sample.softwareTerminalMS as Any? ?? NSNull(),
                 "presentation_revision": sample.presentation?.revision as Any? ?? NSNull(), "presentation_frame": sample.presentation?.frame as Any? ?? NSNull(), "presentation_ms": sample.presentationMS as Any? ?? NSNull()]
            }
            results.append(["condition": condition, "samples": samples, "warmup": 3,
                "renderer_mode": forceSoftware ? "software" : "metal",
                "terminal_phase_semantics": forceSoftware ? "successful software raster completion" : "Metal command-buffer completion callback",
                "event_to_draw_start_ms": measured.map { $0.drawStartMS as Any? ?? NSNull() },
                "event_to_commit_ms": measured.map { $0.commitMS as Any? ?? NSNull() },
                "event_to_terminal_ms": terminalMS, "event_to_gpu_ms": gpu, "event_to_software_terminal_ms": softwareTerminal, "input_samples": records,
                "event_to_present_ms": measured.map { $0.presentationMS as Any? ?? NSNull() },
                "missing_terminal_samples": measured.filter { !$0.isTerminated }.count,
                "missing_presentation_samples": measured.filter { $0.presentation == nil }.count,
                "missing_draw_start_samples": measured.filter { $0.drawStart == nil }.count,
                "missing_commit_samples": measured.filter { $0.commit == nil }.count,
                "invalid_draw_callbacks": trace.inputs.invalidDraw,
                "invalid_presentation_callbacks": trace.inputs.invalidPresentation, "invalid_gpu_callbacks": trace.inputs.invalidGPU,
                "invalid_software_terminal_callbacks": trace.inputs.invalidSoftwareTerminal,
                "profiled": profile != nil, "wall_seconds": wall, "cpu_seconds": cpu,
                "process_cpu_percent": cpu / wall * 100, "panes": traces.map(\.object),
                "grids": terminals.map { ["cols": $0.snapshot?.cols ?? 0, "rows": $0.snapshot?.rows ?? 0] },
                "scale": window.backingScaleFactor, "window_points": [1360, 900],
                "input_intervals_seconds": intervals, "producer_interval_ms": 8, "producer_lines_per_tick": lines])
            print("NATIVE_PIPELINE \(condition) renderer=\(forceSoftware ? "software" : "metal") cpu=\(cpu / wall * 100) samples=\(terminal.count) missing_presentations=\(measured.filter { $0.presentation == nil }.count)")
        }
        let executable = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))
        let object: [String: Any] = ["schema": 4, "scope": "synthetic-native-input-to-render-terminal-and-presentation",
            "scene_comparability": "renderer-stable schema-4 scenes are not directly comparable with earlier Unicode-seeded scenes",
            "upload_accounting": "logical resource-update payload bytes; full identifies a fresh/replacement update path, partial identifies an in-place update path and may include zero-byte bitmap damage",
            "probe_binary_sha256": SHA256.hash(data: executable).map { String(format: "%02x", $0) }.joined(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "results": results]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw AkittyError.core("native probe required value unavailable") }
    return value
}

@MainActor private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await NativePipelineProbe().run(); NSApp.terminate(nil) }
            catch { fputs("Native pipeline probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct NativeProbeApp {
    @MainActor static func main() {
        let environment = ProcessInfo.processInfo.environment
        let selectedScenes = environment["AKITTY_NATIVE_PROBE_SCENES"].flatMap { $0.isEmpty ? nil : $0 }?.split(separator: ",").count ?? NativePipelineProbe.allScenes.count
        let samples = Int(environment["AKITTY_NATIVE_PROBE_SAMPLES"] ?? "60").flatMap { (3...100).contains($0) ? $0 : nil } ?? 60
        let deadline = max(120.0, Double(selectedScenes) * (Double(samples + 3) * 0.2 + 20) + 60)
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
            fputs("Native pipeline probe exceeded \(Int(deadline)) seconds\n", stderr); exit(1)
        }
        let app = NSApplication.shared, delegate = ProbeDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

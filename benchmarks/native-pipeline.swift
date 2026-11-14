import AppKit
import Darwin
import QuartzCore
import CryptoKit
@testable import AkittyKit

/// Explicitly opt-in: opens a window and drives real PTYs and the normal snapshot/raster/Metal path.
/// Reports synthetic Enter/scroll dispatch to GPU completion. Presentation timestamp availability is separate.
@MainActor final class NativePipelineProbe {
    @MainActor private final class Trace {
        weak var terminal: TerminalView?
        var enabled = false
        var snapshots = 0, rasters = 0, presents = 0, fullUploads = 0, partialUploads = 0, bytes = 0
        var snapshotStart: Double?, rasterStart: Double?, uploadStart: Double?
        var snapshotMS: [Double] = [], rasterMS: [Double] = [], uploadMS: [Double] = [], latencyMS: [Double] = []
        var positivePresentationTimes = 0, zeroPresentationTimes = 0
        var pending: (marker: String?, base: UInt64, start: Double, target: UInt64?)?
        func event(_ event: NativeFrameEvent) {
            let now = CACurrentMediaTime()
            switch event {
            case .snapshotStarted:
                if enabled { snapshots += 1; snapshotStart = now }
            case .snapshotFinished(let revision):
                if enabled, let start = snapshotStart, snapshotMS.count < 5000 { snapshotMS.append((now - start) * 1000) }
                snapshotStart = nil
                if let revision, var p = pending, p.target == nil, revision > p.base,
                   p.marker == nil || terminal?.snapshot?.text.contains(p.marker!) == true {
                    p.target = revision; pending = p
                }
            case .rasterStarted:
                if enabled { rasters += 1; rasterStart = now }
            case .rasterReady:
                if enabled, let start = rasterStart, rasterMS.count < 5000 { rasterMS.append((now - start) * 1000) }
                rasterStart = nil; uploadStart = now
            case .uploaded(let count, let full):
                if enabled { bytes += count; if full { fullUploads += 1 } else { partialUploads += 1 } }
            case .handedOff:
                if enabled, let start = uploadStart, uploadMS.count < 5000 { uploadMS.append((now - start) * 1000) }
                uploadStart = nil
            case .presented(_, let time):
                if enabled { if time > 0 { positivePresentationTimes += 1 } else { zeroPresentationTimes += 1 } }
            case .gpuCompleted(let revision, let time):
                if enabled { presents += 1 }
                if let p = pending, let target = p.target, revision >= target, time >= p.start {
                    latencyMS.append((time - p.start) * 1000); pending = nil
                }
            }
        }
        var object: [String: Any] {
            ["snapshot_builds": snapshots, "raster_builds": rasters, "gpu_completions": presents, "positive_presentation_timestamps": positivePresentationTimes, "zero_presentation_timestamps": zeroPresentationTimes,
             "full_uploads": fullUploads, "partial_uploads": partialUploads, "uploaded_bytes": bytes,
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
        var results: [[String: Any]] = []
        for condition in ["single-typing", "four-ascii-typing", "four-unicode-typing", "four-unicode-scroll"] {
            let count = condition == "single-typing" ? 1 : 4
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
            for pane in 0..<count {
                let terminal = try TerminalView(headless: false, forceSoftware: false, forceShaderFailure: false, initial: preferences, defaults: defaults)
                let trace = Trace(); trace.terminal = terminal; terminal.onNativeFrameEvent = { trace.event($0) }
                terminal.frame = count == 1 ? host.bounds : NSRect(x: (pane % 2) * 680, y: (1 - pane / 2) * 450, width: 680, height: 450)
                terminals.append(terminal); traces.append(trace); host.addSubview(terminal)
            }
            window.makeKeyAndOrderFront(nil); NSApp.activate(); window.makeFirstResponder(terminals[0])
            for pane in 0..<count {
                var program = "/usr/bin/awk '{printf \"%s\\r\\n\", $0; fflush()}'"
                if pane > 0 {
                    let pattern = condition.contains("unicode") ? "\u{1b}[38;2;90;180;240m漢字かな한글 👩🏽‍💻 e\u{301} log output\u{1b}[0m\r\n" : "\u{1b}[32mbuild log 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\u{1b}[0m\r\n"
                    let literal = String(data: try JSONSerialization.data(withJSONObject: [pattern]), encoding: .utf8)!
                    let ready = String(data: try JSONSerialization.data(withJSONObject: ["\u{1b}]2;probe-ready\u{7}"]), encoding: .utf8)!
                    let js = "const s=\(literal)[0];let ready=true,n=0;process.stdout.write(\(ready)[0]);process.stdout.on('drain',()=>ready=true);setInterval(()=>{if(ready){let t='';for(let j=0;j<1;j++)t+=String(n++).padStart(8,'0')+' '+s;ready=process.stdout.write(t)}},8)"
                    guard let node = environment["AKITTY_NATIVE_PROBE_NODE"], node.hasPrefix("/") else { throw AkittyError.core("probe requires an absolute Node executable") }
                    program = "'\(node.replacingOccurrences(of: "'", with: "'\\''"))' -e '\(js.replacingOccurrences(of: "'", with: "'\\''"))'"
                }
                let seed = pane == 0 ? "i=0; while [ $i -lt 100 ]; do printf 'seed 漢字 emoji 😀 line %s\\r\\n' $i; i=$((i+1)); done; " : ""
                let title = pane == 0 ? "printf '\\033]2;probe-ready\\007'; " : ""
                let command = "stty -echo -onlcr; PS1=; printf '\\033[2J\\033[H'; \(seed)\(title)\(program)\r"
                guard command.utf8.count <= 900 else { throw AkittyError.core("probe command exceeds the canonical PTY line bound") }
                terminals[pane].send(command)
            }
            try await wait { terminals.allSatisfy { $0.snapshot?.title == "probe-ready" } }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard window.isKeyWindow, window.firstResponder === terminals[0], terminals.allSatisfy({ !$0.health.usesSoftware }) else {
                throw AkittyError.core("probe requires a focused visible Metal window")
            }
            let foreground = terminals[0], trace = traces[0]
            var cpuStart = cpuSeconds(), start = CACurrentMediaTime(), nextInput = CACurrentMediaTime()
            let intervals: [Double] = [0.083, 0.097, 0.113, 0.091, 0.109, 0.101]
            for i in 0..<(samples + 3) {
                guard window.isKeyWindow, window.firstResponder === foreground else { throw AkittyError.core("probe lost foreground focus") }
                if i == 3 {
                    for trace in traces { trace.enabled = true }
                    trace.latencyMS = []; cpuStart = cpuSeconds(); start = CACurrentMediaTime(); nextInput = start
                }
                let delay = nextInput - CACurrentMediaTime()
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
                let marker = condition.hasSuffix("scroll") ? nil : String(format: "NATIVE_FRAME_%04d", i)
                if let marker { foreground.send(marker) }
                trace.pending = (marker, foreground.snapshot?.revision ?? 0, CACurrentMediaTime(), nil)
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
                try await wait { trace.pending == nil }
                nextInput = max(nextInput + intervals[i % intervals.count], CACurrentMediaTime())
            }
            let wall = CACurrentMediaTime() - start, cpu = cpuSeconds() - cpuStart
            guard trace.latencyMS.count == samples else { throw AkittyError.core("missing native presentation samples") }
            results.append(["condition": condition, "samples": samples, "warmup": 3,
                "event_to_gpu_ms": trace.latencyMS, "wall_seconds": wall, "cpu_seconds": cpu,
                "process_cpu_percent": cpu / wall * 100, "panes": traces.map(\.object),
                "grids": terminals.map { ["cols": $0.snapshot?.cols ?? 0, "rows": $0.snapshot?.rows ?? 0] },
                "scale": window.backingScaleFactor, "window_points": [1360, 900],
                "input_intervals_seconds": intervals, "producer_interval_ms": 8, "producer_lines_per_tick": 1])
            print("NATIVE_PIPELINE \(condition) cpu=\(cpu / wall * 100) samples=\(trace.latencyMS.count)")
        }
        let executable = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))
        let object: [String: Any] = ["schema": 1, "scope": "synthetic-native-event-to-gpu-completion",
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            fputs("Native pipeline probe exceeded 120 seconds\n", stderr); exit(1)
        }
        let app = NSApplication.shared, delegate = ProbeDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

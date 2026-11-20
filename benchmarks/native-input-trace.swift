import Foundation

/// Benchmark-only correlation. Draw phases share the GPU frame identity; presentation has an independent lifetime.
struct NativeInputTrace {
    enum Kind { case drawStart, commit, gpu, softwareTerminal, presentation }
    struct Completion {
        let revision: UInt64, frame: UInt64, time: Double
    }
    struct Sample {
        let base: UInt64, start: Double
        var target: UInt64?
        var drawStart: Completion?, commit: Completion?, gpu: Completion?
        var softwareTerminal: Completion?, presentation: Completion?
        var drawStartMS: Double? { drawStart.map { ($0.time - start) * 1000 } }
        var commitMS: Double? { commit.map { ($0.time - start) * 1000 } }
        var gpuMS: Double? { gpu.map { ($0.time - start) * 1000 } }
        var softwareTerminalMS: Double? { softwareTerminal.map { ($0.time - start) * 1000 } }
        var presentationMS: Double? { presentation.map { ($0.time - start) * 1000 } }
        var terminal: Completion? { gpu ?? softwareTerminal }
        var isTerminated: Bool { terminal != nil }
    }
    private(set) var samples: [Sample] = []
    private var drawStarts: [Completion] = [], commits: [Completion] = []
    private var gpu: [Completion] = [], softwareTerminals: [Completion] = [], presentations: [Completion] = []
    private(set) var invalidDraw = 0, invalidGPU = 0, invalidSoftwareTerminal = 0, invalidPresentation = 0
    private(set) var overflowBeforeTarget = 0

    @discardableResult mutating func begin(base: UInt64, time: Double) -> Bool {
        // The driver submits its next input only after a terminal completion identifies
        // the current target. Older presentations may remain pending independently.
        guard samples.count < 128, time.isFinite, time > 0,
              samples.last == nil || samples.last?.isTerminated == true else { return false }
        samples.append(Sample(base: base, start: time))
        return true
    }
    mutating func identify(revision: UInt64) {
        guard let index = samples.indices.last, samples[index].target == nil, revision > samples[index].base else { return }
        samples[index].target = revision
        // Main-queue delivery may lag the underlying callbacks. Reconsider timestamps once the target is known.
        for completion in gpu { match(completion, kind: .gpu) }
        for completion in softwareTerminals { match(completion, kind: .softwareTerminal) }
        for completion in presentations { match(completion, kind: .presentation) }
        reconcileDrawPhases()
    }
    mutating func receive(_ kind: Kind, revision: UInt64, frame: UInt64? = nil, time: Double) {
        guard time.isFinite && time > 0 else {
            switch kind {
            case .drawStart, .commit: invalidDraw += 1
            case .gpu: invalidGPU += 1
            case .softwareTerminal: invalidSoftwareTerminal += 1
            case .presentation: invalidPresentation += 1
            }
            return
        }
        let completion = Completion(revision: revision, frame: frame ?? revision, time: time)
        switch kind {
        case .drawStart:
            drawStarts.append(completion)
            if drawStarts.count > 32 { noteOverflow(drawStarts.removeFirst()) }
            reconcileDrawPhases()
        case .commit:
            commits.append(completion)
            if commits.count > 32 { noteOverflow(commits.removeFirst()) }
            reconcileDrawPhases()
        case .gpu:
            gpu.append(completion)
            if gpu.count > 32 { noteOverflow(gpu.removeFirst()) }
            match(completion, kind: kind)
            reconcileDrawPhases()
        case .softwareTerminal:
            softwareTerminals.append(completion)
            if softwareTerminals.count > 32 { noteOverflow(softwareTerminals.removeFirst()) }
            match(completion, kind: kind)
        case .presentation:
            presentations.append(completion)
            if presentations.count > 32 { noteOverflow(presentations.removeFirst()) }
            match(completion, kind: kind)
        }
    }
    private mutating func noteOverflow(_ completion: Completion) {
        if let pending = samples.last, pending.target == nil,
           completion.revision > pending.base, completion.time >= pending.start { overflowBeforeTarget += 1 }
    }
    private mutating func match(_ completion: Completion, kind: Kind) {
        for index in samples.indices {
            guard let target = samples[index].target, completion.revision >= target,
                  completion.time >= samples[index].start else { continue }
            switch kind {
            case .gpu:
                if samples[index].gpu == nil || completion.time < samples[index].gpu!.time { samples[index].gpu = completion }
            case .softwareTerminal:
                if samples[index].softwareTerminal == nil || completion.time < samples[index].softwareTerminal!.time { samples[index].softwareTerminal = completion }
            case .presentation:
                if samples[index].presentation == nil || completion.time < samples[index].presentation!.time { samples[index].presentation = completion }
            case .drawStart, .commit:
                break
            }
        }
    }
    private mutating func reconcileDrawPhases() {
        for index in samples.indices {
            guard let gpu = samples[index].gpu else { continue }
            if samples[index].drawStart?.revision != gpu.revision || samples[index].drawStart?.frame != gpu.frame {
                samples[index].drawStart = drawStarts.filter {
                    $0.revision == gpu.revision && $0.frame == gpu.frame && $0.time >= samples[index].start
                }.min { $0.time < $1.time }
            }
            if samples[index].commit?.revision != gpu.revision || samples[index].commit?.frame != gpu.frame {
                samples[index].commit = commits.filter {
                    $0.revision == gpu.revision && $0.frame == gpu.frame && $0.time >= samples[index].start
                }.min { $0.time < $1.time }
            }
        }
    }
}

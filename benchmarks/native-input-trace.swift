import Foundation

/// Benchmark-only correlation. GPU completion and presentation have independent
/// lifetimes; neither callback can consume the other's sample.
struct NativeInputTrace {
    enum Kind { case gpu, presentation }
    struct Completion {
        let revision: UInt64, time: Double
    }
    struct Sample {
        let base: UInt64, start: Double
        var target: UInt64?
        var gpu: Completion?, presentation: Completion?
        var gpuMS: Double? { gpu.map { ($0.time - start) * 1000 } }
        var presentationMS: Double? { presentation.map { ($0.time - start) * 1000 } }
    }
    private(set) var samples: [Sample] = []
    private var gpu: [Completion] = [], presentations: [Completion] = []
    private(set) var invalidGPU = 0, invalidPresentation = 0, overflowBeforeTarget = 0

    mutating func begin(base: UInt64, time: Double) {
        precondition(samples.count < 128 && time.isFinite && time > 0)
        samples.append(Sample(base: base, start: time))
    }
    mutating func identify(revision: UInt64) {
        guard let index = samples.indices.last, samples[index].target == nil, revision > samples[index].base else { return }
        samples[index].target = revision
        // Main-queue delivery may lag the underlying GPU/presentation callbacks.
        // Reconsider their timestamps when the matching snapshot becomes known.
        for completion in gpu { match(completion, kind: .gpu) }
        for completion in presentations { match(completion, kind: .presentation) }
    }
    mutating func receive(_ kind: Kind, revision: UInt64, time: Double) {
        guard time.isFinite && time > 0 else {
            if kind == .gpu { invalidGPU += 1 } else { invalidPresentation += 1 }
            return
        }
        let completion = Completion(revision: revision, time: time)
        if kind == .gpu {
            gpu.append(completion)
            if gpu.count > 32 { noteOverflow(gpu.removeFirst()) }
        } else {
            presentations.append(completion)
            if presentations.count > 32 { noteOverflow(presentations.removeFirst()) }
        }
        match(completion, kind: kind)
    }
    private mutating func noteOverflow(_ completion: Completion) {
        if let pending = samples.last, pending.target == nil,
           completion.revision > pending.base, completion.time >= pending.start { overflowBeforeTarget += 1 }
    }
    private mutating func match(_ completion: Completion, kind: Kind) {
        for index in samples.indices {
            guard let target = samples[index].target, completion.revision >= target,
                  completion.time >= samples[index].start else { continue }
            if kind == .gpu {
                if samples[index].gpu == nil || completion.time < samples[index].gpu!.time { samples[index].gpu = completion }
            } else if samples[index].presentation == nil || completion.time < samples[index].presentation!.time {
                samples[index].presentation = completion
            }
        }
    }
}

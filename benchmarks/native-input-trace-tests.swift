import Foundation

@main struct NativeInputTraceTests {
    static func main() {
        var trace = NativeInputTrace()
        trace.begin(base: 7, time: 10)
        precondition(!trace.begin(base: 7, time: 10.001), "an overlapping input cannot steal an unidentified snapshot")
        precondition(trace.samples.count == 1)
        trace.receive(.gpu, revision: 7, time: 10.001)
        trace.receive(.presentation, revision: 8, time: 9.999)
        trace.identify(revision: 7)
        precondition(trace.samples[0].target == nil, "an unchanged snapshot cannot identify input")
        trace.identify(revision: 8)
        precondition(!trace.begin(base: 8, time: 10.001), "target recognition alone is not GPU completion")
        precondition(trace.samples[0].gpu == nil && trace.samples[0].presentation == nil, "old revisions and pre-input timestamps cannot satisfy a sample")
        trace.receive(.gpu, revision: 8, time: 10.002)
        precondition(trace.samples[0].gpu != nil && trace.samples[0].presentation == nil, "GPU completion must leave presentation pending")
        trace.begin(base: 8, time: 10.1)
        trace.identify(revision: 9)
        trace.receive(.presentation, revision: 8, time: 10.003)
        precondition(trace.samples[0].presentation?.revision == 8 && trace.samples[1].presentation == nil, "a late callback belongs to the prior input")
        trace.receive(.presentation, revision: 9, time: 10.102)
        precondition(trace.samples[1].presentation != nil && trace.samples[1].gpu == nil, "presentation may precede GPU callback delivery")
        trace.receive(.gpu, revision: 9, time: 10.101)
        precondition(abs(trace.samples[1].gpuMS! - 1) < 0.00001)
        precondition(abs(trace.samples[1].presentationMS! - 2) < 0.00001)

        trace.begin(base: 9, time: 11)
        trace.receive(.presentation, revision: 11, time: 11.004)
        trace.receive(.gpu, revision: 10, time: 11.002)
        trace.identify(revision: 10)
        precondition(trace.samples[2].gpu?.revision == 10 && trace.samples[2].presentation?.revision == 11, "callbacks delivered before target recognition must survive")
        trace.receive(.presentation, revision: 10, time: 11.003)
        precondition(trace.samples[2].presentation?.revision == 10, "choose the earliest qualifying timestamp, not delivery order")
        for time in [Double.nan, .infinity, 0, -1] {
            trace.receive(.presentation, revision: 12, time: time)
            trace.receive(.gpu, revision: 12, time: time)
        }
        precondition(trace.invalidPresentation == 4 && trace.invalidGPU == 4)
        trace.begin(base: 11, time: 12)
        trace.identify(revision: 12)
        trace.receive(.gpu, revision: 12, time: 12.001)
        precondition(trace.samples[3].presentationMS == nil, "missing presentation must remain missing, never become zero latency")

        var bounded = NativeInputTrace()
        bounded.begin(base: 0, time: 1)
        for revision in 1...40 { bounded.receive(.gpu, revision: UInt64(revision), time: 1 + Double(revision)) }
        precondition(bounded.overflowBeforeTarget > 0, "dropping callbacks before target recognition must be reported")
        var oldHistory = NativeInputTrace()
        for revision in 1...32 { oldHistory.receive(.gpu, revision: UInt64(revision), time: Double(revision)) }
        oldHistory.begin(base: 32, time: 33)
        oldHistory.receive(.gpu, revision: 33, time: 33.1)
        precondition(oldHistory.overflowBeforeTarget == 0, "evicting pre-input history cannot lose the new sample")
        oldHistory.identify(revision: 33)
        precondition(oldHistory.samples[0].gpu?.revision == 33)
        print("Native input trace: independent completion, reordering, stale/invalid callbacks, missing data and bounds passed")
    }
}

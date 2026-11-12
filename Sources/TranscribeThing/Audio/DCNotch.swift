import Foundation

/// The DC notch SpeexDSP's canceller puts the mic through first (`filter_dc_notch16` in mdf.c, at 16 kHz).
struct DCNotch {
    private var memory: (Double, Double) = (0, 0)
    private let radius = 0.982

    /// `samples` through the notch, into `out` (as long), which goes on from the last call.
    mutating func filter(_ samples: [Int16], into out: inout [Double]) {
        let den2 = radius * radius + 0.7 * (1 - radius) * (1 - radius)
        for (index, sample) in samples.enumerated() {
            let input = Double(sample)
            let output = memory.0 + input
            memory.0 = memory.1 + 2 * (-input + radius * output)
            memory.1 = input - den2 * output
            out[index] = radius * output
        }
    }
}

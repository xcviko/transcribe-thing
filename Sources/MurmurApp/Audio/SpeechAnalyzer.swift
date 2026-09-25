import Foundation

// STUB (FOUNDATION): AUDIO replaces this with the adaptive-floor analyzer.
enum SpeechAnalyzer {
    static func stats(for samples: [Float]) -> SpeechStats {
        guard !samples.isEmpty else { return .empty }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let peakDB = peak > 0 ? 20 * log10(peak) : -160
        return SpeechStats(voicedSeconds: peak > 1e-7 ? Double(samples.count) / Recording.sampleRate : 0,
                           peakDBFS: peakDB, isSilent: peak < 1e-7)
    }
}

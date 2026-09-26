import Accelerate
import Foundation

/// Engine-side speech check. The recorder's `SpeechStats` gate most silent dictations before they reach an
/// engine; this tells an empty result on a recording that slipped through ("no speech") from an engine that
/// heard voice and returned nothing.
enum SilenceGuard {
    private static let frameSeconds = 0.03
    /// −50 dBFS: the quietest frame that can count as voice, even over digital silence.
    private static let absoluteFloor: Float = 0.003_16
    /// Voice must clear the noise floor by 10 dB.
    private static let floorMargin: Float = 3.16
    /// A "floor" louder than −45 dBFS is continuous speech without pauses, not room noise.
    private static let loudestFloor: Float = 0.005_62

    /// Below this, an empty result reads as no speech rather than an engine failure.
    static let minimumVoicedSeconds = 0.15

    /// Seconds of 30 ms frames whose RMS clears an adaptive threshold: the noise floor (10th-percentile frame,
    /// capped at −45 dBFS) + 10 dB, never below −50 dBFS.
    static func voicedSeconds(_ samples: [Float], sampleRate: Double = 16_000) -> Double {
        let frame = max(1, Int(sampleRate * frameSeconds))
        let count = samples.count / frame
        guard count > 0 else { return 0 }
        var rms = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<count {
                vDSP_rmsqv(base + i * frame, 1, &rms[i], vDSP_Length(frame))
            }
        }
        let floor = min(rms.sorted()[count / 10], loudestFloor)
        let threshold = max(absoluteFloor, floor * floorMargin)
        let voiced = rms.reduce(0) { $1 > threshold ? $0 + 1 : $0 }
        return Double(voiced) * Double(frame) / sampleRate
    }
}

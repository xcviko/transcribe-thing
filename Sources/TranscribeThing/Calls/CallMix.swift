import Foundation

/// A call's two tracks as the one mono track transcription hears, and the person's mutes cut out of their mic. Both
/// tracks are on the call's clock (`TrackAligner`): sample `n` of each is the same moment, so they add sample by sample.
/// Pure arithmetic on 16 kHz samples, safe anywhere.
enum CallMix {
    /// Each track's gain in the mix: -3 dB, so two loud voices at once rarely reach the limiter.
    static let gain: Float = 0.707_946 // 10^(-3/20)
    /// Where the limiter starts bending: below it a sample goes through as it is.
    static let knee: Float = 0.8

    /// The mic and the other side as one track, `length` samples long (each padded with silence, or cut, to it). A
    /// track that's nil (not recorded, or over before this stretch) leaves the mix just the other one, at full level.
    /// Otherwise each goes in at `gain` and the sum through `limit`, so nothing clips.
    static func mix(mic: [Float]?, remote: [Float]?, length: Int) -> [Float] {
        guard length > 0 else { return [] }
        func fitted(_ samples: [Float]) -> [Float] {
            samples.count >= length ? Array(samples.prefix(length))
                : samples + [Float](repeating: 0, count: length - samples.count)
        }
        switch (mic, remote) {
        case (nil, nil): return [Float](repeating: 0, count: length)
        case (let only?, nil), (nil, let only?): return fitted(only)
        case (let mic?, let remote?):
            var out = [Float](repeating: 0, count: length)
            for i in 0..<min(length, mic.count) { out[i] = mic[i] * gain }
            for i in 0..<min(length, remote.count) { out[i] += remote[i] * gain }
            for i in out.indices { out[i] = limit(out[i]) }
            return out
        }
    }

    /// The loudest sample the limiter lets out: just under full scale.
    static let ceiling: Float = 0.999

    /// A soft limiter: a sample within `knee` is unchanged; above it, it bends smoothly toward full scale and stops
    /// at `ceiling`.
    static func limit(_ sample: Float) -> Float {
        let level = abs(sample)
        guard level > knee else { return sample }
        let room = 1 - knee
        let bent = min(ceiling, knee + room * Float(tanh(Double((level - knee) / room))))
        return sample < 0 ? -bent : bent
    }

    /// Zeroes `samples` wherever the person was muted. `first` is the call-clock sample index of `samples[0]`;
    /// `mutes` are seconds from the call's start; `mutedSince`, a mute still going on, silences everything from there.
    /// Idempotent: zeroing twice changes nothing.
    static func silence(_ samples: inout [Float], first: Int = 0, mutes: [CallInterval],
                        mutedSince: TimeInterval? = nil) {
        guard !samples.isEmpty else { return }
        var spans = mutes.map { (from: sampleIndex($0.start, rounding: .down), to: sampleIndex($0.end, rounding: .up)) }
        if let mutedSince { spans.append((sampleIndex(mutedSince, rounding: .down), Int.max)) }
        for span in spans {
            let from = max(span.from, first) - first
            let end = min(span.to, first + samples.count) - first
            guard end > from else { continue }
            for i in from..<end { samples[i] = 0 }
        }
    }

    /// The sample at `seconds` on the call's clock.
    static func sampleIndex(_ seconds: TimeInterval, rounding: FloatingPointRoundingRule) -> Int {
        guard seconds.isFinite else { return seconds > 0 ? Int.max : 0 }
        return max(0, Int((seconds * Recording.sampleRate).rounded(rounding)))
    }
}

extension CallInterval {
    /// `intervals` sorted, the ones that touch or overlap made one.
    static func union(_ intervals: [CallInterval]) -> [CallInterval] {
        var merged: [CallInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}

import Foundation

/// How loud a mono track sounds, as ITU-R BS.1770-4 (EBU R128) measures it: K-weighted, in 400 ms blocks that overlap
/// by 75%, gated at -70 LUFS and then at 10 LU below what's left, so silence and pauses don't pull it down. Fed a block
/// at a time, so an hour of audio is never in memory. Not thread-safe.
struct LoudnessMeter {
    let rate: Double
    private var shelf: Biquad
    private var highPass: Biquad
    /// Samples in 100 ms: a quarter of a block.
    private let step: Int
    private var sum: Double = 0
    private var filled = 0
    /// Mean square of each whole 100 ms.
    private var steps: [Double] = []

    init(rate: Double) {
        self.rate = rate
        (shelf, highPass) = Biquad.kWeighting(rate: rate)
        step = max(1, Int((rate / 10).rounded()))
    }

    mutating func add(_ samples: [Float]) {
        for sample in samples {
            let weighted = highPass.process(shelf.process(Double(sample)))
            sum += weighted * weighted
            filled += 1
            if filled == step {
                steps.append(sum / Double(step))
                sum = 0
                filled = 0
            }
        }
    }

    /// Integrated loudness in LUFS; nil when nothing is louder than the absolute gate (silence, or under 400 ms).
    var integrated: Double? {
        guard steps.count >= 4 else { return nil }
        let blocks = (0...(steps.count - 4)).map { (steps[$0] + steps[$0 + 1] + steps[$0 + 2] + steps[$0 + 3]) / 4 }
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(max(meanSquare, 1e-20)) }
        let audible = blocks.filter { loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relative = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let gated = audible.filter { loudness($0) > relative }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}

/// One second-order IIR section (direct form I), in Double.
struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }

    /// BS.1770's K-weighting at `rate`: its high shelf (+4 dB above about 1.7 kHz, the head's effect) and its high-pass
    /// (below about 38 Hz), from their analog prototypes, so any rate gets the filters the standard gives for 48 kHz.
    static func kWeighting(rate: Double) -> (shelf: Biquad, highPass: Biquad) {
        var k = tan(Double.pi * 1_681.974450955533 / rate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / rate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return (shelf, highPass)
    }
}

/// Keeps a track's peaks under `ceiling` without clipping them: each sample's gain is the least any sample in the
/// `lookahead` after it needs, eased in over that lookahead (so the gain is already down when a peak arrives, with no
/// step to click) and let back up over `release`. Its output is `lookahead - 1` samples behind its input: `finish`
/// gives the rest. Fed a block at a time; not thread-safe.
struct PeakLimiter {
    let ceiling: Float
    let lookahead: Int
    private let releaseStep: Float
    /// The last `lookahead` inputs, oldest first from `head`.
    private var delay: [Float]
    private var head = 0
    /// Indices and needed gains of a falling run: the front is the least needed gain in the window.
    private var minimums: [(index: Int, gain: Float)] = []
    private var minimumsStart = 0
    /// The window's minimums, for their moving average (its sum in Double, refreshed now and then, so hours of
    /// rounding never add up).
    private var held: [Float]
    private var heldSum: Double
    private var gain: Float = 1
    private var taken = 0

    init(ceiling: Float, rate: Double, lookahead: TimeInterval = 0.005, release: TimeInterval = 0.1) {
        self.ceiling = ceiling
        self.lookahead = max(1, Int((lookahead * rate).rounded()))
        releaseStep = Float(1 - exp(-1 / (release * rate)))
        delay = [Float](repeating: 0, count: self.lookahead)
        held = [Float](repeating: 1, count: self.lookahead)
        heldSum = Double(self.lookahead)
    }

    /// `samples` limited, `lookahead - 1` samples behind: as many come out as go in, the first ones silence.
    mutating func process(_ samples: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        for (i, sample) in samples.enumerated() {
            out[i] = step(sample)
        }
        return out
    }

    /// The last `lookahead - 1` samples, as if silence followed.
    mutating func finish() -> [Float] {
        (0..<(lookahead - 1)).map { _ in step(0) }
    }

    private mutating func step(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        let needed = magnitude > ceiling ? ceiling / magnitude : 1
        // The least gain needed among the last `lookahead` inputs.
        while minimums.count > minimumsStart, minimums[minimums.count - 1].gain >= needed { minimums.removeLast() }
        minimums.append((taken, needed))
        if minimums[minimumsStart].index <= taken - lookahead { minimumsStart += 1 }
        if minimumsStart > 4_096 {
            minimums.removeFirst(minimumsStart)
            minimumsStart = 0
        }
        let least = minimums[minimumsStart].gain
        // Its moving average over the same length eases the gain down ahead of the peak.
        let slot = taken % lookahead
        heldSum += Double(least) - Double(held[slot])
        held[slot] = least
        if taken & 0xFFFF == 0 { heldSum = held.reduce(0) { $0 + Double($1) } }
        let eased = Float(min(1, heldSum / Double(lookahead)))
        gain = eased < gain ? eased : gain + (eased - gain) * releaseStep
        // The input `lookahead - 1` samples back goes out now.
        let outgoing = lookahead == 1 ? sample : delay[(head + 1) % lookahead]
        delay[head] = sample
        head = (head + 1) % lookahead
        taken += 1
        // Rounding in the running sum must never let a peak through.
        let limited = outgoing * gain
        return max(-ceiling, min(ceiling, limited))
    }
}

import CSpeexDSP
import Foundation

/// Takes the other side's voices out of a call's mic. On laptop speakers the mic hears the call as it plays, and that
/// echo confuses who said what. The call's own track (`remote`, the call app's sound as it played) is the far end:
/// SpeexDSP's echo canceller (MDF) learns how it reaches the mic and subtracts it, then its preprocessor suppresses
/// what's left of the echo and steady noise. No AGC: the mic keeps its level.
///
/// Offline, a block at a time, both tracks on the call's clock (sample `n` of each is the same moment): `process`
/// hands back as many cleaned samples as it can (less than a frame behind), `finish` the rest, so the output is as
/// long as the input. A frame of digital silence (a mute) stays silent and teaches the filter nothing: the echo path
/// it learned before the mute still holds after. Not thread-safe; one per track, used from one thread.
final class EchoCanceller {
    struct Settings: Equatable, Sendable {
        /// Samples per frame: 10 ms.
        var frame = 160
        /// How long an echo the filter covers, in samples: 0.4 s, for the speaker-to-mic delay plus the room.
        var filterLength = 6_400
        /// How far the preprocessor pushes down what echo is left, in dB: when only the other side talks, and when the
        /// person talks over them.
        var echoSuppress: Int32 = -40
        var echoSuppressActive: Int32 = -15
        /// Steady noise (fans, hum): taken down this far, in dB; nil leaves it.
        var noiseSuppress: Int32? = -15
        /// Runs the preprocessor at all: off leaves just the linear echo canceller.
        var preprocess = true
        /// A frame the echo canceller made louder than it was goes on as recorded instead.
        var neverLouder = true

        static let standard = Settings()
    }

    let settings: Settings
    private let echo: OpaquePointer
    private let preprocessor: OpaquePointer?
    /// Taken in, not yet a whole frame.
    private var pendingMic: [Int16] = []
    private var pendingFar: [Int16] = []
    private var frameOut: [Int16]

    init(settings: Settings = .standard) {
        self.settings = settings
        let frame = Int32(settings.frame)
        echo = speex_echo_state_init(frame, Int32(settings.filterLength))
        var rate = Int32(Recording.sampleRate)
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        frameOut = [Int16](repeating: 0, count: settings.frame)
        guard settings.preprocess else {
            preprocessor = nil
            return
        }
        let state = speex_preprocess_state_init(frame, rate)
        preprocessor = state
        func set(_ request: Int32, _ value: Int32) {
            var value = value
            speex_preprocess_ctl(state, request, &value)
        }
        set(SPEEX_PREPROCESS_SET_DENOISE, settings.noiseSuppress == nil ? 0 : 1)
        if let noise = settings.noiseSuppress { set(SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, noise) }
        // VAD and dereverb are off by default (setting the VAD prints a warning).
        set(SPEEX_PREPROCESS_SET_AGC, 0)
        set(SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, settings.echoSuppress)
        set(SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, settings.echoSuppressActive)
        speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
    }

    deinit {
        if let preprocessor { speex_preprocess_state_destroy(preprocessor) }
        speex_echo_state_destroy(echo)
    }

    /// `mic` cleaned of `reference` (the far end at the same samples; silence where it's shorter). Returns the whole
    /// frames done so far: up to a frame fewer than went in, which the next call or `finish` gives.
    func process(mic: [Float], reference: [Float]) -> [Float] {
        pendingMic.append(contentsOf: mic.lazy.map(Self.int16))
        pendingFar.append(contentsOf: reference.prefix(mic.count).lazy.map(Self.int16))
        if reference.count < mic.count {
            pendingFar.append(contentsOf: repeatElement(0, count: mic.count - reference.count))
        }
        return drain()
    }

    /// The last partial frame, cleaned as if silence followed.
    func finish() -> [Float] {
        let left = pendingMic.count
        guard left > 0 else { return [] }
        let pad = settings.frame - left
        pendingMic.append(contentsOf: repeatElement(0, count: pad))
        pendingFar.append(contentsOf: repeatElement(0, count: pad))
        return Array(drain().prefix(left))
    }

    private func drain() -> [Float] {
        let frame = settings.frame
        let frames = pendingMic.count / frame
        guard frames > 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(frames * frame)
        pendingMic.withUnsafeBufferPointer { mic in
            pendingFar.withUnsafeBufferPointer { far in
                frameOut.withUnsafeMutableBufferPointer { cleaned in
                    for index in 0..<frames {
                        let start = index * frame
                        let near = UnsafeBufferPointer(rebasing: mic[start..<start + frame])
                        if !near.contains(where: { $0 != 0 }) {
                            out.append(contentsOf: repeatElement(0, count: frame))
                            continue
                        }
                        speex_echo_cancellation(echo, near.baseAddress, far.baseAddress! + start, cleaned.baseAddress)
                        // Right after the echo path changes (the volume turned down), the filter subtracts an echo
                        // that's no longer there and the frame comes out louder than it went in: then it goes on as
                        // recorded, while the filter catches up.
                        if settings.neverLouder, Self.energy(cleaned) > Self.energy(near) {
                            _ = cleaned.initialize(from: near)
                        }
                        if let preprocessor { speex_preprocess_run(preprocessor, cleaned.baseAddress) }
                        out.append(contentsOf: cleaned.lazy.map { Float($0) / 32_768 })
                    }
                }
            }
        }
        pendingMic.removeFirst(frames * frame)
        pendingFar.removeFirst(frames * frame)
        return out
    }

    private static func energy<C: Collection>(_ samples: C) -> Int64 where C.Element == Int16 {
        samples.reduce(Int64(0)) { $0 + Int64($1) * Int64($1) }
    }

    private static func int16(_ sample: Float) -> Int16 {
        Int16(clamping: Int((sample * 32_768).rounded()))
    }
}

/// How much of the other side a mic track has in it, before and after `EchoCanceller`: fed the mic as recorded, the
/// other side and the cleaned mic a block at a time, each from sample 0, it keeps each track's level per 50 ms frame
/// (and per 10 ms for the envelopes), never the audio. Which frames count as the other side alone, or the person
/// alone, is decided on the mic as recorded, so before and after are measured on the same frames.
struct EchoMeter: Sendable {
    /// 50 ms frames for levels, 10 ms for the envelopes the correlation compares.
    static let frame = 800
    static let envelopeFrame = 160
    /// A frame at or above this is voiced.
    static let voicedDBFS: Float = -45
    /// The lags the envelopes are compared at, in 10 ms steps: 0 to 400 ms, the mic behind the other side.
    static let lags = 0...40

    private var raw = Levels(), cleaned = Levels(), remote = Levels()

    mutating func add(raw samples: [Float], remote reference: [Float]) {
        raw.add(samples)
        var reference = Array(reference.prefix(samples.count))
        if reference.count < samples.count {
            reference += [Float](repeating: 0, count: samples.count - reference.count)
        }
        remote.add(reference)
    }

    mutating func add(cleaned samples: [Float]) {
        cleaned.add(samples)
    }

    /// The figures, once every block is in.
    func result() -> EchoStats {
        var raw = raw, cleaned = cleaned, remote = remote
        raw.close()
        cleaned.close()
        remote.close()
        let count = min(raw.frames.count, cleaned.frames.count, remote.frames.count)
        let rawDB = raw.frames.prefix(count).map(Self.dB)
        let remoteDB = remote.frames.prefix(count).map(Self.dB)
        let remoteVoiced = remoteDB.map { $0 >= Self.voicedDBFS }
        // How loud the other side is in the mic when it's just them: the typical mic-to-remote level difference
        // where they talk, within a minute around (the speaker volume changes during a call). A frame much louder
        // than that has the person (or the room) in it too.
        let talking = (0..<count).filter { remoteVoiced[$0] && rawDB[$0] > -100 }
        func median(_ indices: ArraySlice<Int>) -> Float? {
            let sorted = indices.map { rawDB[$0] - remoteDB[$0] }.sorted()
            return sorted.isEmpty ? nil : sorted[sorted.count / 2]
        }
        let overall = median(talking[...])
        /// Where frames from `frame` on start in `talking` (sorted).
        func position(_ frame: Int) -> Int {
            var low = 0, high = talking.count
            while low < high {
                let middle = (low + high) / 2
                if talking[middle] < frame { low = middle + 1 } else { high = middle }
            }
            return low
        }
        let chunk = 100, reach = 600
        var couplings: [Float?] = []
        for start in stride(from: 0, to: count, by: chunk) {
            let low = position(start - reach), high = position(start + chunk + reach)
            couplings.append(high - low >= 20 ? median(talking[low..<high]) : overall)
        }
        let remoteOnly = talking.filter { index in
            guard let coupling = couplings[index / chunk] else { return false }
            return rawDB[index] - remoteDB[index] <= coupling + 8
        }
        // The person alone: they're voiced and the other side has been quiet for 300 ms, so no echo tail is left.
        let nearOnly = (0..<count).filter { index in
            rawDB[index] >= Self.voicedDBFS
                && (max(0, index - 6)...index).allSatisfy { remoteDB[$0] < -55 }
        }
        func side(_ levels: Levels) -> EchoStats.Side {
            let frames = Array(levels.frames.prefix(count))
            let voiced = frames.indices.filter { Self.dB(frames[$0]) >= Self.voicedDBFS }
            let overlapping = voiced.filter { remoteVoiced[$0] }.count
            func level(_ indices: [Int]) -> Double? {
                guard !indices.isEmpty else { return nil }
                return Double(Self.dB(indices.reduce(Float(0)) { $0 + frames[$1] } / Float(indices.count)))
            }
            return EchoStats.Side(
                voicedFraction: count == 0 ? 0 : Double(voiced.count) / Double(count),
                overlapFraction: voiced.isEmpty ? 0 : Double(overlapping) / Double(voiced.count),
                correlation: Self.lags.map { Self.correlation(levels.envelope, remote.envelope, lag: $0,
                                                              skipping: raw.envelope) },
                echoDBFS: level(remoteOnly), nearDBFS: level(nearOnly))
        }
        let drops = remoteOnly.map { rawDB[$0] - max(Self.dB(cleaned.frames[$0]), -100) }.sorted()
        return EchoStats(before: side(raw), after: side(cleaned), frames: count, remoteOnlyFrames: remoteOnly.count,
                         nearOnlyFrames: nearOnly.count,
                         typicalEchoReductionDB: drops.isEmpty ? nil : Double(drops[drops.count / 2]))
    }

    /// Pearson's correlation of the mic's envelope with the other side's `lag` frames earlier, over the frames where
    /// the recorded mic isn't digital silence (a mute would correlate with nothing).
    private static func correlation(_ mic: [Float], _ remote: [Float], lag: Int, skipping raw: [Float]) -> Double {
        let count = min(mic.count, remote.count + lag, raw.count)
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for index in lag..<max(lag, count) where raw[index] > 0 {
            let x = Double(mic[index].squareRoot()), y = Double(remote[index - lag].squareRoot())
            n += 1
            sx += x
            sy += y
            sxx += x * x
            syy += y * y
            sxy += x * y
        }
        guard n > 1 else { return 0 }
        let covariance = sxy - sx * sy / n
        let spread = ((sxx - sx * sx / n) * (syy - sy * sy / n)).squareRoot()
        return spread > 0 ? covariance / spread : 0
    }

    /// A frame's mean square in dBFS; -160 for digital silence.
    static func dB(_ meanSquare: Float) -> Float {
        meanSquare > 1e-16 ? max(10 * log10(meanSquare), -160) : -160
    }

    /// A track's mean square per 50 ms and per 10 ms frame.
    private struct Levels: Sendable {
        var frames: [Float] = []
        var envelope: [Float] = []
        private var sum: Float = 0, filled = 0
        private var envelopeSum: Float = 0, envelopeFilled = 0

        mutating func add(_ samples: [Float]) {
            for sample in samples {
                let square = sample * sample
                sum += square
                envelopeSum += square
                filled += 1
                envelopeFilled += 1
                if envelopeFilled == EchoMeter.envelopeFrame {
                    envelope.append(envelopeSum / Float(envelopeFilled))
                    envelopeSum = 0
                    envelopeFilled = 0
                }
                if filled == EchoMeter.frame {
                    frames.append(sum / Float(filled))
                    sum = 0
                    filled = 0
                }
            }
        }

        /// A last partial frame counts only when it's at least half a frame.
        mutating func close() {
            if filled >= EchoMeter.frame / 2 { frames.append(sum / Float(filled)) }
            if envelopeFilled >= EchoMeter.envelopeFrame / 2 { envelope.append(envelopeSum / Float(envelopeFilled)) }
            sum = 0
            filled = 0
            envelopeSum = 0
            envelopeFilled = 0
        }
    }
}

/// What `EchoMeter` found: the mic as recorded (`before`) and cleaned (`after`), on the same 50 ms frames.
struct EchoStats: Equatable, Sendable {
    struct Side: Equatable, Sendable {
        /// Frames at or above -45 dBFS, of all.
        var voicedFraction: Double
        /// Of the voiced frames, those where the other side is voiced too.
        var overlapFraction: Double
        /// The envelope's correlation with the other side's, at each of `EchoMeter.lags` (10 ms steps).
        var correlation: [Double]
        /// The mic's level where only the other side talks (the echo), and where only the person does; nil when
        /// there's no such frame.
        var echoDBFS: Double?
        var nearDBFS: Double?

        /// The highest correlation and its lag in ms.
        var strongestCorrelation: (value: Double, lagMS: Int) {
            let best = correlation.indices.max { correlation[$0] < correlation[$1] } ?? 0
            return (correlation.isEmpty ? 0 : correlation[best], best * 10)
        }
    }

    var before: Side
    var after: Side
    var frames: Int
    var remoteOnlyFrames: Int
    var nearOnlyFrames: Int
    /// The median frame's drop where only the other side talks, in dB: how much quieter the echo usually got, where
    /// `echoReductionDB` weighs the loud frames most.
    var typicalEchoReductionDB: Double?

    /// How much quieter the echo got, in dB: the level where only the other side talks, before less after.
    var echoReductionDB: Double? {
        guard let before = before.echoDBFS, let after = after.echoDBFS else { return nil }
        return before - after
    }
}

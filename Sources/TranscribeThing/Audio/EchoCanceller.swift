import CSpeexDSP
import Foundation

/// Takes the other side's voices out of a call's mic, and the background noise out of all of it. On laptop speakers
/// the mic hears the call as it plays, and that echo confuses who said what. The call's own track (`remote`, the call
/// app's sound as it played) is the far end: SpeexDSP's echo canceller (MDF) learns how it reaches the mic and
/// subtracts it, then its preprocessor suppresses what's left of the echo and the noise. No AGC: the mic keeps its
/// level.
///
/// The canceller's output only helps where there's echo: on headphones, or with the speakers turned down, it has
/// nothing to take out, and what it subtracts anyway is a bit of the person. So the mic goes two ways at once, each
/// through its own preprocessor: as recorded, and through the canceller. Each `Settings.hop` of the call is judged:
/// the canceller's version is used where it took a real share of the mic away while the other side talked
/// (`Settings.minimumERLE`), and a stretch each side of that (`Settings.reach`); the recorded one's elsewhere.
/// Between the two the mic crossfades over 100 ms: nothing switches at a frame's edge, where a hard switch clicks. The
/// canceller keeps learning the whole time, so it's ready the moment echo starts. The preprocessors are a frame
/// behind; the output is put back on the call's clock.
///
/// Offline, a block at a time, both tracks on the call's clock (sample `n` of each is the same moment): `process`
/// hands back what it can (it holds back up to `reach + 1` hops to see what comes), `finish` the rest, so the output
/// is as long as the input and on the same clock. A frame of digital silence (a mute) stays silent and teaches the
/// filter nothing: the echo path it learned before the mute still holds after. Not thread-safe; one per track, used
/// from one thread.
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
        /// Runs the preprocessor at all: off leaves just the linear echo canceller (and no noise suppression).
        var preprocess = true
        /// Uses the echo canceller only where there's echo (see the type); off uses it everywhere.
        var gate = true
        /// The recorded mic's preprocessor also takes down what the canceller's model puts down to the speakers. With
        /// no echo to learn, the model fits whatever the mic hears while the other side's track has any sound, so this
        /// works as a strong noise gate: the background goes down about 15 dB more than with steady noise alone, the
        /// person's voice about 1.5 dB. Off leaves that version just the steady noise taken out.
        var plainSuppressesEcho = true
        /// The stretch judged at a time, in seconds. Echo there is in a stretch when, in its frames where the other side
        /// talks (`minimumFrames` of them at least: 0.5 s), the canceller took `minimumERLE` dB of the mic away.
        var hop: Double = 5
        var minimumERLE: Double = 3
        var minimumFrames = 50
        /// The canceller's version is used in a stretch with echo and in `reach` stretches each side of it.
        var reach = 1

        static let standard = Settings()
    }

    /// What it did, once `finish` is through.
    struct Summary: Equatable, Sendable {
        /// The stretches judged, and those with echo, whose mic is the echo canceller's.
        var hops = 0
        var echoHops = 0
        /// Each hop's echo return loss enhancement, in dB; nil where the other side barely talked.
        var erle: [Double?] = []

        var echoShare: Double { hops == 0 ? 0 : Double(echoHops) / Double(hops) }
    }

    let settings: Settings
    private(set) var summary = Summary()
    private let echo: OpaquePointer
    /// The preprocessors of the mic as recorded and of the canceller's output.
    private let plain: OpaquePointer?
    private let cleaning: OpaquePointer?
    private let hopFrames: Int
    /// Taken in, not yet a whole frame.
    private var pendingMic: [Int16] = []
    private var pendingFar: [Int16] = []
    private var taken = 0, given = 0
    /// Frames in, frames handed back.
    private var arrived = 0, emitted = 0
    /// The last frame in was digital silence.
    private var lastZero = true
    /// Per frame from `emitted`: whether it was digital silence.
    private var zeros: [Bool] = []
    /// The two versions of frames `emitted...`, as far as the preprocessors have given them (a frame behind).
    private var plainOut: [Int16] = []
    private var cleanOut: [Int16] = []
    /// Per hop, over its frames where the other side talks: the mic's energy before and after the canceller.
    private var hopEnergy: [(mic: Double, cleaned: Double, frames: Int)] = []
    private var decisions: [Bool] = []
    /// How much of the canceller's version is in the mix, 0...1, at the end of the last frame handed back.
    private var weight: Double = 0
    private var micFrame: [Int16], farFrame: [Int16], cleaned: [Int16], scratch: [Int16]
    private var notch = DCNotch()

    /// The other side counts as talking in a frame at or above -50 dBFS.
    private static let farVoiced: Double = Foundation.pow(32_768 * Foundation.pow(10.0, -50.0 / 20), 2)

    init(settings: Settings = .standard) {
        self.settings = settings
        let frame = Int32(settings.frame)
        echo = speex_echo_state_init(frame, Int32(settings.filterLength))
        var rate = Int32(Recording.sampleRate)
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        hopFrames = max(1, Int(settings.hop * Recording.sampleRate) / settings.frame)
        micFrame = [Int16](repeating: 0, count: settings.frame)
        farFrame = micFrame
        cleaned = micFrame
        scratch = micFrame
        guard settings.preprocess else {
            plain = nil
            cleaning = nil
            return
        }
        func make(echo state: OpaquePointer?) -> OpaquePointer? {
            guard let preprocessor = speex_preprocess_state_init(frame, rate) else { return nil }
            func set(_ request: Int32, _ value: Int32) {
                var value = value
                speex_preprocess_ctl(preprocessor, request, &value)
            }
            set(SPEEX_PREPROCESS_SET_DENOISE, settings.noiseSuppress == nil ? 0 : 1)
            if let noise = settings.noiseSuppress { set(SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, noise) }
            // VAD and dereverb are off by default (setting the VAD prints a warning).
            set(SPEEX_PREPROCESS_SET_AGC, 0)
            if let state {
                set(SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, settings.echoSuppress)
                set(SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, settings.echoSuppressActive)
                speex_preprocess_ctl(preprocessor, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(state))
            }
            return preprocessor
        }
        plain = make(echo: settings.plainSuppressesEcho ? echo : nil)
        cleaning = make(echo: echo)
    }

    deinit {
        if let plain { speex_preprocess_state_destroy(plain) }
        if let cleaning { speex_preprocess_state_destroy(cleaning) }
        speex_echo_state_destroy(echo)
    }

    /// `mic` cleaned of `reference` (the far end at the same samples; silence where it's shorter). Returns what's
    /// done so far, from where the last call stopped: up to `reach + 1` hops fewer than went in, which later calls or
    /// `finish` give.
    func process(mic: [Float], reference: [Float]) -> [Float] {
        taken += mic.count
        pendingMic.append(contentsOf: mic.lazy.map(Self.int16))
        pendingFar.append(contentsOf: reference.prefix(mic.count).lazy.map(Self.int16))
        if reference.count < mic.count {
            pendingFar.append(contentsOf: repeatElement(0, count: mic.count - reference.count))
        }
        let frame = settings.frame
        let frames = pendingMic.count / frame
        for index in 0..<frames {
            take(start: index * frame)
        }
        pendingMic.removeFirst(frames * frame)
        pendingFar.removeFirst(frames * frame)
        return emit(final: false)
    }

    /// The rest, the last partial frame cleaned as if silence followed.
    func finish() -> [Float] {
        let left = pendingMic.count
        if left > 0 {
            let pad = settings.frame - left
            pendingMic.append(contentsOf: repeatElement(0, count: pad))
            pendingFar.append(contentsOf: repeatElement(0, count: pad))
            take(start: 0)
            pendingMic.removeAll()
            pendingFar.removeAll()
        }
        // The preprocessors are a frame behind: a frame of silence brings out the last one.
        if settings.preprocess, arrived > 0 {
            if lastZero {
                produce(arrived - 1, plain: nil, clean: nil)
            } else {
                runPreprocessors(mic: nil)
            }
        }
        let out = emit(final: true)
        summary.hops = decisions.count
        summary.echoHops = settings.gate ? decisions.filter { $0 }.count : decisions.count
        summary.erle = hopEnergy.indices.map(erle)
        return out
    }

    /// One frame from `pendingMic`/`pendingFar` at `start`: through the canceller, into the hop's figures, and
    /// through both preprocessors.
    private func take(start: Int) {
        let frame = settings.frame
        for i in 0..<frame {
            micFrame[i] = pendingMic[start + i]
            farFrame[i] = pendingFar[start + i]
        }
        let zero = !micFrame.contains { $0 != 0 }
        let hop = arrived / hopFrames
        while hopEnergy.count <= hop { hopEnergy.append((0, 0, 0)) }
        if !zero {
            micFrame.withUnsafeBufferPointer { mic in
                farFrame.withUnsafeBufferPointer { far in
                    cleaned.withUnsafeMutableBufferPointer { out in
                        speex_echo_cancellation(echo, mic.baseAddress, far.baseAddress, out.baseAddress)
                    }
                }
            }
            // The canceller takes the mic's DC and rumble out (below about 50 Hz) whatever the echo: measured against
            // the mic without them too, so a rumbling room doesn't pass for echo.
            let before = notch.energy(micFrame), after = Self.energy(cleaned)
            if Self.energy(farFrame) / Double(frame) >= Self.farVoiced {
                hopEnergy[hop].mic += before
                hopEnergy[hop].cleaned += after
                hopEnergy[hop].frames += 1
            }
        }
        zeros.append(zero)
        arrived += 1
        if !settings.preprocess {
            produce(arrived - 1, plain: micFrame, clean: cleaned)
        } else if zero {
            // A mute: the frame before it comes out of the preprocessors with silence after it; the rest of the mute
            // doesn't go through them, so their noise estimate isn't pulled down to nothing.
            if lastZero {
                produce(arrived - 2, plain: nil, clean: nil)
            } else {
                runPreprocessors(mic: nil)
            }
        } else {
            runPreprocessors(mic: micFrame)
        }
        lastZero = zero
    }

    /// Both preprocessors on the frame just taken (`mic`, and `cleaned` the canceller's), or on silence for nil.
    /// What comes out is the frame before (`arrived - 2`), or for nil after the last frame, the last one.
    private func runPreprocessors(mic: [Int16]?) {
        if let mic {
            scratch = mic
        } else {
            for i in 0..<settings.frame {
                scratch[i] = 0
                cleaned[i] = 0
            }
        }
        _ = scratch.withUnsafeMutableBufferPointer { speex_preprocess_run(plain, $0.baseAddress) }
        _ = cleaned.withUnsafeMutableBufferPointer { speex_preprocess_run(cleaning, $0.baseAddress) }
        produce(mic == nil && arrived == producedFrames + 1 ? arrived - 1 : arrived - 2, plain: scratch, clean: cleaned)
    }

    /// Frames `0..<producedFrames` are in `plainOut`/`cleanOut` (from `emitted` on).
    private var producedFrames = 0

    /// Frame `index`'s two versions, or silence for nil and for a frame that was digital silence. A frame from before
    /// the call (the preprocessors' first output) is dropped.
    private func produce(_ index: Int, plain: [Int16]?, clean: [Int16]?) {
        guard index >= 0 else { return }
        if let plain, let clean, !zeros[index - emitted] {
            plainOut += plain
            cleanOut += clean
        } else {
            plainOut += repeatElement(0, count: settings.frame)
            cleanOut += repeatElement(0, count: settings.frame)
        }
        producedFrames = index + 1
    }

    /// The canceller's take on hop `hop`: how much quieter it made the mic where the other side talked, in dB; nil
    /// when they barely did.
    private func erle(_ hop: Int) -> Double? {
        erle(hop..<hop + 1)
    }

    /// The same over `hops` together.
    private func erle(_ hops: Range<Int>) -> Double? {
        let window = hopEnergy[hops]
        guard window.reduce(0, { $0 + $1.frames }) >= settings.minimumFrames else { return nil }
        let mic = window.reduce(0) { $0 + $1.mic }, cleaned = window.reduce(0) { $0 + $1.cleaned }
        return 10 * log10(max(mic, 1) / max(cleaned, 1))
    }

    /// Whether hop `hop` gets the canceller's version: it, or one within `reach` of it, has echo, or they have
    /// together (a hop where the other side said little, or the person talked over them, is judged with its
    /// neighbours).
    private func hasEcho(near hop: Int) -> Bool {
        let window = hopEnergy.indices.clamped(to: hop - settings.reach..<hop + settings.reach + 1)
        let echo = { (erle: Double?) in erle.map { $0 >= self.settings.minimumERLE } ?? false }
        return window.contains { echo(erle($0)) } || echo(erle(window))
    }

    /// Hands back the frames whose hop can be judged (all of them when `final`), mixed.
    private func emit(final: Bool) -> [Float] {
        let frame = settings.frame
        var out = [Float]()
        out.reserveCapacity(max(0, producedFrames - emitted) * frame)
        var done = 0
        while emitted + done < producedFrames {
            let index = emitted + done
            let hop = index / hopFrames
            if !final && arrived < (hop + settings.reach + 1) * hopFrames { break }
            while decisions.count <= hop {
                decisions.append(hasEcho(near: decisions.count))
            }
            // 100 ms from one version to the other, on a raised cosine.
            let start = weight
            let target: Double = !settings.gate || decisions[hop] ? 1 : 0
            weight = target > weight ? min(target, weight + 0.1) : max(target, weight - 0.1)
            let base = done * frame
            for i in 0..<frame {
                let a = Float(plainOut[base + i]), b = Float(cleanOut[base + i])
                let sample: Float
                if start == 0 && weight == 0 {
                    sample = a
                } else if start == 1 && weight == 1 {
                    sample = b
                } else {
                    let w = start + (weight - start) * Double(i + 1) / Double(frame)
                    let s = Float(0.5 - 0.5 * cos(Double.pi * w))
                    sample = (s * b + (1 - s) * a).rounded()
                }
                out.append(sample / 32_768)
            }
            done += 1
        }
        emitted += done
        zeros.removeFirst(done)
        plainOut.removeFirst(done * frame)
        cleanOut.removeFirst(done * frame)
        // Never more than went in: the padding of the last frame stays out.
        let room = taken - given
        if out.count > room { out.removeLast(out.count - room) }
        given += out.count
        return out
    }

    /// The DC notch SpeexDSP's canceller puts the mic through first (`filter_dc_notch16` in mdf.c, at 16 kHz).
    struct DCNotch {
        private var memory: (Double, Double) = (0, 0)
        private let radius = 0.982

        /// The energy of `samples` through the notch, which goes on from the last call.
        mutating func energy(_ samples: [Int16]) -> Double {
            let den2 = radius * radius + 0.7 * (1 - radius) * (1 - radius)
            var sum = 0.0
            for sample in samples {
                let input = Double(sample)
                let output = memory.0 + input
                memory.0 = memory.1 + 2 * (-input + radius * output)
                memory.1 = input - den2 * output
                sum += (radius * output) * (radius * output)
            }
            return sum
        }

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

    private static func energy(_ samples: [Int16]) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
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

import Accelerate
import CSpeexDSP
import Foundation

/// Takes what the Mac itself plays (music, a video) out of a dictation's mic as it's captured, so the pill's waveform,
/// the speech check and the transcript hear the person rather than the song. Music on the speakers never dips, so both
/// the voice gate (`LevelMeter`) and the speech check (`SpeechAnalyzer`) take it for the room's floor, and a voice that
/// isn't 9-10 dB louder than it counts as nothing.
///
/// The reference is the Mac's output as a process tap hears it (`DictationEcho`), 16 kHz, stamped with `AudioClock`
/// times like the mic. Each 10 ms mic frame is paired with the reference of the same moment (the speakers' delay and
/// the room, up to `filterLength`, are the filter's to learn) and goes through three stages:
///
/// 1. SpeexDSP's echo canceller (MDF), as calls use it (`EchoCanceller`): takes out the echo it has learned, about
///    15-20 dB of a song.
/// 2. SpeexDSP's preprocessor: steady noise and some of what's left of the echo.
/// 3. `EchoGate`: what the canceller misses most is a sound it hasn't heard yet (a new chord, a drum), which then rings
///    out at nearly full level for a moment, and a speech check takes it for a voice. So in each frequency band, a
///    frame is let through only where it's louder than `echoShare` of the echo the Mac's sound makes there; elsewhere
///    it goes down to `residualFloorDB`. A voice about as loud as the music is louder than that in most bands and
///    goes through.
///
/// Until the first reference arrives (no tap yet, or never), the mic goes through untouched and at once. After, the
/// output is two frames behind (the preprocessor's and the gate's), but always the same length and on the same clock
/// as the mic. Like calls, the cancelled version is used only where there's echo: while the reference plays, the last
/// second must have lost `engageERLE` dB to the linear canceller; it's left when the last five seconds lost less than
/// `releaseERLE`. On headphones, or with the speakers muted, there's nothing to cancel and the mic is exactly as
/// recorded. Between the two the mic crossfades over 100 ms.
///
/// Not thread-safe: one per capture, used under the capture's lock on the mic's delivery queue.
final class LiveEchoCanceller {
    struct Settings: Equatable, Sendable {
        /// Samples per frame: 10 ms.
        var frame = 160
        /// How long an echo the filter covers, in samples: 0.4 s, the speakers' delay plus the room.
        var filterLength = 6_400
        /// How far the preprocessor pushes down what echo is left, in dB, when only the Mac plays and when the person
        /// talks over it.
        var echoSuppress: Int32 = -40
        var echoSuppressActive: Int32 = -15
        /// Steady noise taken down this far, in dB, in the cancelled version; nil leaves it.
        var noiseSuppress: Int32? = -15
        /// Uses the cancelled version only where there's echo; off: always, once a reference arrived.
        var gate = true
        /// The cancelled version is taken when, of the last `engageFrames` frames, those where the Mac played
        /// (`engageMinimumFrames` of them at least) were `engageShare` of them frames where the linear canceller took
        /// at least half the mic away: the echo was most of the mic there. A voice over the music doesn't hide it, as
        /// there are pauses between words; on headphones there's never such a frame ...
        var engageShare: Double = 0.25
        var engageFrames = 100
        var engageMinimumFrames = 50
        /// ... and left when, of the last `releaseFrames` (with `releaseMinimumFrames` where it played), fewer than
        /// `releaseShare` were.
        var releaseShare: Double = 0.05
        var releaseFrames = 500
        var releaseMinimumFrames = 250
        /// How long a mic frame waits for the reference of its moment, in seconds.
        var maxWait: TimeInterval = 0.1
        /// The echo gate (stage 3): off leaves the canceller and the preprocessor.
        var suppressResidual = true
        /// A band goes through where it holds more than this share (power) of the echo the Mac's sound makes there:
        /// what it holds beyond that.
        var echoShare: Float = 3
        /// How far a band that doesn't is pushed down, in dB.
        var residualFloorDB: Float = -30
        /// How fast a band closes again after it let something through (per 10 ms, as a power ratio), so a voice's
        /// tail isn't cut off at once.
        var residualRelease: Float = 0.25

        static let standard = Settings()
    }

    /// What it did, for the diagnostics log: no audio.
    struct Report: Equatable, Sendable {
        /// A reference arrived: the tap was up for at least part of the dictation.
        var hadReference = false
        /// Frames through the canceller, and those handed back mostly as the cancelled version.
        var processedFrames = 0
        var cancelledFrames = 0
        /// Where the Mac's sound was most of the mic and the cancelled version was used: how much quieter the mic
        /// got, in dB.
        var echoReductionDB: Double?
        /// The samples (from the first one in) where the output turns from the mic as recorded to the cancelled
        /// version, or back: the speech check measures each part against its own floor (`SpeechAnalyzer`).
        var switches: [Int] = []

        var cancelledSeconds: Double { Double(cancelledFrames) * 0.01 }
    }

    let settings: Settings
    /// `AudioClock` time of reference sample 0.
    let origin: TimeInterval
    private let pull: () -> [TimedAudio]

    // Reference, by sample index from `origin`: `reference[0]` is index `referenceBase`, up to `referenceEnd`.
    private var reference: [Float] = []
    private var referenceBase = 0
    private var referenceEnd = 0
    private var hasReference = false

    // Mic samples waiting for their reference, each with its reference index.
    private var pendingMic: [Float] = []
    private var pendingIndex: [Int] = []

    // Speex and the gate, made when the first reference arrives.
    private var echo: OpaquePointer?
    private var cleaning: OpaquePointer?
    private var echoGate: EchoGate?
    private var notch = EchoCanceller.DCNotch()
    private var micFrame: [Int16], farFrame: [Int16], linear: [Int16]
    private var notched: [Double]

    /// A frame on its way through the stages, oldest first: the frame the gate hands back next is the first.
    private struct Frame {
        var raw: [Float]
        var zero: Bool
        var micEnergy: Double
        /// The Mac's sound was most of the mic (the canceller took at least half of it away).
        var echoOnly: Bool
        /// The mic and the reference, in 16-bit units, for the gate.
        var mic: [Float]
        var far: [Float]
    }

    private var frames: [Frame] = []
    /// The gate has had a frame: what it hands back from now on is a frame that went in.
    private var gatePrimed = false

    /// The reference's energy per frame, smoothed over a few frames (the speakers' delay).
    private var farSmooth = 0.0
    /// How loud the echo is in the mic for the reference (power ratio): the mic over the reference in the last two
    /// seconds' frames where the Mac played, at the 30th percentile, as a voice only ever adds to it and pauses
    /// between words leave the echo alone. 0 until there are 20 such frames. The gate starts from it in a band it
    /// hasn't learned yet.
    private var couplings: [Double] = []
    private var coupling = 0.0
    /// Per frame, newest last, up to `releaseFrames`: whether the Mac played, and whether its echo was most of the mic.
    private var recent: [(farActive: Bool, echoOnly: Bool)] = []
    private var engaged = false
    /// How much of the cancelled version is in the mix, 0...1, at the end of the last frame handed back.
    private var weight: Double = 0
    private(set) var report = Report()
    /// Samples handed back so far.
    private var emitted = 0
    /// The version the output is on, or crossfading to: the cancelled one when true.
    private var heading = false
    private var reducedMic = 0.0, reducedOut = 0.0

    /// The Mac counts as playing in a frame at or above -50 dBFS.
    private static let farVoiced: Double = Foundation.pow(32_768 * Foundation.pow(10.0, -50.0 / 20), 2)

    /// `reference` hands over the reference audio that arrived since it was last asked, oldest first.
    init(settings: Settings = .standard, origin: TimeInterval, reference: @escaping () -> [TimedAudio]) {
        self.settings = settings
        self.origin = origin
        self.pull = reference
        micFrame = [Int16](repeating: 0, count: settings.frame)
        farFrame = micFrame
        linear = micFrame
        notched = [Double](repeating: 0, count: settings.frame)
    }

    deinit {
        if let cleaning { speex_preprocess_state_destroy(cleaning) }
        if let echo { speex_echo_state_destroy(echo) }
    }

    /// `mic`, whose first sample was captured at `time` (`AudioClock`), cleaned as far as its reference allows: the
    /// output so far, from where the last call stopped. Everything comes out in order, as long as it went in.
    func process(_ mic: [Float], at time: TimeInterval) -> [Float] {
        takeReference()
        guard hasReference else {
            emitted += mic.count
            return mic
        }
        let first = index(of: time)
        pendingMic.append(contentsOf: mic)
        pendingIndex.append(contentsOf: first..<first + mic.count)
        return run(final: false)
    }

    /// The rest, without waiting for any more reference.
    func flush() -> [Float] {
        takeReference()
        var out = run(final: true)
        if let last = frames.last {
            // The preprocessor and the gate are a frame behind each: frames of silence bring out what they hold.
            for i in 0..<settings.frame { linear[i] = 0 }
            _ = linear.withUnsafeMutableBufferPointer { speex_preprocess_run(cleaning, $0.baseAddress) }
            out += gate(cleaned: linear.map(Float.init), of: last)
            let silence = [Float](repeating: 0, count: settings.frame)
            out += gate(cleaned: silence, of: Frame(raw: [], zero: true, micEnergy: 0, echoOnly: false,
                                                    mic: silence, far: silence))
        }
        finishReport()
        return out
    }

    // MARK: Reference

    private func index(of time: TimeInterval) -> Int {
        Int(((time - origin) * Recording.sampleRate).rounded())
    }

    /// Puts what arrived in place: a stretch that starts later than the reference reached is preceded by silence,
    /// one that starts earlier loses what overlaps; within `TrackAligner.tolerance` it just follows on, so the
    /// tap's jitter doesn't move the echo the filter learned.
    private func takeReference() {
        for stretch in pull() {
            var samples = stretch.samples[...]
            if let start = stretch.start {
                let target = index(of: start)
                let slack = Int(TrackAligner.tolerance * Recording.sampleRate)
                if !hasReference {
                    hasReference = true
                    report.hadReference = true
                    referenceBase = target
                    referenceEnd = target
                } else if target - referenceEnd > slack {
                    let gap = target - referenceEnd
                    if gap > Int(Recording.sampleRate) {
                        // Long gone: start over there (anything earlier reads as silence).
                        reference.removeAll(keepingCapacity: true)
                        referenceBase = target
                        referenceEnd = target
                    } else {
                        reference.append(contentsOf: repeatElement(0, count: gap))
                        referenceEnd = target
                    }
                } else if referenceEnd - target > slack {
                    samples = samples.dropFirst(min(samples.count, referenceEnd - target))
                }
            } else if !hasReference {
                continue
            }
            reference.append(contentsOf: samples)
            referenceEnd += samples.count
        }
        // Keep a second behind the oldest mic sample waiting, at most.
        let needed = pendingIndex.first ?? referenceEnd
        let drop = min(reference.count, needed - Int(Recording.sampleRate) - referenceBase)
        if drop > Int(Recording.sampleRate) / 2 {
            reference.removeFirst(drop)
            referenceBase += drop
        }
    }

    private func far(at index: Int) -> Float {
        index >= referenceBase && index < referenceEnd ? reference[index - referenceBase] : 0
    }

    // MARK: Frames

    /// Runs every frame whose reference is in (or that waited long enough; all of them when `final`).
    private func run(final: Bool) -> [Float] {
        let frame = settings.frame
        let wait = Int(settings.maxWait * Recording.sampleRate)
        var out: [Float] = []
        var consumed = 0
        while pendingMic.count - consumed >= frame || (final && pendingMic.count > consumed) {
            let count = min(frame, pendingMic.count - consumed)
            let ready = referenceEnd > pendingIndex[consumed + count - 1]
            if !ready, !final, pendingMic.count - consumed - frame < wait { break }
            for i in 0..<frame {
                if i < count {
                    micFrame[i] = Self.int16(pendingMic[consumed + i])
                    farFrame[i] = Self.int16(far(at: pendingIndex[consumed + i]))
                } else {
                    micFrame[i] = 0
                    farFrame[i] = 0
                }
            }
            out += step(raw: Array(pendingMic[consumed..<consumed + count]))
            consumed += count
        }
        pendingMic.removeFirst(consumed)
        pendingIndex.removeFirst(consumed)
        return out
    }

    /// One frame (in `micFrame`/`farFrame`) through the canceller and the preprocessor, whose version of the frame
    /// before goes through the gate: hands back what the gate gives, two frames before this one.
    private func step(raw: [Float]) -> [Float] {
        makeStagesIfNeeded()
        let frame = settings.frame
        let zero = !micFrame.contains { $0 != 0 }
        if zero {
            for i in 0..<frame { linear[i] = 0 }
        } else {
            micFrame.withUnsafeBufferPointer { mic in
                farFrame.withUnsafeBufferPointer { far in
                    linear.withUnsafeMutableBufferPointer { out in
                        speex_echo_cancellation(echo, mic.baseAddress, far.baseAddress, out.baseAddress)
                    }
                }
            }
        }
        report.processedFrames += 1
        // Measured against the mic without its DC and rumble, which the canceller takes out whatever the echo.
        notch.filter(micFrame, into: &notched)
        var micEnergy = 0.0, linearEnergy = 0.0
        for i in 0..<frame {
            micEnergy += notched[i] * notched[i]
            linearEnergy += Double(linear[i]) * Double(linear[i])
        }
        let farEnergy = Self.energy(farFrame)
        let farActive = !zero && farEnergy / Double(frame) >= Self.farVoiced
        farSmooth += 0.3 * (farEnergy - farSmooth)
        let echoOnly = farActive && linearEnergy < 0.5 * micEnergy
        recent.append((farActive, echoOnly))
        if recent.count > settings.releaseFrames { recent.removeFirst(recent.count - settings.releaseFrames) }
        decide()
        if farActive {
            couplings.append(micEnergy / max(farSmooth, 1))
            if couplings.count > 200 { couplings.removeFirst() }
            if couplings.count >= 20 { coupling = couplings.sorted()[couplings.count * 3 / 10] }
        }
        frames.append(Frame(raw: raw, zero: zero, micEnergy: micEnergy, echoOnly: echoOnly,
                            mic: notched.map(Float.init), far: farFrame.map(Float.init)))

        _ = linear.withUnsafeMutableBufferPointer { speex_preprocess_run(cleaning, $0.baseAddress) }
        // The preprocessor gave the frame before; the first time, a frame from before any (dropped).
        guard frames.count >= 2 else { return [] }
        return gate(cleaned: linear.map(Float.init), of: frames[frames.count - 2])
    }

    /// `cleaned`, the preprocessor's version of `frame`, through the gate: hands back the frame the gate had before,
    /// mixed (nothing the first time).
    private func gate(cleaned: [Float], of frame: Frame) -> [Float] {
        let gated = echoGate!.process(cleaned, mic: frame.mic, far: frame.far, learn: frame.echoOnly,
                                      prior: Float(coupling), settings: settings)
        guard gatePrimed else {
            gatePrimed = true
            return []
        }
        return emit(frames.removeFirst(), cancelled: gated)
    }

    /// Whether the cancelled version is used from now on.
    private func decide() {
        guard settings.gate else {
            engaged = true
            return
        }
        func echo(last frames: Int) -> (share: Double, frames: Int) {
            var active = 0, echoes = 0
            for entry in recent.suffix(frames) where entry.farActive {
                active += 1
                if entry.echoOnly { echoes += 1 }
            }
            return (active == 0 ? 0 : Double(echoes) / Double(active), active)
        }
        if !engaged {
            let short = echo(last: settings.engageFrames)
            if short.frames >= settings.engageMinimumFrames, short.share >= settings.engageShare { engaged = true }
        } else {
            let long = echo(last: settings.releaseFrames)
            if long.frames >= settings.releaseMinimumFrames, long.share < settings.releaseShare { engaged = false }
        }
    }

    /// `frame` as recorded, mixed with its cancelled version (16-bit units).
    private func emit(_ frame: Frame, cancelled: [Float]) -> [Float] {
        let start = weight
        let target: Double = engaged ? 1 : 0
        // The crossfades belong to the part as recorded, where the music is the floor: a part with the cancelled
        // version starts once the crossfade into it is over, and ends where the one out of it starts.
        if !engaged, heading {
            heading = false
            if report.switches.count < 64 { report.switches.append(emitted) }
        }
        weight = target > weight ? min(target, weight + 0.1) : max(target, weight - 0.1)
        let count = frame.raw.count
        var out = [Float](repeating: 0, count: count)
        if !frame.zero {
            for i in 0..<count {
                let a = frame.raw[i], b = cancelled[i] / 32_768
                if start == 0 && weight == 0 {
                    out[i] = a
                } else if start == 1 && weight == 1 {
                    out[i] = b
                } else {
                    // 100 ms from one version to the other, on a raised cosine.
                    let w = start + (weight - start) * Double(i + 1) / Double(settings.frame)
                    let s = Float(0.5 - 0.5 * cos(Double.pi * w))
                    out[i] = s * b + (1 - s) * a
                }
            }
        }
        emitted += count
        if engaged, !heading, weight == 1 {
            heading = true
            if report.switches.count < 64 { report.switches.append(emitted) }
        }
        if weight >= 0.5 {
            report.cancelledFrames += 1
            if frame.echoOnly {
                reducedMic += frame.micEnergy
                reducedOut += out.reduce(0.0) { $0 + Double($1 * 32_768) * Double($1 * 32_768) }
            }
        }
        return out
    }

    private func finishReport() {
        report.echoReductionDB = reducedMic > 0 ? 10 * log10(reducedMic / max(reducedOut, 1)) : nil
    }

    private func makeStagesIfNeeded() {
        guard echo == nil else { return }
        let frame = Int32(settings.frame)
        echo = speex_echo_state_init(frame, Int32(settings.filterLength))
        var rate = Int32(Recording.sampleRate)
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        echoGate = EchoGate(hop: settings.frame)
        guard let preprocessor = speex_preprocess_state_init(frame, rate) else { return }
        func set(_ request: Int32, _ value: Int32) {
            var value = value
            speex_preprocess_ctl(preprocessor, request, &value)
        }
        set(SPEEX_PREPROCESS_SET_DENOISE, settings.noiseSuppress == nil ? 0 : 1)
        if let noise = settings.noiseSuppress { set(SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, noise) }
        set(SPEEX_PREPROCESS_SET_AGC, 0)
        set(SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, settings.echoSuppress)
        set(SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, settings.echoSuppressActive)
        speex_preprocess_ctl(preprocessor, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
        cleaning = preprocessor
    }

    private static func energy(_ samples: [Int16]) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    }

    private static func int16(_ sample: Float) -> Int16 {
        Int16(clamping: Int((sample * 32_768).rounded()))
    }
}

/// Stage 3 of `LiveEchoCanceller`: per frequency band, lets through only what's louder than a share of the echo the
/// Mac's sound makes there. A short-time Fourier transform (20 ms windows every 10 ms, square-root Hann, so with every
/// band let through the output is the input a frame later, exactly). For each band:
///
/// - the reference's power, held over the speakers' delay and the room (it falls 1 dB per 10 ms);
/// - how loud the echo is in the mic for it, learned in frames where the echo is most of the mic (the canceller
///   took at least half of it away), starting from the whole frame's figure;
/// - the gain: what of the band's power isn't `echoShare` of that echo, down to `residualFloorDB`, closing again at
///   `residualRelease` per frame after it opened.
final class EchoGate {
    let hop: Int
    private let size = 512
    private let bins = 257
    private let setup: FFTSetup
    private let window: [Float]
    private var outHistory: [Float], micHistory: [Float], farHistory: [Float]
    private var overlap: [Float]
    private var farPower: [Float], coupling: [Float], gains: [Float]
    private var learned: [Bool]
    // Scratch.
    private var real: [Float], imaginary: [Float], power: [Float], micPower: [Float], buffer: [Float]

    init(hop: Int) {
        self.hop = hop
        setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        let length = 2 * hop
        window = (0..<length).map { Float((0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(length))).squareRoot()) }
        outHistory = [Float](repeating: 0, count: length)
        micHistory = outHistory
        farHistory = outHistory
        overlap = [Float](repeating: 0, count: hop)
        farPower = [Float](repeating: 0, count: bins)
        coupling = farPower
        gains = [Float](repeating: 1, count: bins)
        learned = [Bool](repeating: false, count: bins)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = real
        power = farPower
        micPower = farPower
        buffer = [Float](repeating: 0, count: size)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// One hop of the output to gate, with the mic and the reference of the same moment: hands back the hop before.
    /// `learn`: the echo is most of the mic in this hop. `prior`: the whole frame's echo coupling, for bands not
    /// learned yet (0: unknown).
    func process(_ out: [Float], mic: [Float], far: [Float], learn: Bool, prior: Float,
                 settings: LiveEchoCanceller.Settings) -> [Float] {
        Self.push(out, into: &outHistory)
        Self.push(mic, into: &micHistory)
        Self.push(far, into: &farHistory)

        spectrum(of: farHistory)
        for bin in 0..<bins { farPower[bin] = max(power[bin], 0.79 * farPower[bin]) }
        spectrum(of: micHistory)
        micPower = power
        if learn {
            // Only where the reference has something: elsewhere the ratio is noise over nothing.
            let loudest = farPower.max() ?? 0
            for bin in 0..<bins where farPower[bin] > loudest * 1e-4 && farPower[bin] > 0 {
                let ratio = micPower[bin] / farPower[bin]
                coupling[bin] = learned[bin] ? coupling[bin] + 0.1 * (ratio - coupling[bin]) : ratio
                learned[bin] = true
            }
        }
        spectrum(of: outHistory)
        let floor = Foundation.pow(10, settings.residualFloorDB / 10)
        for bin in 0..<bins {
            var target: Float = 1
            if settings.suppressResidual {
                let echo = settings.echoShare * (learned[bin] ? coupling[bin] : prior) * farPower[bin]
                // Never more than the mic had there: where the canceller added to it, it's still the echo.
                let heard = min(power[bin], micPower[bin])
                target = heard > 0 ? min(1, max(floor, 1 - echo / heard)) : (echo > 0 ? floor : 1)
            }
            gains[bin] = max(target, gains[bin] * settings.residualRelease)
        }
        // The output's spectrum is still in `real`/`imaginary`: gated, back, windowed and overlapped.
        real[0] *= gains[0].squareRoot()
        imaginary[0] *= gains[bins - 1].squareRoot()
        for bin in 1..<bins - 1 {
            let gain = gains[bin].squareRoot()
            real[bin] *= gain
            imaginary[bin] *= gain
        }
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(kFFTDirection_Inverse))
                buffer.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2))
                    }
                }
            }
        }
        // Forward and back scale by 2 * size.
        let scale = 1 / Float(2 * size)
        var result = [Float](repeating: 0, count: hop)
        for i in 0..<hop {
            result[i] = overlap[i] + buffer[i] * scale * window[i]
            overlap[i] = buffer[hop + i] * scale * window[hop + i]
        }
        return result
    }

    private static func push(_ hop: [Float], into history: inout [Float]) {
        let count = hop.count
        history.removeFirst(count)
        history.append(contentsOf: hop)
    }

    /// The windowed, zero-padded spectrum of `samples` into `real`/`imaginary` (packed: Nyquist in `imaginary[0]`),
    /// and its power per bin into `power`.
    private func spectrum(of samples: [Float]) {
        for i in 0..<size { buffer[i] = i < samples.count ? samples[i] * window[i] : 0 }
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                buffer.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(kFFTDirection_Forward))
            }
        }
        power[0] = real[0] * real[0]
        power[bins - 1] = imaginary[0] * imaginary[0]
        for bin in 1..<bins - 1 { power[bin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
    }
}

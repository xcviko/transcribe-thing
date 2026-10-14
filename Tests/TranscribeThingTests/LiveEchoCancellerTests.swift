import AVFAudio
import Foundation
import Testing
@testable import TranscribeThing

// Dictating while the Mac plays music on its speakers (`LiveEchoCanceller`, `DictationEcho`, the capture that runs
// them). The music is synthetic and never dips, like a song: chords that change every half second over a steady hiss.
// The mic hears it 30 ms late through a short room; the person talks over it about as loud as it is, which the speech
// check and the pill's voice gate took for nothing.

private let rate = Recording.sampleRate

/// A song from the tap: three-note chords with harmonics, a new one every 0.5 s, over a steady hiss. About -17 dBFS.
private func music(seconds: Double, seed: UInt32 = 7) -> [Float] {
    var seed = seed
    let scale = [196.0, 220, 246.9, 261.6, 293.7, 329.6, 349.2, 392, 440, 493.9, 523.3]
    var chords: [[Double]] = []
    for _ in 0..<Int(seconds / 0.5) + 1 {
        var notes: [Double] = []
        for _ in 0..<3 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            notes.append(scale[Int(seed >> 16) % scale.count])
        }
        chords.append(notes)
    }
    var phases = [Double](repeating: 0, count: 3)
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        let chord = chords[Int(t / 0.5)]
        var sample = 0.0
        for (n, f) in chord.enumerated() {
            phases[n] += 2 * .pi * f / rate
            for harmonic in 1...4 { sample += sin(Double(harmonic) * phases[n]) / Double(harmonic * harmonic) }
        }
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let hiss = Double(seed >> 8) / Double(1 << 24) - 0.5
        return Float(0.06 * sample + 0.03 * hiss)
    }
}

/// A voice from `from` to `to` seconds: harmonics on a wandering pitch in syllables with a breathy part, with a
/// 0.3 s pause every 1.3 s (as `EchoCancellerTests` has it).
private func voice(seconds: Double, pitch: Double = 210, seed: UInt32 = 2, from: Double = 0, to: Double = .infinity,
                   gain: Double = 0.1) -> [Float] {
    var seed = seed
    var phase = 0.0
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        let f0 = pitch * (1 + 0.08 * sin(2 * .pi * 0.7 * t) + 0.04 * sin(2 * .pi * 2.3 * t))
        phase += 2 * .pi * f0 / rate
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = Double(seed >> 8) / Double(1 << 24) - 0.5
        guard t >= from, t < to else { return 0 }
        let inPause = (t - from).truncatingRemainder(dividingBy: 1.3) >= 1.0
        let syllable = inPause ? 0 : pow(sin(.pi * (t * 3.7).truncatingRemainder(dividingBy: 1)), 2)
        var harmonics = 0.0
        for harmonic in 1...15 where Double(harmonic) * f0 < 7_000 {
            harmonics += sin(Double(harmonic) * phase) / Double(harmonic)
        }
        return Float(gain * syllable * (0.7 * harmonics + 0.6 * noise))
    }
}

/// `played` as the mic hears it from the speakers: 30 ms late, through a short room, about 9 dB down.
private func echo(of played: [Float]) -> [Float] {
    let taps: [(delay: Int, gain: Float)] = [(480, 0.35), (520, 0.15), (575, -0.1), (690, 0.06), (880, 0.03)]
    var out = [Float](repeating: 0, count: played.count)
    for (delay, gain) in taps {
        for i in delay..<played.count { out[i] += played[i - delay] * gain }
    }
    return out
}

/// The room's faint noise, about -72 dBFS.
private func roomNoise(seconds: Double) -> [Float] {
    var seed: UInt32 = 99
    return (0..<Int(seconds * rate)).map { _ in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(Double(seed >> 8) / Double(1 << 24) - 0.5) * 0.001
    }
}

/// 8 s of dictation over music: it plays all along, the person talks from 2 s.
private struct MusicScene {
    let seconds: Double
    let played: [Float]
    let near: [Float]
    let mic: [Float]
    /// The person alone in the same room: what the speech check should find.
    let alone: [Float]

    /// `nonlinear`: the speakers distort, as laptop speakers playing loud do, which no linear filter can follow.
    init(seconds: Double = 8, speechFrom: Double = 2, voiceGain: Double = 0.1, echoes: Bool = true,
         nonlinear: Bool = false) {
        self.seconds = seconds
        let played = music(seconds: seconds)
        let near = voice(seconds: seconds, from: speechFrom, gain: voiceGain)
        let noise = roomNoise(seconds: seconds)
        let speaker = nonlinear ? played.map { tanh(4 * $0) / 4 } : played
        let heard = echoes ? echo(of: speaker) : [Float](repeating: 0, count: played.count)
        self.played = played
        self.near = near
        mic = (0..<played.count).map { heard[$0] + near[$0] + noise[$0] }
        alone = (0..<played.count).map { near[$0] + noise[$0] }
    }
}

private func slice(_ samples: [Float], _ from: Double, _ to: Double) -> ArraySlice<Float> {
    samples[Int(from * rate)..<min(samples.count, Int(to * rate))]
}

private func dB(_ samples: ArraySlice<Float>) -> Double {
    let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
    return 10 * log10(max(energy, 1e-16))
}

/// Hands the reference over the way a tap does: in stretches stamped with their `AudioClock` time, up to what the
/// test lets through.
private final class ReferenceFeed: @unchecked Sendable {
    let origin: TimeInterval
    let samples: [Float]
    private let lock = NSLock()
    private var given = 0
    private var available = 0
    private var started = false

    init(origin: TimeInterval, samples: [Float]) {
        self.origin = origin
        self.samples = samples
    }

    /// Makes the reference up to `index` available; the first stretch starts at `from`.
    func release(upTo index: Int, from: Int = 0) {
        lock.withLock {
            if !started {
                given = from
                started = true
            }
            available = min(samples.count, max(available, index))
        }
    }

    func drain() -> [TimedAudio] {
        lock.withLock {
            guard started, available > given else { return [] }
            let start = origin + Double(given) / rate
            defer { given = available }
            return [TimedAudio(samples: Array(samples[given..<available]), start: start)]
        }
    }
}

/// Runs `mic` through a canceller 10 ms at a time, as the mic's IO cycles come, with the tap's reference arriving
/// `lag` samples behind the mic (from `tapFrom` seconds on; never, for nil).
private func cancelLive(_ mic: [Float], reference: [Float], lag: Int = 320, tapFrom: Double? = 0,
                        settings: LiveEchoCanceller.Settings = .standard) -> (out: [Float], report: LiveEchoCanceller.Report) {
    let origin = 1_000.0
    let feed = ReferenceFeed(origin: origin, samples: reference)
    let canceller = LiveEchoCanceller(settings: settings, origin: origin) { feed.drain() }
    var out: [Float] = []
    let chunk = 160
    var start = 0
    while start < mic.count {
        let end = min(mic.count, start + chunk)
        if let tapFrom, Double(end) / rate >= tapFrom {
            feed.release(upTo: end - lag, from: Int(tapFrom * rate))
        }
        out += canceller.process(Array(mic[start..<end]), at: origin + Double(start) / rate)
        start = end
    }
    if tapFrom != nil { feed.release(upTo: reference.count) }
    out += canceller.flush()
    return (out, canceller.report)
}

/// The share of 100 ms stretches in `from..<to` where the gate let voice through.
private func gateOpenShare(_ samples: [Float], from: Double, to: Double) -> Double {
    let meter = LevelMeter(clock: { 0 })
    let window = 160
    for index in 0..<samples.count / window {
        let frame = samples[index * window..<(index + 1) * window]
        let rms = (frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(window)).squareRoot()
        meter.ingest(rmsDBFS: rms > 1e-8 ? 20 * log10(rms) : -160, at: Double(index + 1) * 0.01)
    }
    let stretches = stride(from: from, to: to, by: 0.1).map { meter.voiceAmplitude(from: $0, to: $0 + 0.1) }
    return Double(stretches.filter { $0 > 0 }.count) / Double(max(1, stretches.count))
}

@Suite struct LiveEchoCancellerTests {
    @Test func withoutTheCancellerMusicHidesTheVoice() {
        // The bug as it was: the speech check finds (almost) nothing, and the pill's voice gate lets through little.
        let scene = MusicScene()
        let truth = SpeechAnalyzer.stats(for: scene.alone).voicedSeconds
        let heard = SpeechAnalyzer.stats(for: scene.mic).voicedSeconds
        let gate = gateOpenShare(scene.mic, from: 3, to: 8)
        let alone = gateOpenShare(scene.alone, from: 3, to: 8)
        print("baseline: voiced \(heard) s of \(truth) s, gate open \(gate) (alone \(alone))")
        #expect(truth >= 2.5)
        #expect(heard < 0.25 * truth, "voiced \(heard) of \(truth)")
        #expect(gate < 0.6 * alone, "gate open \(gate), alone \(alone)")
    }

    @Test(arguments: [false, true])
    func theMusicGoesAndTheVoiceIsFound(distorted: Bool) {
        // The person talks about as loud as the music (2 dB over it), from 2 s; the tap is up from the start.
        let scene = MusicScene(nonlinear: distorted)
        let (out, report) = cancelLive(scene.mic, reference: scene.played)
        #expect(out.count == scene.mic.count)
        let truth = SpeechAnalyzer.stats(for: scene.alone).voicedSeconds
        let voiced = SpeechAnalyzer.stats(for: out, sampleRate: rate, parts: report.switches).voicedSeconds
        let gate = gateOpenShare(out, from: 3, to: 8)
        let alone = gateOpenShare(scene.alone, from: 3, to: 8)
        let erle = dB(slice(scene.mic, 1, 2)) - dB(slice(out, 1, 2))
        let kept = dB(slice(out, 6.6, 7.6)) - dB(slice(scene.alone, 6.6, 7.6))
        print("cancelled (distorted: \(distorted)): voiced \(voiced) s of \(truth) s, gate open \(gate) (alone \(alone)), music down \(erle) dB, voice \(kept) dB, report \(report)")
        #expect(voiced >= 0.7 * truth && voiced <= 1.1 * truth, "voiced \(voiced) of \(truth)")
        #expect(gate >= 0.85 * alone, "gate open \(gate), alone \(alone)")
        #expect(erle >= 25, "music down \(erle) dB")
        #expect(report.hadReference)
        #expect(report.cancelledFrames > 600)
        #expect(report.switches.count == 1 && report.switches[0] < Int(1.2 * rate), "\(report.switches)")
        #expect((report.echoReductionDB ?? 0) >= 15)
        // The voice keeps most of its level: the gate takes it down only in the bands where the music is louder.
        #expect(kept >= -6 && kept <= 1, "voice \(kept) dB")
    }

    @Test(arguments: [false, true])
    func musicAloneIsStillNoSpeech(distorted: Bool) {
        // Dictation started by mistake while a song plays: still nothing to send. The tap comes up 0.3 s in; the
        // first part is the mic as recorded, measured on its own.
        let scene = MusicScene(seconds: 6, voiceGain: 0, nonlinear: distorted)
        let (out, report) = cancelLive(scene.mic, reference: scene.played, tapFrom: 0.3)
        let voiced = SpeechAnalyzer.stats(for: out, sampleRate: rate, parts: report.switches).voicedSeconds
        let gate = gateOpenShare(out, from: 1, to: 6)
        print("music alone (distorted: \(distorted)): voiced \(voiced) s, gate open \(gate), report \(report)")
        #expect(voiced < 0.1, "voiced \(voiced)")
        #expect(gate < 0.05, "gate open \(gate)")
        #expect(report.cancelledFrames > 400)
    }

    @Test func aQuieterVoiceIsStillFound() {
        // 4 dB under the music: most of it is found, where nothing was.
        let scene = MusicScene(voiceGain: 0.05)
        let (out, report) = cancelLive(scene.mic, reference: scene.played)
        let truth = SpeechAnalyzer.stats(for: scene.alone).voicedSeconds
        let before = SpeechAnalyzer.stats(for: scene.mic).voicedSeconds
        let voiced = SpeechAnalyzer.stats(for: out, sampleRate: rate, parts: report.switches).voicedSeconds
        print("quieter voice: voiced \(voiced) s of \(truth) s (without: \(before))")
        #expect(before < 0.1 * truth)
        #expect(voiced >= 0.5 * truth, "voiced \(voiced) of \(truth)")
    }

    @Test func aTapThatComesUpLateStartsCancellingThen() {
        let scene = MusicScene(seconds: 9, speechFrom: 3.5)
        let (out, report) = cancelLive(scene.mic, reference: scene.played, tapFrom: 1.5)
        #expect(out.count == scene.mic.count)
        // Before the tap, the mic exactly as recorded and with no delay.
        #expect(Array(out[0..<Int(1.5 * rate)]) == Array(scene.mic[0..<Int(1.5 * rate)]))
        let truth = SpeechAnalyzer.stats(for: scene.alone).voicedSeconds
        let voiced = SpeechAnalyzer.stats(for: out, sampleRate: rate, parts: report.switches).voicedSeconds
        print("late tap: voiced \(voiced) s of \(truth) s, report \(report)")
        #expect(voiced >= 0.7 * truth, "voiced \(voiced) of \(truth)")
        #expect(report.hadReference)
    }

    @Test func noTapLeavesTheMicAsItIs() {
        let scene = MusicScene(seconds: 3)
        let (out, report) = cancelLive(scene.mic, reference: scene.played, tapFrom: nil)
        #expect(out == scene.mic)
        #expect(report == LiveEchoCanceller.Report())
    }

    @Test func onHeadphonesTheVoiceIsUntouched() {
        // The Mac plays, but into headphones: the mic never hears it. Nothing to cancel, so nothing is.
        let scene = MusicScene(echoes: false)
        let (out, report) = cancelLive(scene.mic, reference: scene.played)
        #expect(out.count == scene.mic.count)
        #expect(report.hadReference)
        #expect(report.cancelledFrames == 0)
        #expect(out == scene.mic)
    }

    @Test func evenForcedOnAReferenceTheMicDoesNotHearKeepsTheVoice() {
        // The gate is what keeps headphones exact; without it the canceller still leaves the voice near its level.
        let scene = MusicScene(echoes: false)
        var settings = LiveEchoCanceller.Settings.standard
        settings.gate = false
        let (out, _) = cancelLive(scene.mic, reference: scene.played, settings: settings)
        let kept = dB(slice(out, 3, 8)) - dB(slice(scene.mic, 3, 8))
        let truth = SpeechAnalyzer.stats(for: scene.alone).voicedSeconds
        let voiced = SpeechAnalyzer.stats(for: out).voicedSeconds
        print("forced on, uncorrelated: voice \(kept) dB, voiced \(voiced) of \(truth)")
        #expect(abs(kept) <= 2, "voice \(kept) dB")
        #expect(voiced >= 0.8 * truth)
    }

    @Test func aReferenceThatStallsDoesNotHoldTheMicBack() {
        // The tap delivers the first second and then nothing: the mic waits at most `maxWait` for it.
        let scene = MusicScene(seconds: 3)
        let origin = 1_000.0
        let feed = ReferenceFeed(origin: origin, samples: scene.played)
        let canceller = LiveEchoCanceller(origin: origin) { feed.drain() }
        feed.release(upTo: Int(rate))
        var out: [Float] = []
        for start in stride(from: 0, to: scene.mic.count, by: 160) {
            out += canceller.process(Array(scene.mic[start..<min(scene.mic.count, start + 160)]),
                                     at: origin + Double(start) / rate)
        }
        let held = scene.mic.count - out.count
        #expect(held <= Int(LiveEchoCanceller.Settings.standard.maxWait * rate) + 3 * 160, "held \(held)")
        out += canceller.flush()
        #expect(out.count == scene.mic.count)
    }

    @Test func theGateOpenIsTheInputAFrameLater() {
        // Every band let through: the short-time transform gives back exactly what went in, 10 ms later.
        var settings = LiveEchoCanceller.Settings.standard
        settings.suppressResidual = false
        let gate = EchoGate(hop: 160)
        let input = voice(seconds: 1, from: 0).map { $0 * 32_768 }
        let silence = [Float](repeating: 0, count: 160)
        var out: [Float] = []
        for start in stride(from: 0, to: input.count, by: 160) {
            out += gate.process(Array(input[start..<start + 160]), mic: silence, far: silence, learn: false, prior: 0,
                                settings: settings)
        }
        let error = zip(out.dropFirst(160), input).map { abs($0 - $1) }.max() ?? 0
        #expect(error < 0.01, "largest difference \(error) of 32768")
    }

    @Test func costsLittle() {
        // 20 s of dictation over music, 10 ms at a time. Release builds run hundreds of times faster than real
        // time; debug builds (Speex unoptimised) still several times.
        let seconds = 20.0
        let played = music(seconds: seconds)
        let near = voice(seconds: seconds, from: 1)
        let heard = echo(of: played)
        let mic = (0..<played.count).map { heard[$0] + near[$0] }
        let began = ContinuousClock.now
        let (out, _) = cancelLive(mic, reference: played)
        let took = ContinuousClock.now - began
        let seconds_ = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let factor = seconds / seconds_
        print("live echo canceller: \(seconds) s of audio in \(seconds_) s, \(Int(factor))x real time, \(1000 * seconds_ / seconds) ms per second of audio")
        #expect(out.count == mic.count)
        #expect(factor >= 2)
    }
}

/// A tap that hands over what the test gives it.
private final class FakeTap: CallTrackSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [TimedAudio] = []
    private var running = false
    private var stopped = false

    var isRunning: Bool { lock.withLock { running } }
    var isStopped: Bool { lock.withLock { stopped } }
    var problem: String? { nil }

    func start() { lock.withLock { running = true } }
    func stop() { lock.withLock { stopped = true } }
    func give(_ audio: TimedAudio) { lock.withLock { queued.append(audio) } }
    func drain() -> [TimedAudio] {
        lock.withLock {
            defer { queued = [] }
            return queued
        }
    }
}

/// What the echo's checks were asked, and the taps it made.
private final class EchoProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var playingNow: Bool
    private var looks = 0
    private var made: [FakeTap] = []
    let permission: SystemAudioPermission.Status

    init(permission: SystemAudioPermission.Status, playing: Bool) {
        self.permission = permission
        playingNow = playing
    }

    var playing: Bool {
        get { lock.withLock { playingNow } }
        set { lock.withLock { playingNow = newValue } }
    }

    var lookCount: Int { lock.withLock { looks } }
    var taps: [FakeTap] { lock.withLock { made } }

    var sensors: DictationEcho.Sensors {
        DictationEcho.Sensors(
            permission: { self.permission },
            othersPlaying: {
                self.lock.withLock {
                    self.looks += 1
                    return self.playingNow
                }
            },
            makeTap: {
                let tap = FakeTap()
                self.lock.withLock { self.made.append(tap) }
                return tap
            },
            recheck: 0.02)
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

@Suite struct DictationEchoTests {
    @Test func withoutThePermissionNoTapIsMadeAndNothingIsAsked() async throws {
        let probe = EchoProbe(permission: .denied, playing: true)
        let echo = DictationEcho(sensors: probe.sensors)
        echo.start()
        try await waitUntil { echo.status != .checking }
        #expect(echo.status == .noPermission)
        try await Task.sleep(for: .milliseconds(60))
        #expect(probe.taps.isEmpty)
        #expect(probe.lookCount == 0)
        #expect(echo.drain().isEmpty)
        // Not asked yet counts as not allowed: a tap would bring up the system's prompt mid-dictation.
        let unknown = EchoProbe(permission: .unknown, playing: true)
        let second = DictationEcho(sensors: unknown.sensors)
        second.start()
        try await waitUntil { second.status != .checking }
        #expect(second.status == .noPermission)
        #expect(unknown.taps.isEmpty)
    }

    @Test func nothingPlayingMakesNoTapUntilSomethingDoes() async throws {
        let probe = EchoProbe(permission: .authorized, playing: false)
        let echo = DictationEcho(sensors: probe.sensors)
        echo.start()
        try await waitUntil { probe.lookCount >= 3 }
        #expect(echo.status == .nothingPlaying)
        #expect(probe.taps.isEmpty)
        // Music starts mid-dictation: the next look makes the tap.
        probe.playing = true
        try await waitUntil { echo.status == .tapping }
        #expect(probe.taps.count == 1)
        #expect(probe.taps.first?.isRunning == true)
        let looks = probe.lookCount
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.lookCount == looks)
        echo.stop()
        try await waitUntil { probe.taps.first?.isStopped == true }
        #expect(probe.taps.first?.isStopped == true)
    }

    @Test func stoppedBeforeTheLookMakesNoTap() async throws {
        let probe = EchoProbe(permission: .authorized, playing: true)
        let echo = DictationEcho(sensors: probe.sensors)
        echo.stop()
        echo.start()
        try await Task.sleep(for: .milliseconds(60))
        #expect(probe.taps.isEmpty)
    }

    @Test func theReportSaysWhatHappened() {
        var canceller = LiveEchoCanceller.Report()
        #expect(EchoCancellationReport(echo: .noPermission, canceller: canceller).status == .noPermission)
        #expect(EchoCancellationReport(echo: .nothingPlaying, canceller: canceller).status == .nothingPlaying)
        #expect(EchoCancellationReport(echo: .tapping, canceller: canceller).status == .noTap)
        canceller.hadReference = true
        #expect(EchoCancellationReport(echo: .tapping, canceller: canceller).status == .off)
        canceller.cancelledFrames = 250
        canceller.echoReductionDB = 21
        canceller.switches = [8_000]
        let on = EchoCancellationReport(echo: .tapping, canceller: canceller)
        #expect(on == EchoCancellationReport(status: .on, reductionDB: 21, seconds: 2.5, parts: [8_000]))
    }
}

@Suite struct DictationOverMusicCaptureTests {
    private func buffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
        return buffer
    }

    /// A capture over music, as the recorder runs it: the mic in 10 ms IO cycles, the tap's reference 20 ms behind it.
    private func capture(_ scene: MusicScene, probe: EchoProbe, meter: LevelMeter) async throws
        -> (samples: [Float], report: EchoCancellationReport?) {
        let device = AudioInputDevice(id: "synthetic", name: "Synthetic Mic", transport: .builtIn, isAvailable: true)
        let echo = DictationEcho(sensors: probe.sensors)
        let session = CaptureSession(device: CoreAudioHAL.InputRecord(device: device, audioID: 0),
                                     options: CaptureSession.Options(preferredUID: nil), meter: meter, echo: echo,
                                     onEvent: { _ in })
        echo.start()
        try await waitUntil { echo.status != .checking }
        let origin = session.startedAt
        let tap = probe.taps.first
        var given = 0
        for start in stride(from: 0, to: scene.mic.count, by: 160) {
            let end = min(scene.mic.count, start + 160)
            if let tap, end - 320 > given {
                tap.give(TimedAudio(samples: Array(scene.played[given..<end - 320]), start: origin + Double(given) / rate))
                given = end - 320
            }
            session.receive(buffer(scene.mic[start..<end]), chunkStart: origin + Double(start) / rate,
                            arrival: origin + Double(end) / rate)
        }
        let samples = session.finishNow(discard: false)
        return (samples, session.echoReport)
    }

    @Test func theRecordingTheMeterAndTheSpeechCheckHearTheVoice() async throws {
        let scene = MusicScene()
        let meter = LevelMeter(clock: { 0 })
        let probe = EchoProbe(permission: .authorized, playing: true)
        let (samples, report) = try await capture(scene, probe: probe, meter: meter)
        #expect(samples.count == scene.mic.count)
        let report_ = try #require(report)
        #expect(report_.status == .on)
        #expect((report_.reductionDB ?? 0) >= 15)
        let truth = SpeechAnalyzer.stats(for: scene.alone).voicedSeconds
        let voiced = SpeechAnalyzer.stats(for: samples, sampleRate: rate, parts: report_.parts).voicedSeconds
        #expect(voiced >= 0.7 * truth, "voiced \(voiced) of \(truth)")
        // The pill's gate opened on the voice: the meter was fed the cancelled mic.
        var open = 0, windows = 0
        let first = try #require(meter.settledTime)
        for t in stride(from: first - 4.5, to: first, by: 0.1) {
            windows += 1
            if meter.voiceAmplitude(from: t, to: t + 0.1) > 0 { open += 1 }
        }
        #expect(Double(open) / Double(windows) >= 0.4, "gate open \(open) of \(windows)")
    }

    @Test func withoutThePermissionTheMicIsAsRecorded() async throws {
        let scene = MusicScene(seconds: 2)
        let probe = EchoProbe(permission: .denied, playing: true)
        let (samples, report) = try await capture(scene, probe: probe, meter: LevelMeter(clock: { 0 }))
        #expect(samples == scene.mic)
        #expect(report?.status == .noPermission)
        #expect(report?.parts == [])
    }

    @Test func nothingPlayingTheMicIsAsRecorded() async throws {
        let scene = MusicScene(seconds: 2, echoes: false)
        let probe = EchoProbe(permission: .authorized, playing: false)
        let (samples, report) = try await capture(scene, probe: probe, meter: LevelMeter(clock: { 0 }))
        #expect(samples == scene.mic)
        #expect(report?.status == .nothingPlaying)
    }
}

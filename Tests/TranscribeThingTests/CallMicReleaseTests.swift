import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import TranscribeThing

// A call's mic let go while the call app has let go of it, and taken again (`MicTrackSource.release`, `retake`): the
// capture really stops, the track stays as long as the other side's with silence in the gap, a retake that fails is
// tried again, and dictation's own capture is never touched. No real mic: the devices, inputs and clock are fakes.

private let rate = Recording.sampleRate

/// Stands in for `HALDeviceInput`: the device it was asked to open, whether it runs, and audio the test pushes.
private final class MicFakeInput: CaptureInput, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?
    private var running = false
    private(set) var device: AudioDeviceID?
    let failure: CaptureFailure?

    init(failure: CaptureFailure?) {
        self.failure = failure
    }

    func start(device: AudioDeviceID, deliver: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onChange: @escaping @Sendable (CaptureInputChange) -> Void) throws {
        if let failure { throw failure }
        lock.withLock {
            self.device = device
            self.deliver = deliver
            running = true
        }
    }

    func stop() {
        lock.withLock {
            running = false
            deliver = nil
        }
    }

    var isRunning: Bool { lock.withLock { running } }

    /// `seconds` of a tone at 48 kHz, its first frame captured at `time`, in 10 ms IO cycles.
    func push(seconds: Double, at time: TimeInterval) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let cycle = 480
        for index in 0..<Int((seconds * 100).rounded()) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(cycle))!
            for i in 0..<cycle { buffer.floatChannelData![0][i] = 0.3 * Float(sin(Double(index * cycle + i) * 0.04)) }
            buffer.frameLength = AVAudioFrameCount(cycle)
            lock.withLock { deliver }?(buffer, time + Double(index) / 100)
        }
    }
}

/// The Mac's mics as the source sees them: the devices, the default input, every input opened, and starts to fail.
private final class MicFakeHAL: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CoreAudioHAL.InputRecord]
    private var defaultID: AudioDeviceID?
    private var created: [MicFakeInput] = []
    private var failures = 0

    init(records: [CoreAudioHAL.InputRecord], defaultID: AudioDeviceID?) {
        self.records = records
        self.defaultID = defaultID
    }

    var inputs: [MicFakeInput] { lock.withLock { created } }
    var opened: [AudioDeviceID] { inputs.compactMap(\.device) }
    /// The inputs running now: what the HAL would list for this process (`kAudioProcessPropertyIsRunningInput`).
    var running: [MicFakeInput] { inputs.filter(\.isRunning) }

    /// The next `count` starts fail, as a device that won't start.
    func failNext(_ count: Int) { lock.withLock { failures = count } }

    /// AirPods connect and become the default input.
    func connect(_ record: CoreAudioHAL.InputRecord) {
        lock.withLock {
            records.append(record)
            defaultID = record.audioID
        }
    }

    var capture: CaptureSession.Hardware {
        CaptureSession.Hardware(
            inputRecords: { self.lock.withLock { self.records } },
            defaultInputID: { self.lock.withLock { self.defaultID } },
            isAlive: { id in self.lock.withLock { self.records.contains { $0.audioID == id } } },
            processInputDeviceIDs: { self.running.compactMap(\.device) },
            makeInput: {
                self.lock.withLock {
                    let input = MicFakeInput(failure: self.failures > 0
                        ? .startFailed(NSError(domain: NSOSStatusErrorDomain, code: 560_557_684)) : nil)
                    self.failures = max(0, self.failures - 1)
                    self.created.append(input)
                    return input
                }
            })
    }

    /// No start timeout or stall while a busy machine runs the tests: a test pushes audio when it means to.
    static var patient: CaptureSession.Options {
        var options = CaptureSession.Options()
        options.firstBufferTimeout = 60
        options.stallTimeout = 60
        return options
    }

    func hardware(clock: FakeClock, backoff: [TimeInterval] = [0.01, 0.01], retryAfter: TimeInterval = 0.02)
        -> MicTrackSource.Hardware {
        MicTrackSource.Hardware(
            isAuthorized: { true },
            defaultInputUID: {
                self.lock.withLock { self.records.first { $0.audioID == self.defaultID }?.device.id }
            },
            capture: capture, options: Self.patient, clock: { clock.now }, retryAfter: retryAfter,
            retakeBackoff: backoff)
    }
}

/// `AudioClock` time as the test says it is.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval

    init(_ time: TimeInterval) {
        self.time = time
    }

    var now: TimeInterval {
        get { lock.withLock { time } }
        set { lock.withLock { time = newValue } }
    }
}

/// What a retake reported, in order.
private final class Retakes: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [MicRetake] = []
    func record(_ outcome: MicRetake) { lock.withLock { list.append(outcome) } }
    var all: [MicRetake] { lock.withLock { list } }
}

@Suite struct CallMicReleaseTests {
    private static let builtIn = CoreAudioHAL.InputRecord(
        device: AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn,
                                 isAvailable: true), audioID: 91)
    private static let airPods = CoreAudioHAL.InputRecord(
        device: AudioInputDevice(id: "airpods:input", name: "AirPods Pro", transport: .bluetooth, isAvailable: true),
        audioID: 120)

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// Telegram mutes at 1 s; the detector sees it and the recording lets go of the mic at 1.5 s; Telegram takes the mic
    /// again at 3.4 s, seen and taken at 3.5 s. The capture really stops meanwhile; the mic's track is as long as the
    /// other side's, the mute and the gap silent, its audio from before kept where it was and its audio after at its
    /// time. What was held back as the mic was let go is silenced from the mute's start, as any mute is.
    @Test func theGapIsSilenceOfItsLengthAndTheTracksStayInLine() async throws {
        let hal = MicFakeHAL(records: [Self.builtIn], defaultID: Self.builtIn.audioID)
        let clock = FakeClock(1000)
        let source = MicTrackSource(preferredUID: nil, hardware: hal.hardware(clock: clock))
        let remote = FakeSource()
        let journal = CallJournal(directory: AppPaths.temporary().callJournals)
        let info = CallJournal.Info(startedAt: Date(), appName: "Telegram", bundleID: "ru.keepcoder.Telegram",
                                    service: .telegram, consent: .kept)
        journal.begin(info, origin: 1000, sources: [.mic: source, .remote: remote])
        try await waitUntil { hal.running.count == 1 }
        let first = try #require(hal.inputs.first)
        first.push(seconds: 1.5, at: 1000)
        clock.now = 1001.5
        journal.pump(info.id)
        // Seen muted from 1 s, as the monitor notes it before it lets go.
        journal.update(info.id) {
            $0.mutes = [CallInterval(start: 1, end: 1.5)]
            $0.mutedSince = 1
        }
        // The fake clock jumps where a real one walks: the journal must have the mute before it sees the time move on.
        await journal.settle()
        source.release()
        try await waitUntil { hal.running.isEmpty }
        #expect(hal.capture.processInputDeviceIDs().isEmpty, "nothing of this app records from a mic")
        clock.now = 1002.5
        journal.pump(info.id)
        clock.now = 1003.5
        let retakes = Retakes()
        source.retake { retakes.record($0) }
        journal.update(info.id) {
            $0.mutes = [CallInterval(start: 1, end: 3.4)]
            $0.mutedSince = nil
        }
        await journal.settle()
        try await waitUntil { hal.running.count == 1 }
        #expect(hal.opened == [Self.builtIn.audioID, Self.builtIn.audioID])
        clock.now = 1003.58
        hal.running.first?.push(seconds: 1, at: 1003.5)
        try await waitUntil { retakes.all.count == 1 }
        let delivered = try #require(retakes.all.first)
        guard case .delivered(let seconds, let failures) = delivered else { Issue.record("\(delivered)"); return }
        #expect(abs(seconds - 0.08) < 0.001 && failures == 0)
        remote.push([Float](repeating: 0.25, count: Int(4.5 * rate)), at: 1000)

        let ended = try #require(await journal.end(info.id))
        #expect(ended.micProblem == nil)
        let mic = try #require(RecordingJournal.read(journal.audioURL(for: info.id, track: .mic)))
        let other = try #require(RecordingJournal.read(journal.audioURL(for: info.id, track: .remote)))
        #expect(abs(mic.count - other.count) < Int(0.02 * rate), "\(mic.count) vs \(other.count)")
        func at(_ from: Double, _ to: Double) -> ArraySlice<Float> { mic[Int(from * rate)..<min(mic.count, Int(to * rate))] }
        #expect(Self.rms(at(0.05, 0.95)) > 0.1, "before the mute: kept, where it was")
        #expect(at(1, 3.4).allSatisfy { $0 == 0 }, "muted, then let go: digital silence")
        #expect(at(3.4, 3.5).allSatisfy { $0 == 0 }, "until the mic was back")
        #expect(Self.rms(at(3.52, 4.45)) > 0.1, "after: at its own time")
        // The first sample of the retaken mic lands within a few ms of when it was captured.
        let onset = try #require(mic.indices.dropFirst(Int(3.4 * rate)).first { abs(mic[$0]) > 0.01 })
        #expect(abs(Double(onset) / rate - 3.5) < 0.01, "at \(Double(onset) / rate)")
    }

    /// A start that fails as the mic is taken again is tried again shortly, after each backoff and then on and on,
    /// until it gives audio: the call is never left without a mic once its app has its own back.
    @Test func aRetakeThatFailsIsTriedAgainUntilItWorks() async throws {
        let hal = MicFakeHAL(records: [Self.builtIn], defaultID: Self.builtIn.audioID)
        let clock = FakeClock(50)
        let source = MicTrackSource(preferredUID: nil, hardware: hal.hardware(clock: clock))
        source.start()
        try await waitUntil { hal.running.count == 1 }
        hal.running.first?.push(seconds: 0.2, at: 50)
        clock.now = 51
        source.release()
        try await waitUntil { hal.running.isEmpty }
        hal.failNext(4)
        let retakes = Retakes()
        clock.now = 52
        source.retake { retakes.record($0) }
        try await waitUntil { hal.running.count == 1 }
        #expect(hal.inputs.count == 6, "the first, four that failed, the one that started")
        #expect(retakes.all == [.failed(attempt: 1), .failed(attempt: 2), .failed(attempt: 3), .failed(attempt: 4)])
        clock.now = 52.5
        hal.running.first?.push(seconds: 0.1, at: 52.25)
        try await waitUntil { retakes.all.count == 5 }
        #expect(retakes.all.last == .delivered(seconds: 0.5, failures: 4))
        source.stop()
        try await waitUntil { hal.running.isEmpty }
    }

    /// AirPods connected while the mic was let go are the default input now: the retake takes them, as a fresh start
    /// would, and the track goes on.
    @Test func aRetakeTakesTheMicAFreshStartWouldPick() async throws {
        let hal = MicFakeHAL(records: [Self.builtIn], defaultID: Self.builtIn.audioID)
        let clock = FakeClock(10)
        let source = MicTrackSource(preferredUID: nil, hardware: hal.hardware(clock: clock))
        source.start()
        try await waitUntil { hal.running.count == 1 }
        hal.running.first?.push(seconds: 0.5, at: 10)
        clock.now = 10.5
        source.release()
        hal.connect(Self.airPods)
        clock.now = 12
        source.retake { _ in }
        try await waitUntil { hal.running.count == 1 }
        #expect(hal.opened == [Self.builtIn.audioID, Self.airPods.audioID])
        hal.running.first?.push(seconds: 0.5, at: 12)
        clock.now = 12.5
        source.stop()
        var placed = TrackAligner(origin: 10)
        let track = source.drain().flatMap { placed.place($0) }
        #expect(abs(track.count - Int(2.5 * rate)) < Int(0.02 * rate), "\(track.count)")
        #expect(track[Int(0.6 * rate)..<Int(1.95 * rate)].allSatisfy { $0 == 0 })
        #expect(Self.rms(track[Int(2.05 * rate)..<Int(2.45 * rate)]) > 0.1)
    }

    /// A call that ends with the mic let go (Telegram hung up, muted to the end) has its mic track to the end, silent.
    @Test func aCallEndingLetGoHasItsMicTrackToTheEnd() async throws {
        let hal = MicFakeHAL(records: [Self.builtIn], defaultID: Self.builtIn.audioID)
        let clock = FakeClock(10)
        let source = MicTrackSource(preferredUID: nil, hardware: hal.hardware(clock: clock))
        source.start()
        try await waitUntil { hal.running.count == 1 }
        hal.running.first?.push(seconds: 0.5, at: 10)
        clock.now = 10.5
        source.release()
        clock.now = 11.7
        var placed = TrackAligner(origin: 10)
        var track = source.drain().flatMap { placed.place($0) }
        clock.now = 13
        source.stop()
        track += source.drain().flatMap { placed.place($0) }
        #expect(abs(track.count - Int(3 * rate)) < Int(0.01 * rate), "\(track.count)")
        #expect(Self.rms(track[Int(0.05 * rate)..<Int(0.45 * rate)]) > 0.1)
        #expect(track[Int(0.55 * rate)...].allSatisfy { $0 == 0 })
        try await waitUntil { hal.running.isEmpty }
    }

    /// A mic that never gave audio (no device yet) leaves no track while let go: silence only follows audio.
    @Test func noSilenceBeforeTheFirstAudio() async throws {
        let hal = MicFakeHAL(records: [], defaultID: nil)
        let clock = FakeClock(0)
        let source = MicTrackSource(preferredUID: nil, hardware: hal.hardware(clock: clock, retryAfter: 60))
        source.start()
        try await waitUntil { source.problem == "No microphone" }
        source.release()
        clock.now = 30
        #expect(source.drain().isEmpty)
        source.stop()
        #expect(source.drain().isEmpty)
    }

    /// Dictation has a capture of its own: the call's mic let go and taken again never touches it.
    @Test func dictationsCaptureIsNeverTouched() async throws {
        let hal = MicFakeHAL(records: [Self.builtIn], defaultID: Self.builtIn.audioID)
        let clock = FakeClock(0)
        let dictation = CaptureSession(device: Self.builtIn, options: MicFakeHAL.patient, meter: LevelMeter(),
                                       hardware: hal.capture, onEvent: { _ in })
        dictation.start()
        try await waitUntil { hal.running.count == 1 }
        let dictationInput = try #require(hal.inputs.first)
        let call = MicTrackSource(preferredUID: nil, hardware: hal.hardware(clock: clock))
        call.start()
        try await waitUntil { hal.running.count == 2 }
        call.release()
        try await waitUntil { hal.running.count == 1 }
        #expect(hal.running.first === dictationInput)
        dictationInput.push(seconds: 0.2, at: AudioClock.now())
        #expect(dictation.capturedDuration > 0.15)
        call.retake { _ in }
        try await waitUntil { hal.running.count == 2 }
        call.stop()
        try await waitUntil { hal.running.count == 1 }
        #expect(dictationInput.isRunning)
        _ = dictation.finishNow(discard: true)
    }
}

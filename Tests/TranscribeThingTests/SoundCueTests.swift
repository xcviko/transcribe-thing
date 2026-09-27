import AVFAudio
import Foundation
import os
import Testing
@testable import TranscribeThing

/// A cue output that plays nothing: it records what `CueEngine` asks of it and on which thread.
final class FakeCueOutput: CueOutput, @unchecked Sendable {
    enum Call: Equatable { case load, start, stop, reset, play(SoundEffect) }

    struct State {
        var calls: [Call] = []
        var isRunning = false
        var calledOnMain = false
        /// Starts that throw before one succeeds.
        var failingStarts = 0
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    /// Blocks `start` until signaled, like a Bluetooth route waking (nil: returns at once).
    let startGate: DispatchSemaphore?
    var onChange: (() -> Void)?

    init(startGate: DispatchSemaphore? = nil, failingStarts: Int = 0) {
        self.startGate = startGate
        state.withLock { $0.failingStarts = failingStarts }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var calledOnMain: Bool { state.withLock { $0.calledOnMain } }
    var isRunning: Bool { state.withLock { $0.isRunning } }
    var played: [SoundEffect] {
        calls.compactMap { if case .play(let effect) = $0 { effect } else { nil } }
    }
    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    private func record(_ call: Call) {
        let onMain = Thread.isMainThread
        state.withLock {
            $0.calls.append(call)
            if onMain { $0.calledOnMain = true }
        }
    }

    func load() -> [SoundEffect: TimeInterval] {
        record(.load)
        return [.start: 0.5]
    }

    func start() throws {
        record(.start)
        startGate?.wait()
        let fails = state.withLock { state -> Bool in
            guard state.failingStarts > 0 else {
                state.isRunning = true
                return false
            }
            state.failingStarts -= 1
            return true
        }
        if fails { throw CueOutputError.noOutputDevice }
    }

    func stop() {
        record(.stop)
        state.withLock { $0.isRunning = false }
    }

    func reset() {
        record(.reset)
        state.withLock { $0.isRunning = false }
    }

    func play(_ effect: SoundEffect) -> Bool {
        record(.play(effect))
        return isRunning
    }

    /// What AirPods connecting (or `AVAudioEngineConfigurationChange`) does, from a CoreAudio thread.
    func simulateDeviceChange() {
        DispatchQueue.global().async { self.onChange?() }
    }
}

@MainActor
@Suite(.serialized) struct CueEngineTests {
    static func make(_ output: FakeCueOutput, idle: TimeInterval = 5, soundsOn: Bool = true) -> (SoundPlayer, CueEngine) {
        let settings = AppSettings.inMemory()
        settings.soundsEnabled = soundsOn
        let engine = CueEngine(idleRelease: idle, makeOutput: { output })
        let player = SoundPlayer(settings: settings, engine: engine)
        player.preload()
        engine.flush()
        return (player, engine)
    }

    @Test func playReturnsAtOnceAndNeverTouchesTheOutputOnTheCallingThread() async throws {
        let gate = DispatchSemaphore(value: 0)
        let output = FakeCueOutput(startGate: gate)
        let (player, engine) = Self.make(output)
        let clock = ContinuousClock()
        let elapsed = clock.measure { player.play(.start) }
        // The output is still "waking" (start blocks on the gate), yet the main thread is free.
        #expect(elapsed < .milliseconds(20))
        #expect(output.played.isEmpty)
        try await waitUntil { output.calls.contains(.start) }
        gate.signal()
        engine.flush()
        #expect(output.played == [.start])
        #expect(!output.calledOnMain)
    }

    @Test func nothingPlaysBeforePreload() {
        let output = FakeCueOutput()
        let engine = CueEngine(makeOutput: { output })
        let player = SoundPlayer(settings: .inMemory(), engine: engine)
        player.warmUp()
        player.play(.start)
        engine.flush()
        #expect(output.calls.isEmpty)
        #expect(player.duration(of: .start) == SoundPlayer.nominalDurations[.start])
    }

    @Test func loadedDurationsReplaceTheNominalOnes() {
        let output = FakeCueOutput()
        let (player, _) = Self.make(output)
        #expect(player.duration(of: .start) == 0.5)
        #expect(player.duration(of: .lock) == SoundPlayer.nominalDurations[.lock])
    }

    @Test func soundsOffSchedulesNothingAndWakesNothing() {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output, soundsOn: false)
        player.warmUp()
        player.play(.start)
        player.play(.paste)
        engine.flush()
        #expect(output.calls == [.load])
    }

    @Test func warmUpStartsTheOutputAndIdleReleaseStopsIt() async throws {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output, idle: 0.15)
        player.warmUp()
        engine.flush()
        #expect(output.isRunning)
        #expect(output.count(.start) == 1)
        // A cue on a running output doesn't start it again.
        player.play(.start)
        engine.flush()
        #expect(output.count(.start) == 1)
        try await waitUntil { !output.isRunning }
        #expect(output.count(.stop) == 1)
        // The next cue brings it back.
        player.play(.paste)
        engine.flush()
        #expect(output.isRunning)
        #expect(output.count(.start) == 2)
        #expect(output.played == [.start, .paste])
        #expect(!output.calledOnMain)
    }

    @Test func eachCuePushesTheIdleReleaseBack() async throws {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output, idle: 0.5)
        player.warmUp()
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(120))
            player.play(.lock)
        }
        engine.flush()
        #expect(output.isRunning)
        #expect(output.count(.stop) == 0)
        try await waitUntil { !output.isRunning }
    }

    @Test func aDictationHoldsTheOutputUntilItEnds() async throws {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output, idle: 0.1)
        player.setDictationActive(true)
        player.warmUp()
        try await Task.sleep(for: .milliseconds(300))
        engine.flush()
        #expect(output.isRunning)
        player.setDictationActive(false)
        try await waitUntil { !output.isRunning }
        #expect(output.count(.stop) == 1)
    }

    @Test func overlappingCuesAreAllScheduledWithoutStoppingEachOther() {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output)
        player.play(.start)
        player.play(.lock)
        player.play(.alert)
        player.play(.lock)
        engine.flush()
        #expect(output.played == [.start, .lock, .alert, .lock])
        #expect(output.count(.stop) == 0)
        #expect(output.count(.start) == 1)
    }

    @Test func aDeviceChangeRebuildsTheRunningOutput() async throws {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output)
        player.play(.start)
        engine.flush()
        output.simulateDeviceChange()
        try await waitUntil { output.count(.reset) == 1 && output.isRunning }
        #expect(output.count(.start) == 2)
        player.play(.stop)
        engine.flush()
        #expect(output.played == [.start, .stop])
        #expect(!output.calledOnMain)
    }

    @Test func aDeviceChangeWhileIdleRebuildsAtTheNextCue() async throws {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output, idle: 0.05)
        player.warmUp()
        try await waitUntil { output.count(.stop) == 1 }
        output.simulateDeviceChange()
        try await waitUntil { output.count(.reset) == 1 }
        engine.flush()
        #expect(!output.isRunning)
        #expect(output.count(.start) == 1)
        player.play(.paste)
        engine.flush()
        #expect(output.count(.start) == 2)
        #expect(output.played == [.paste])
    }

    @Test func aFailedStartRebuildsOnceAndNeverCrashes() {
        let once = FakeCueOutput(failingStarts: 1)
        let (player, engine) = Self.make(once)
        player.play(.start)
        engine.flush()
        #expect(once.calls == [.load, .start, .reset, .start, .play(.start)])

        let dead = FakeCueOutput(failingStarts: 10)
        let (deadPlayer, deadEngine) = Self.make(dead)
        deadPlayer.play(.start)
        deadEngine.flush()
        #expect(dead.played.isEmpty)
        #expect(dead.count(.start) == 2)
    }

    @Test func keyFeedbackCuesTooLateAreDroppedButNoticeCuesStillPlay() {
        let output = FakeCueOutput()
        let (_, engine) = Self.make(output)
        let now = DispatchTime.now().uptimeNanoseconds
        let late = now - UInt64((CueEngine.maxLateness + 0.2) * 1e9)
        engine.play(.start, requestedAt: late)
        engine.play(.error, requestedAt: late)
        engine.play(.lock, requestedAt: now)
        engine.flush()
        #expect(output.played == [.error, .lock])
    }

    @Test func conversionResamplesToTheOutputRate() throws {
        let url = try #require(AppResources.url("start", ext: SoundEffect.fileExtension, subdirectory: "Sounds"))
        let file = try AVAudioFile(forReading: url)
        let source = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: source.format.channelCount))
        let converted = try #require(AVCueOutput.convert(source, to: format))
        #expect(converted.format == format)
        let expected = Double(source.frameLength) * 44_100 / source.format.sampleRate
        #expect(abs(Double(converted.frameLength) - expected) < 64, "\(converted.frameLength) frames")
        let sameRate = try #require(AVAudioFormat(standardFormatWithSampleRate: source.format.sampleRate,
                                                   channels: source.format.channelCount))
        #expect(AVCueOutput.convert(source, to: sameRate)?.frameLength == source.frameLength)
    }
}

@MainActor
@Suite(.serialized) struct DictationCueWarmUpTests {
    static func make(_ output: FakeCueOutput) -> (DictationController, CueEngine) {
        let settings = AppSettings.inMemory()
        let meter = LevelMeter.preview(level: 0)
        let store = ModelStore.preview(states: [.parakeet: .ready], lastErrors: [:])
        let account = OpenRouterAccount.preview(status: .missing)
        let engine = CueEngine(idleRelease: 0.1, makeOutput: { output })
        let sounds = SoundPlayer(settings: settings, engine: engine)
        sounds.preload()
        let controller = DictationController(
            settings: settings, recorder: AudioRecorder(levelMeter: meter, devices: .preview()),
            transcription: TranscriptionService(models: store, account: account, client: OpenRouterClient(), settings: settings),
            models: store, account: account, history: .preview(entries: []), inserter: TextInserter(settings: settings),
            hotkeys: .preview(), permissions: .preview(mic: .granted, ax: .granted), sounds: sounds,
            pillModel: PillModel(settings: settings, levelMeter: meter), toasts: ToastCenter())
        controller.captureDevice = FakeRecorder()
        controller.copyOverride = { _ in }
        controller.runsTimers = false
        return (controller, engine)
    }

    @Test func keyDownWarmsTheOutputBeforeTheStartCue() {
        let output = FakeCueOutput()
        let (controller, engine) = Self.make(output)
        controller.send(.pttDown)
        engine.flush()
        #expect(output.isRunning)
        #expect(output.played.isEmpty)
        controller.send(.timer(.arming))
        engine.flush()
        #expect(output.played == [.start])
        #expect(output.count(.start) == 1)
        #expect(!output.calledOnMain)
    }

    @Test func aHandsFreeStartWarmsTheOutputToo() {
        let output = FakeCueOutput()
        let (controller, engine) = Self.make(output)
        controller.send(.handsFreeToggle)
        engine.flush()
        #expect(output.played == [.lock])
        #expect(output.calls.prefix(2) == [.load, .start])
    }

    @Test func theOutputStaysUpWhileRecordingAndIdlesOutAfter() async throws {
        let output = FakeCueOutput()
        let (controller, engine) = Self.make(output)
        controller.send(.handsFreeToggle)
        #expect(controller.activity == .recording)
        try await Task.sleep(for: .milliseconds(300))
        engine.flush()
        #expect(output.isRunning)
        controller.send(.pillCancel)
        try await waitUntil { !output.isRunning }
    }
}

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
        /// When each cue played (uptime ns).
        var playTimes: [UInt64] = []
        var isRunning = false
        var calledOnMain = false
        /// A device change made the graph stale and nothing has rebuilt it yet.
        var isStale = false
        /// Starts that throw before one succeeds.
        var failingStarts = 0
        /// Like AirPods nothing is playing to (false: built-in speakers).
        var wakesSlowly = false
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
    var wakesSlowly: Bool { state.withLock { $0.wakesSlowly } }
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
        _ = resetIfStale()
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

    func resetIfStale() -> Bool {
        let wasStale = state.withLock { state in
            defer { state.isStale = false }
            return state.isStale
        }
        if wasStale { reset() }
        return wasStale
    }

    func play(_ effect: SoundEffect) -> Bool {
        record(.play(effect))
        state.withLock { $0.playTimes.append(DispatchTime.now().uptimeNanoseconds) }
        return isRunning
    }

    /// What AirPods connecting (or `AVAudioEngineConfigurationChange`) does, from a CoreAudio thread.
    func simulateDeviceChange() {
        markDeviceChanged()
        DispatchQueue.global().async { self.onChange?() }
    }

    /// The first half of a change, as `AVCueOutput` does it on the notifying thread: the engine has stopped itself
    /// and the graph is stale, but `onChange` hasn't reached the engine's queue yet.
    func markDeviceChanged() {
        state.withLock {
            $0.isStale = true
            $0.isRunning = false
        }
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
        // A notice cue: it plays however long the gate holds it (a key-feedback cue would be dropped as late).
        let elapsed = clock.measure { player.play(.alert) }
        // The output is still "waking" (start blocks on the gate), yet the main thread is free.
        #expect(elapsed < .milliseconds(20))
        #expect(output.played.isEmpty)
        try await waitUntil { output.calls.contains(.start) }
        gate.signal()
        engine.flush()
        #expect(output.played == [.alert])
        #expect(!output.calledOnMain)
    }

    @Test func nothingPlaysBeforePreload() {
        let output = FakeCueOutput()
        let engine = CueEngine(makeOutput: { output })
        let player = SoundPlayer(settings: .inMemory(), engine: engine)
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
        player.captureStarting(bluetooth: false)
        player.play(.start)
        player.play(.paste)
        engine.flush()
        #expect(output.calls == [.load])
    }

    @Test func warmUpStartsTheOutputAndIdleReleaseStopsIt() async throws {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output, idle: 0.5)
        engine.warmUp()
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
        // Gaps far shorter than the idle window, adding up to more than it.
        let (player, engine) = Self.make(output, idle: 1)
        engine.warmUp()
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(300))
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
        engine.warmUp()
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
        engine.warmUp()
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

    @Test func aDeviceChangeNeverWakesAnOutputNoCueStarted() async throws {
        // "Play sounds" off: a dictation holds the engine, but nothing ever started the output.
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output, idle: 0.05, soundsOn: false)
        player.setDictationActive(true)
        output.simulateDeviceChange()
        try await waitUntil { output.count(.reset) == 1 }
        engine.flush()
        // Just after the dictation (the idle window still open).
        player.setDictationActive(false)
        output.simulateDeviceChange()
        try await waitUntil { output.count(.reset) == 2 }
        engine.flush()
        #expect(output.count(.start) == 0)
        #expect(!output.isRunning)
    }

    @Test func aCueAheadOfTheChangeNoticePlaysOnAFreshGraphThatTheNoticeKeeps() {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output)
        player.play(.start)
        engine.flush()
        // The engine stopped itself; the cue reaches the queue before `onChange` does.
        output.markDeviceChanged()
        player.play(.lock)
        engine.flush()
        #expect(output.calls.suffix(3) == [.reset, .start, .play(.lock)])
        output.onChange?()
        engine.flush()
        // The late notice finds nothing stale: no second reset cuts the cue off.
        #expect(output.count(.reset) == 1)
        #expect(output.count(.start) == 2)
        #expect(output.isRunning)
        #expect(output.played == [.start, .lock])
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

    /// AirPods take ~450 ms to wake: the cues asked for meanwhile play once they're up, as far apart as they were
    /// asked for, so fn then ⇥ is still two cues.
    @Test func cuesAskedForWhileTheOutputWakesKeepTheirSpacing() async throws {
        let gate = DispatchSemaphore(value: 0)
        let output = FakeCueOutput(startGate: gate)
        let (_, engine) = Self.make(output)
        engine.warmUp()
        try await waitUntil { output.calls.contains(.start) }
        engine.play(.start)
        try await Task.sleep(for: .milliseconds(150))
        engine.play(.modelSwitch)
        try await Task.sleep(for: .milliseconds(100))
        gate.signal()
        try await waitUntil { output.played == [.start, .modelSwitch] }
        let times = output.state.withLock { $0.playTimes }
        try #require(times.count >= 2, "a busy machine can outlast the wait: stop here, not on times[1]")
        let gap = Double(times[1] - times[0]) / 1e6
        #expect(gap >= 120, "\(gap) ms apart")
    }

    /// The start cue answers the key while the mic starts: an output that starts in a few ms plays it at once.
    @Test func aQuickOutputPlaysWhileTheMicStarts() {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output)
        player.captureStarting(bluetooth: false)
        player.play(.start)
        engine.flush()
        #expect(output.played == [.start])
        player.captureStarted()
        engine.flush()
        #expect(output.played == [.start])
    }

    /// Waking AirPods while a mic starts would hold the mic up: the cues wait for its first audio, in order.
    @Test func cuesThatWouldWakeTheOutputWaitForTheStartingMicsFirstAudio() {
        let output = FakeCueOutput()
        output.state.withLock { $0.wakesSlowly = true }
        let (player, engine) = Self.make(output)
        player.captureStarting(bluetooth: false)
        player.play(.start)
        engine.warmUp()
        player.play(.lock)
        engine.flush()
        #expect(output.calls == [.load])
        player.captureStarted()
        engine.flush()
        #expect(output.played == [.start, .lock])
        #expect(output.count(.start) == 1)
        // Once started, cues go straight to the output.
        player.play(.paste)
        engine.flush()
        #expect(output.played == [.start, .lock, .paste])
    }

    /// Already running, the output plays at once, even for AirPods.
    @Test func aRunningOutputPlaysWhileTheMicStarts() {
        let output = FakeCueOutput()
        output.state.withLock { $0.wakesSlowly = true }
        let (player, engine) = Self.make(output)
        engine.warmUp()
        engine.flush()
        player.captureStarting(bluetooth: false)
        player.play(.start)
        engine.flush()
        #expect(output.played == [.start])
    }

    /// A Bluetooth mic switches its headset to the call profile, which rebuilds the output: every cue waits.
    @Test func aBluetoothMicHoldsEveryCue() {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output)
        engine.warmUp()
        engine.flush()
        player.captureStarting(bluetooth: true)
        player.play(.start)
        engine.flush()
        #expect(output.played.isEmpty)
        player.captureStarted()
        engine.flush()
        #expect(output.played == [.start])
    }

    @Test func aMicThatNeverDeliversReleasesTheCuesAfterTheWait() async throws {
        let output = FakeCueOutput()
        let (player, engine) = Self.make(output)
        player.captureStarting(bluetooth: true)
        player.play(.lock)
        engine.flush()
        #expect(output.played.isEmpty)
        try await waitUntil { engine.flush(); return output.played == [.lock] }
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
    static func make(_ output: FakeCueOutput, idle: TimeInterval = 1) -> (DictationController, CueEngine, AudioRecorder) {
        let settings = AppSettings.inMemory()
        let meter = LevelMeter.preview(level: 0)
        let store = ModelStore.preview(states: [.parakeet: .ready], lastErrors: [:])
        let account = OpenRouterAccount.preview(status: .missing)
        let engine = CueEngine(idleRelease: idle, makeOutput: { output })
        let sounds = SoundPlayer(settings: settings, engine: engine)
        sounds.preload()
        let recorder = AudioRecorder(levelMeter: meter, devices: .preview())
        let controller = DictationController(
            settings: settings, recorder: recorder,
            transcription: TranscriptionService(models: store, account: account, client: OpenRouterClient()),
            models: store, account: account, history: .preview(entries: []), inserter: .inert(),
            hotkeys: .preview(), permissions: .preview(mic: .granted, ax: .granted), sounds: sounds,
            pillModel: PillModel(settings: settings, levelMeter: meter), toasts: ToastCenter())
        controller.captureDevice = FakeRecorder()
        controller.copyOverride = { _ in }
        controller.runsTimers = false
        // Wires the recorder's events (the mic's first audio).
        controller.start()
        return (controller, engine, recorder)
    }

    /// The start cue answers fn at once, in the key-down turn, after the pill and the mic start.
    @Test func keyDownPlaysTheStartCueAtOnce() {
        let output = FakeCueOutput()
        let (controller, engine, _) = Self.make(output)
        controller.send(.pttDown)
        engine.flush()
        #expect(output.played == [.start])
        controller.send(.timer(.arming))
        engine.flush()
        #expect(output.played == [.start], "the confirm only goes on listening")
        #expect(!output.calledOnMain)
    }

    /// AirPods asleep (~450 ms to wake, Core Audio busy meanwhile) would start the mic late: the start cue waits
    /// for its first audio.
    @Test func keyDownWaitsForTheMicBeforeWakingAirPods() {
        let output = FakeCueOutput()
        output.state.withLock { $0.wakesSlowly = true }
        let (controller, engine, recorder) = Self.make(output)
        controller.send(.pttDown)
        engine.flush()
        #expect(output.calls == [.load])
        recorder.onEvent?(.firstBuffer)
        engine.flush()
        #expect(output.played == [.start])
        #expect(output.count(.start) == 1)
    }

    @Test func aHandsFreeStartsLockCueWaitsForABluetoothMic() {
        let output = FakeCueOutput()
        let (controller, engine, recorder) = Self.make(output)
        (controller.captureDevice as? FakeRecorder)?.capturesFromBluetooth = true
        controller.send(.handsFreeToggle)
        engine.flush()
        #expect(output.calls == [.load])
        recorder.onEvent?(.firstBuffer)
        engine.flush()
        #expect(output.played == [.lock])
        #expect(output.calls.prefix(2) == [.load, .start])
    }

    /// The mic refused the press: nothing records, so no start cue (the refusal shows at the confirm).
    @Test func aRefusedPressPlaysNoStartCue() {
        let output = FakeCueOutput()
        let (controller, engine, _) = Self.make(output)
        (controller.captureDevice as? FakeRecorder)?.startError = .noMicrophone
        controller.send(.pttDown)
        engine.flush()
        #expect(output.played.isEmpty)
    }

    @Test func theOutputStaysUpWhileRecordingAndIdlesOutAfter() async throws {
        let output = FakeCueOutput()
        let (controller, engine, recorder) = Self.make(output, idle: 0.1)
        controller.send(.handsFreeToggle)
        recorder.onEvent?(.firstBuffer)
        #expect(controller.activity == .recording)
        try await Task.sleep(for: .milliseconds(300))
        engine.flush()
        #expect(output.isRunning)
        controller.send(.pillCancel)
        try await waitUntil { !output.isRunning }
    }
}

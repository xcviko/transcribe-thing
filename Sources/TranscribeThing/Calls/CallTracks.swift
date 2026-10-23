import AVFAudio
import CoreAudio
import Foundation

/// A call's mic track: a capture of its own (`CaptureSession`, nothing ducked, no level meter) on the mic dictation
/// would pick, separate from dictation's, which keeps its own (two clients of one mic are fine). Its audio is taken
/// out of the session as it comes (`takeSamples`), so an hour never piles up in memory. A mic that fails or goes
/// away is opened again every `retryAfter` seconds until the call ends; the gap stays silent on the call's clock.
///
/// While the call app has let go of the mic (`release`: Telegram muted), the capture is closed too, so nothing of this
/// app keeps the mic open and macOS can turn its mic light off. The track goes on meanwhile as digital silence, from
/// where its audio ended up to each drain: as long as if the mic had kept recording, so it stays in line with the other
/// side's. `retake` opens a mic again at once, the one a fresh start picks now (AirPods may have come or gone
/// meanwhile); a start that fails is tried again after each of `retakeBackoff`, then every `retryAfter`, for as long as
/// the call lasts.
final class MicTrackSource: CallTrackSource, @unchecked Sendable {
    static let retryAfter: TimeInterval = 5
    /// How soon a start that failed after a retake is tried again, one after another; then every `retryAfter`.
    static let retakeBackoff: [TimeInterval] = [0.2, 0.5, 1, 2]

    /// What the source asks of the system, replaceable in tests (no real mic).
    struct Hardware: Sendable {
        var isAuthorized: @Sendable () -> Bool = { AudioRecorder.isMicrophoneAuthorized }
        var defaultInputUID: @Sendable () -> String? = { CoreAudioHAL.defaultInputUID() }
        /// The devices the capture picks from and the inputs it opens.
        var capture: CaptureSession.Hardware = .live
        /// The capture's timeouts; the mic it prefers is the source's.
        var options = CaptureSession.Options()
        /// `AudioClock` time: how far the silence goes while the mic is let go.
        var clock: @Sendable () -> TimeInterval = { AudioClock.now() }
        var retryAfter: TimeInterval = MicTrackSource.retryAfter
        var retakeBackoff: [TimeInterval] = MicTrackSource.retakeBackoff

        static let live = Hardware()
    }

    private let preferredUID: String?
    private let hardware: Hardware
    private let queue = DispatchQueue(label: "dev.transcribe-thing.calls.mic", qos: .userInitiated)
    private let lock = NSLock()
    // Lock state.
    private var session: CaptureSession?
    private var pending: [TimedAudio] = []
    private var stopped = false
    private var lastProblem: String?
    /// The call app has let go of the mic, and so has this source.
    private var released = false
    /// Moves on with each open, release and retake: a retry or a session's event from before one is stale.
    private var epoch = 0
    /// `AudioClock` time just past the last sample handed over: where the track has reached. nil before any.
    private var reached: TimeInterval?
    /// A retake whose audio hasn't come yet.
    private var retaking: Retaking?

    private struct Retaking {
        /// When it was asked for.
        var since: TimeInterval
        /// The starts that failed since.
        var failures = 0
        var report: @Sendable (MicRetake) -> Void
    }

    init(preferredUID: String?, hardware: Hardware = .live) {
        self.preferredUID = preferredUID
        self.hardware = hardware
    }

    var problem: String? { lock.withLock { lastProblem } }

    func start() {
        let epoch = lock.withLock { self.epoch }
        queue.async { self.open(epoch) }
    }

    func drain() -> [TimedAudio] {
        lock.withLock {
            if let taken = session?.takeSamples() { hand(TimedAudio(samples: taken.samples, start: taken.start)) }
            if released { fillSilence(to: hardware.clock()) }
            defer { pending = [] }
            return pending
        }
    }

    func stop() {
        lock.withLock {
            // Let go to the end: silent up to now, as a mic that recorded on would be.
            if released { fillSilence(to: hardware.clock()) }
            stopped = true
            retaking = nil
            closeSession()
        }
    }

    func release() {
        let letGo = lock.withLock { () -> Bool in
            guard !stopped, !released else { return false }
            released = true
            epoch += 1
            retaking = nil
            closeSession()
            return true
        }
        if letGo { Log.audio.info("Call mic let go: the call app let go of it") }
    }

    func retake(_ report: @escaping @Sendable (MicRetake) -> Void) {
        let epoch = lock.withLock { () -> Int? in
            guard !stopped, released else { return nil }
            let now = hardware.clock()
            // Silent up to now; the new capture's audio, stamped from its first sample, goes on from there.
            fillSilence(to: now)
            released = false
            self.epoch += 1
            retaking = Retaking(since: now, report: report)
            return self.epoch
        }
        guard let epoch else { return }
        Log.audio.info("Call mic taken again: the call app took it")
        queue.async { self.open(epoch) }
    }

    // MARK: Private

    /// Opens the mic a fresh start would pick, unless a release, a retake or the stop came since `expected`.
    private func open(_ expected: Int) {
        let mine = lock.withLock { () -> Int? in
            guard !stopped, !released, epoch == expected else { return nil }
            epoch += 1
            return epoch
        }
        guard let mine else { return }
        guard hardware.isAuthorized() else { return failed(mine, "No permission to use the microphone", retry: false) }
        let records = hardware.capture.inputRecords()
        guard let choice = InputDevicePolicy.choose(preferredUID: preferredUID, defaultUID: hardware.defaultInputUID(),
                                                    devices: records.map(\.device)),
              let record = records.first(where: { $0.device.id == choice.device.id }) else {
            return failed(mine, "No microphone")
        }
        var options = hardware.options
        options.preferredUID = preferredUID
        let session = CaptureSession(device: record, options: options, meter: nil,
                                     hardware: hardware.capture) { [weak self] event in
            self?.handle(event, epoch: mine)
        }
        let opened = lock.withLock { () -> Bool in
            guard !stopped, !released, epoch == mine else { return false }
            self.session = session
            return true
        }
        guard opened else { return }
        session.start()
        Log.audio.info("Call mic capture on \(record.device.name, privacy: .public)")
    }

    private func handle(_ event: CaptureSessionEvent, epoch mine: Int) {
        let reason: String
        switch event {
        case .firstBuffer:
            let heard = lock.withLock { () -> (retaking: Retaking, at: TimeInterval)? in
                guard epoch == mine, let retaking else { return nil }
                self.retaking = nil
                return (retaking, hardware.clock())
            }
            if let heard {
                heard.retaking.report(.delivered(seconds: max(0, heard.at - heard.retaking.since),
                                                 failures: heard.retaking.failures))
            }
            return
        case .switchedDevice: return
        case .startFailed(let detail), .noAudio(let detail): reason = detail
        case .deviceLost: reason = "The microphone went away"
        }
        let current = lock.withLock { () -> Bool in
            guard epoch == mine, !stopped, !released else { return false }
            closeSession()
            return true
        }
        guard current else { return }
        Log.audio.error("Call mic capture lost: \(reason, privacy: .public)")
        failed(mine, reason)
    }

    /// Open number `mine` failed: noted, told to a retake still waiting for audio, and tried again: soon after a
    /// retake (`retakeBackoff`), every `retryAfter` otherwise.
    private func failed(_ mine: Int, _ reason: String, retry: Bool = true) {
        typealias Outcome = (delay: TimeInterval, attempt: Int, report: (@Sendable (MicRetake) -> Void)?)
        let outcome = lock.withLock { () -> Outcome? in
            guard epoch == mine, !stopped, !released else { return nil }
            lastProblem = reason
            guard var retaking else { return (hardware.retryAfter, 0, nil) }
            retaking.failures += 1
            self.retaking = retaking
            let backoff = hardware.retakeBackoff
            let delay = retaking.failures <= backoff.count ? backoff[retaking.failures - 1] : hardware.retryAfter
            return (delay, retaking.failures, retaking.report)
        }
        guard let outcome else { return }
        outcome.report?(.failed(attempt: outcome.attempt))
        guard retry else { return }
        queue.asyncAfter(deadline: .now() + outcome.delay) { [weak self] in self?.open(mine) }
    }

    /// Keeps what the session captured and lets it go. Lock held.
    private func closeSession() {
        guard let session else { return }
        if let taken = session.takeSamples() { hand(TimedAudio(samples: taken.samples, start: taken.start)) }
        let rest = session.finishNow(discard: false)
        if !rest.isEmpty { hand(TimedAudio(samples: rest, start: nil)) }
        self.session = nil
    }

    /// `audio` on its way to the journal: the track reaches past it. Lock held.
    private func hand(_ audio: TimedAudio) {
        pending.append(audio)
        let seconds = Double(audio.samples.count) / Recording.sampleRate
        if let start = audio.start {
            reached = start + seconds
        } else if let reached {
            self.reached = reached + seconds
        }
    }

    /// Digital silence from where the track has reached up to `time`; none before its first audio, so a mic that never
    /// gave any still has no track. Lock held.
    private func fillSilence(to time: TimeInterval) {
        guard let from = reached else { return }
        let count = Int(((time - from) * Recording.sampleRate).rounded(.down))
        guard count > 0 else { return }
        hand(TimedAudio(samples: [Float](repeating: 0, count: count), start: from))
    }
}

/// What a process tap takes in.
enum TapTarget: Equatable, Sendable {
    /// The sound of these HAL process objects, mixed: every process of the call app (a browser's helpers included).
    case processes([AudioObjectID])
    /// Everything the Mac plays but this app's own sounds: a manual recording.
    case everythingButThisApp
}

/// A call's other side: a CoreAudio process tap of the call app's processes (or of everything, for a manual
/// recording), mixed to mono, in a private aggregate device of its own that `HALDeviceInput` reads like any input,
/// resampled to 16 kHz. Each stretch is stamped with the host time its IO cycle carries, so the track lines up with
/// the mic's (`TrackAligner`).
///
/// It needs the "System Audio Recording Only" permission (`NSAudioCaptureUsageDescription`); macOS asks the first time
/// a tap is made. A tap that can't be made leaves `problem` and no audio: the call goes on with its mic alone. When
/// the app's processes change (Chrome starts a new helper), the tap is made again for the new set; the moment
/// between is silence on the call's clock.
final class ProcessTapSource: CallTrackSource, @unchecked Sendable {
    private let control = DispatchQueue(label: "dev.transcribe-thing.calls.tap", qos: .userInitiated)
    private let lock = NSLock()
    // Lock state.
    private var pending: [TimedAudio] = []
    private let resampler = StreamingResampler(targetSampleRate: Recording.sampleRate)
    /// When the next IO cycle should start if nothing was lost.
    private var expected: TimeInterval?
    /// The tap the IO cycles must come from: a late cycle of a torn-down one is ignored.
    private var generation = 0
    private var stopped = false
    private var lastProblem: String?
    // Control-queue state.
    private var target: TapTarget
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var input: HALDeviceInput?

    /// What the tap is for, in its name and the log: "call", or "dictation" for the echo canceller's reference.
    private let label: String

    init(target: TapTarget, label: String = "call") {
        self.target = target
        self.label = label
    }

    var problem: String? { lock.withLock { lastProblem } }

    func start() {
        control.async { self.build() }
    }

    func retarget(_ processes: [AudioObjectID]) {
        control.async {
            guard case .processes(let current) = self.target, current != processes, !processes.isEmpty else { return }
            Log.audio.info("Call tap follows \(processes.count) processes now (was \(current.count))")
            self.target = .processes(processes)
            self.teardown()
            self.build()
        }
    }

    func drain() -> [TimedAudio] {
        lock.withLock {
            defer { pending = [] }
            return pending
        }
    }

    func stop() {
        control.sync {
            lock.withLock { stopped = true }
            teardown()
        }
    }

    // MARK: Control queue

    private func build() {
        guard !lock.withLock({ stopped }) else { return }
        let description: CATapDescription
        switch target {
        case .processes(let processes):
            guard !processes.isEmpty else { return }
            description = CATapDescription(monoMixdownOfProcesses: processes)
        case .everythingButThisApp:
            let own = CoreAudioHAL.processObjectID(pid: getpid()).map { [$0] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        }
        description.uuid = UUID()
        description.name = "transcribe-thing \(label)"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            return failed("Couldn’t record the call app’s sound: no permission to record other apps’ audio (\(status))")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "transcribe-thing \(label)",
            kAudioAggregateDeviceUIDKey: "dev.transcribe-thing.\(label).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap)
            return failed("Couldn’t record the call app’s sound: no device for its tap (\(status))")
        }
        let generation = lock.withLock { () -> Int in
            self.generation += 1
            expected = nil
            return self.generation
        }
        let input = HALDeviceInput()
        do {
            try input.start(device: device, deliver: { [weak self] buffer, start in
                self?.receive(buffer, start: start, generation: generation)
            }, onChange: { [weak self] change in
                guard change == .format, let self else { return }
                self.control.async {
                    guard self.input != nil else { return }
                    self.teardown()
                    self.build()
                }
            })
        } catch {
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            return failed("Couldn’t record the call app’s sound: its tap didn’t start (\(error))")
        }
        tapID = tap
        aggregateID = device
        self.input = input
        Log.audio.info("\(self.label, privacy: .public) tap started")
    }

    private func teardown() {
        input?.stop()
        input = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        lock.withLock {
            generation += 1
            flushResampler()
            expected = nil
        }
    }

    private func failed(_ reason: String) {
        Log.audio.error("\(reason, privacy: .public)")
        lock.withLock { lastProblem = reason }
    }

    // MARK: Delivery (the input's queue)

    /// One IO cycle: a new stretch when it doesn't follow on from the last one (a gap, a new tap), else more of it.
    private func receive(_ buffer: AVAudioPCMBuffer, start: TimeInterval, generation: Int) {
        lock.withLock {
            guard generation == self.generation, !stopped else { return }
            let continues = expected.map { abs(start - $0) <= 0.004 } ?? false && resampler.isConfigured(for: buffer.format)
            if !continues {
                flushResampler()
                pending.append(TimedAudio(samples: [], start: start))
            } else if pending.isEmpty {
                // Drained since: the next stretch carries its own time, so the clocks' drift is caught up.
                pending.append(TimedAudio(samples: [], start: start))
            }
            expected = start + Double(buffer.frameLength) / buffer.format.sampleRate
            do {
                try resampler.process(buffer, into: &pending[pending.count - 1].samples)
            } catch {
                Log.audio.error("Dropped a chunk of the call app's sound the converter rejected")
            }
        }
    }

    /// What the converter still holds, onto the last stretch. Lock held.
    private func flushResampler() {
        var tail: [Float] = []
        try? resampler.flush(into: &tail)
        guard !tail.isEmpty else { return }
        if pending.isEmpty { pending.append(TimedAudio(samples: tail, start: nil)) } else { pending[pending.count - 1].samples += tail }
    }
}

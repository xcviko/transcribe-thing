import AVFAudio
import CoreAudio
import Foundation

/// A call's mic track: a capture of its own (`CaptureSession`, nothing ducked, no level meter) on the mic dictation
/// would pick, separate from dictation's, which keeps its own (two clients of one mic are fine). Its audio is taken
/// out of the session as it comes (`takeSamples`), so an hour never piles up in memory. A mic that fails or goes
/// away is opened again every `retryAfter` seconds until the call ends; the gap stays silent on the call's clock.
final class MicTrackSource: CallTrackSource, @unchecked Sendable {
    static let retryAfter: TimeInterval = 5

    private let preferredUID: String?
    private let queue = DispatchQueue(label: "dev.transcribe-thing.calls.mic", qos: .userInitiated)
    private let lock = NSLock()
    // Lock state.
    private var session: CaptureSession?
    private var pending: [TimedAudio] = []
    private var stopped = false
    private var lastProblem: String?

    init(preferredUID: String?) {
        self.preferredUID = preferredUID
    }

    var problem: String? { lock.withLock { lastProblem } }

    func start() {
        queue.async { self.open() }
    }

    func drain() -> [TimedAudio] {
        lock.withLock {
            var out = pending
            pending = []
            if let taken = session?.takeSamples() { out.append(TimedAudio(samples: taken.samples, start: taken.start)) }
            return out
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            closeSession()
        }
    }

    // MARK: Private

    private func open() {
        guard !lock.withLock({ stopped }) else { return }
        guard AudioRecorder.isMicrophoneAuthorized else {
            lock.withLock { lastProblem = "No permission to use the microphone" }
            return
        }
        let records = CoreAudioHAL.inputRecords()
        guard let choice = InputDevicePolicy.choose(preferredUID: preferredUID, defaultUID: CoreAudioHAL.defaultInputUID(),
                                                    devices: records.map(\.device)),
              let record = records.first(where: { $0.device.id == choice.device.id }) else {
            lock.withLock { lastProblem = "No microphone" }
            retryLater()
            return
        }
        let session = CaptureSession(device: record, options: CaptureSession.Options(preferredUID: preferredUID),
                                     meter: nil) { [weak self] event in self?.handle(event) }
        let opened = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            self.session = session
            return true
        }
        guard opened else { return }
        session.start()
        Log.audio.info("Call mic capture on \(record.device.name, privacy: .public)")
    }

    private func handle(_ event: CaptureSessionEvent) {
        let reason: String
        switch event {
        case .startFailed(let detail), .noAudio(let detail): reason = detail
        case .deviceLost: reason = "The microphone went away"
        case .firstBuffer, .switchedDevice: return
        }
        Log.audio.error("Call mic capture lost: \(reason, privacy: .public)")
        lock.withLock {
            lastProblem = reason
            closeSession()
        }
        retryLater()
    }

    private func retryLater() {
        queue.asyncAfter(deadline: .now() + Self.retryAfter) { [weak self] in self?.open() }
    }

    /// Keeps what the session captured and lets it go. Lock held.
    private func closeSession() {
        guard let session else { return }
        if let taken = session.takeSamples() { pending.append(TimedAudio(samples: taken.samples, start: taken.start)) }
        let rest = session.finishNow(discard: false)
        if !rest.isEmpty { pending.append(TimedAudio(samples: rest, start: nil)) }
        self.session = nil
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

    init(target: TapTarget) {
        self.target = target
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
        description.name = "transcribe-thing call"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            return failed("Couldn’t record the call app’s sound: no permission to record other apps’ audio (\(status))")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "transcribe-thing call",
            kAudioAggregateDeviceUIDKey: "dev.transcribe-thing.call.\(UUID().uuidString)",
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
        Log.audio.info("Call tap started")
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

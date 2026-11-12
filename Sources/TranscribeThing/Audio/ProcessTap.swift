import AVFAudio
import CoreAudio
import Foundation

/// A stretch of one track's audio: 16 kHz mono samples and the `AudioClock` time its first one was captured; nil
/// when it goes straight on from the stretch before.
struct TimedAudio: Equatable, Sendable {
    var samples: [Float]
    var start: TimeInterval?
}

/// Somewhere other apps' sound comes from, a stretch at a time: a process tap (`ProcessTapSource`), or a test's fake.
/// Safe from any thread.
protocol AudioTapSource: AnyObject, Sendable {
    /// Starts capturing. A source that can't capture says why in `problem` and gives no audio.
    func start()
    /// Audio captured since the last drain, oldest first.
    func drain() -> [TimedAudio]
    /// Stops capturing: a drain afterwards hands over the rest.
    func stop()
    /// Why the source has no audio or lost it, once known.
    var problem: String? { get }
}

enum ProcessTap {
    /// The UID every aggregate device the app makes starts with (`CoreAudioHAL` leaves them out of the microphones).
    static let ownDeviceUIDPrefix = "dev.transcribe-thing."
}

/// Other apps' sound: a CoreAudio process tap of everything the Mac plays but this app, mixed to mono, in a private
/// aggregate device of its own that `HALDeviceInput` reads like any input, resampled to 16 kHz: what a dictation takes
/// out of the mic (`DictationEcho`). Each stretch is stamped with the host time its IO cycle carries, so it lines up
/// with the mic's.
///
/// It needs the "System Audio Recording Only" permission (`NSAudioCaptureUsageDescription`); macOS asks the first time
/// a tap is made. A tap that can't be made leaves `problem` and no audio: the mic goes on alone.
final class ProcessTapSource: AudioTapSource, @unchecked Sendable {
    private let control = DispatchQueue(label: "dev.transcribe-thing.audio.tap", qos: .userInitiated)
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
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var input: HALDeviceInput?

    /// What the tap is for, in its name and the log: "dictation" for the echo canceller's reference.
    private let label: String

    init(label: String) {
        self.label = label
    }

    var problem: String? { lock.withLock { lastProblem } }

    func start() {
        control.async { self.build() }
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
        let own = CoreAudioHAL.processObjectID(pid: getpid()).map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        description.uuid = UUID()
        description.name = "transcribe-thing \(label)"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            return failed("Couldn’t record other apps’ sound: no permission to record other apps’ audio (\(status))")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "transcribe-thing \(label)",
            kAudioAggregateDeviceUIDKey: "\(ProcessTap.ownDeviceUIDPrefix)\(label).\(UUID().uuidString)",
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
            return failed("Couldn’t record other apps’ sound: no device for its tap (\(status))")
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
            return failed("Couldn’t record other apps’ sound: its tap didn’t start (\(error))")
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
                Log.audio.error("Dropped a chunk of other apps' sound the converter rejected")
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

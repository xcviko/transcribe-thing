import AVFoundation
import Foundation

enum AudioRecorderEvent: Sendable {
    case firstBuffer, deviceLost, configurationChanged, failed(AppError)
}

/// Dictation capture (SPEC §4.8, §5.2): 16 kHz mono Float32 from the resolved input device.
///
/// `start` resolves the device (a HAL scan, 1-3 ms on the main thread) and returns; capture opens exactly that
/// device (never the system default input unless it is the one) on a background queue, so the mic is usually hot
/// ~50-150 ms later (Bluetooth: up to 2 s, after which `.failed` fires). Levels flow into the shared `LevelMeter`. Device loss, reconfiguration and stalls are healed inside
/// the session; only a device that is gone for good surfaces as `.deviceLost` (the audio so far is kept for
/// `stop`).
@MainActor
final class AudioRecorder {
    /// Audio kept after a stop request, so the last syllable isn't clipped when the key goes up early.
    nonisolated static let stopTail: TimeInterval = 0.15
    /// Canceled recordings shorter than this are not worth an Undo.
    nonisolated static let minimumUndoDuration: TimeInterval = 0.3
    nonisolated static let duckAttenuationDB: Float = -30
    /// Added after the sound's own length: speaker latency and room decay.
    nonisolated static let duckMargin: TimeInterval = 0.05

    private let levelMeter: LevelMeter
    let devices: AudioDeviceCatalog
    private let settings: AppSettings?

    var onEvent: ((AudioRecorderEvent) -> Void)?
    /// Where each capture is kept on disk as it's recorded, until History has it (`RecordingJournal`); nil: nowhere.
    var journal: RecordingJournal?
    /// The model and mode of the dictation being recorded, for its journal: asked as a capture starts and as it ends.
    var journalLabel: (() -> (engine: EngineID, mode: DictationMachine.Mode)?)?
    private(set) var isCapturing = false
    /// Whether `start` may open the mic. The TCC probe blocks the calling thread (the main one, at key-down) for
    /// about 25 ms; the app answers from `PermissionsCenter`'s cached state first.
    var isMicrophoneAllowed: () -> Bool = { AudioRecorder.isMicrophoneAuthorized }
    /// Where a capture gets what the Mac plays, to take it out of the mic (`DictationEcho`); nil: the mic as it
    /// comes. The app sets `.live`.
    var echoSensors: DictationEcho.Sensors?
    /// The device choice of the current (or last) capture, including why it was picked.
    private(set) var lastChoice: InputDeviceChoice?
    var capturesFromBluetooth: Bool { lastChoice?.device.isBluetooth == true }

    private var session: CaptureSession?
    /// The canceled recording this capture continues (Undo): its audio comes first in what `finish`, `stop` and
    /// `cancel` return.
    private var prefix: Recording?
    private var generation = 0
    private var startedAt = Date()
    /// The id of the current (or last) capture's recording: the canceled one's it continues, or its own.
    private var recordingID = UUID()
    private var lastDeviceName: String?
    private var hasFailed = false

    init(levelMeter: LevelMeter, devices: AudioDeviceCatalog, settings: AppSettings? = nil) {
        self.levelMeter = levelMeter
        self.devices = devices
        self.settings = settings
    }

    nonisolated static var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: Capture

    /// Throws `AppError` (`.microphonePermissionDenied`, `.noMicrophone`). Later failures arrive
    /// through `onEvent`. With `prefix`, the capture continues that recording: the result starts with its audio
    /// and keeps its id and start time.
    func start(preferredDeviceUID: String?, continuing prefix: Recording? = nil) throws {
        let began = AudioClock.now()
        if let session {
            _ = session.finishNow(discard: true)
            journal?.discard(recordingID)
            endSession()
        }
        guard isMicrophoneAllowed() else { throw AppError.microphonePermissionDenied }

        let records = CoreAudioHAL.inputRecords()
        guard let choice = InputDevicePolicy.choose(preferredUID: preferredDeviceUID,
                                                    defaultUID: CoreAudioHAL.defaultInputUID(),
                                                    devices: records.map(\.device)),
              let record = records.first(where: { $0.device.id == choice.device.id })
        else { throw AppError.noMicrophone }

        generation += 1
        levelMeter.reset()
        let options = CaptureSession.Options(preferredUID: preferredDeviceUID)
        let session = CaptureSession(device: record, options: options, meter: levelMeter,
                                     echo: echoSensors.map { DictationEcho(sensors: $0) },
                                     onEvent: Self.makeEventHandler(for: self, generation: generation))
        self.session = session
        lastChoice = choice
        lastDeviceName = record.device.name
        startedAt = Date()
        recordingID = prefix?.id ?? UUID()
        self.prefix = prefix
        hasFailed = false
        isCapturing = true
        if let journal, options.keepsSamples {
            let label = journalLabel?()
            let info = RecordingJournal.Info(id: recordingID, startedAt: prefix?.startedAt ?? startedAt,
                                             engine: label?.engine.rawValue, mode: label?.mode.rawValue,
                                             deviceName: record.device.name, continues: prefix != nil)
            journal.begin(info, prefix: prefix?.samples ?? []) { [session] from in
                session.samples(from: from, keepingBack: RecordingJournal.holdBackSamples)
            }
        }
        session.start()
        // Time the main thread spent here, at key-down (the device itself starts on the session's queue).
        let blocked = (AudioClock.now() - began) * 1000
        Log.audio.info("Capture started in \(blocked, format: .fixed(precision: 1), privacy: .public) ms on \(record.device.name, privacy: .public)")
    }

    /// Stops right away and returns everything captured so far, with `SpeechStats`.
    /// Prefer `finish()`, which also keeps the 150 ms tail.
    func stop() -> Recording {
        guard let session else { return Recording(samples: []) }
        let samples = session.finishNow(discard: false)
        let prefix = prefix
        endJournal(samples)
        endSession()
        return Self.joined(prefix, makeRecording(samples, echo: session.echoReport))
    }

    /// Ends the capture after `tail` more seconds of audio (the pill can show processing at once), then
    /// returns the recording. `isCapturing` turns false immediately, so a new `start` is allowed meanwhile.
    func finish(tail: TimeInterval = AudioRecorder.stopTail) async -> Recording {
        guard let session else { return Recording(samples: []) }
        let startedAt = startedAt
        let prefix = prefix
        let name = session.device.name
        let id = recordingID
        labelJournal()
        endSession()
        let journal = journal
        let samples = await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            session.finish(tail: tail) { samples in
                // The tail too, before anyone hears of the recording.
                journal?.end(id, samples: samples)
                continuation.resume(returning: samples)
            }
        }
        // Analysis and the join (an hour of audio, or more) stay off the main thread.
        let echo = session.echoReport
        return await Task.detached(priority: .userInitiated) {
            var own = Recording(id: id, samples: samples, startedAt: startedAt,
                                speech: SpeechAnalyzer.stats(for: samples, sampleRate: Recording.sampleRate,
                                                             parts: echo?.parts ?? []),
                                deviceName: name)
            own.echo = echo
            return AudioRecorder.joined(prefix, own)
        }.value
    }

    /// Stops; returns the captured audio for Undo (with any resumed prefix), or nil when it is shorter than 0.3 s.
    func cancel() -> Recording? {
        guard let session else { return nil }
        let samples = session.finishNow(discard: false)
        let prefix = prefix
        let count = samples.count + (prefix?.samples.count ?? 0)
        guard Double(count) / Recording.sampleRate >= Self.minimumUndoDuration else {
            journal?.discard(recordingID)
            endSession()
            return nil
        }
        endJournal(samples)
        endSession()
        return Self.joined(prefix, makeRecording(samples, echo: session.echoReport))
    }

    /// `recording` after the resumed `prefix`, if any.
    nonisolated static func joined(_ prefix: Recording?, _ recording: Recording) -> Recording {
        prefix.map { $0.continued(with: recording) } ?? recording
    }

    /// Attenuates the recording by 30 dB over `[from, from + duration + 50 ms]` so a UI sound played
    /// during capture doesn't end up in the transcript. Only when the default output is the built-in
    /// speaker (headphones can't leak into the mic) and sounds are on.
    ///
    /// `from` is a monotonic timestamp (`ProcessInfo.processInfo.systemUptime`, `CACurrentMediaTime()`,
    /// `AudioClock.now()`); an offset in seconds from the start of the recording is accepted too.
    func duckRecording(from: TimeInterval, duration: TimeInterval) {
        guard let session, duration > 0 else { return }
        // No ping plays, so there is nothing to keep out; never dull the user's first words for nothing.
        if let settings, !settings.soundsEnabled { return }
        guard CoreAudioHAL.isDefaultOutputBuiltInSpeaker() else { return }
        let now = AudioClock.now()
        let start: TimeInterval
        if abs(from - now) < 30 {
            start = from
        } else if from >= 0, from <= now - session.startedAt + 30 {
            start = session.startedAt + from
        } else {
            start = now
        }
        let gain = pow(10, Self.duckAttenuationDB / 20)
        session.duck(from: start, to: start + duration + Self.duckMargin, gain: gain)
    }

    /// Ducks a sound that starts playing now.
    func duckUpcomingAudio(duration: TimeInterval) {
        duckRecording(from: AudioClock.now(), duration: duration)
    }

    var currentDeviceName: String? { session?.device.name ?? lastDeviceName }

    var currentDevice: AudioInputDevice? { session?.device }

    /// Seconds captured so far in the current session.
    var capturedDuration: TimeInterval { session?.capturedDuration ?? 0 }

    // MARK: Private

    private func endSession() {
        session = nil
        prefix = nil
        isCapturing = false
    }

    private func makeRecording(_ samples: [Float], echo: EchoCancellationReport?) -> Recording {
        var recording = Recording(id: recordingID, samples: samples, startedAt: startedAt,
                                  speech: SpeechAnalyzer.stats(for: samples, sampleRate: Recording.sampleRate,
                                                               parts: echo?.parts ?? []),
                                  deviceName: lastDeviceName)
        recording.echo = echo
        return recording
    }

    /// The journal names the model and mode the dictation ended with (Switch model, hands-free).
    private func labelJournal() {
        guard let journal, let label = journalLabel?() else { return }
        journal.label(recordingID, engine: label.engine.rawValue, mode: label.mode.rawValue)
    }

    /// The capture's journal gets the rest of its audio and is closed: it stays until History has the recording.
    private func endJournal(_ samples: [Float]) {
        labelJournal()
        journal?.end(recordingID, samples: samples)
    }

    private func handle(_ event: CaptureSessionEvent, generation: Int) {
        guard generation == self.generation, isCapturing, !hasFailed else { return }
        switch event {
        case .firstBuffer:
            if let session {
                let wait = (AudioClock.now() - session.startedAt) * 1000
                Log.audio.info("First audio \(wait, format: .fixed(precision: 0), privacy: .public) ms after start")
            }
            onEvent?(.firstBuffer)
        case .switchedDevice(let device):
            lastDeviceName = device.name
            Log.audio.info("Capture moved to \(device.name, privacy: .public)")
            onEvent?(.configurationChanged)
        case .deviceLost:
            onEvent?(.deviceLost)
        case .startFailed(let detail), .noAudio(let detail):
            hasFailed = true
            Log.audio.error("Capture failed: \(detail, privacy: .public)")
            onEvent?(.failed(.microphoneNotResponding(detail)))
        }
    }

    /// Built outside main-actor code: session events fire on CoreAudio and tap threads.
    private nonisolated static func makeEventHandler(for recorder: AudioRecorder,
                                                     generation: Int) -> @Sendable (CaptureSessionEvent) -> Void {
        { [weak recorder] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { recorder?.handle(event, generation: generation) }
            }
        }
    }
}

extension Recording {
    /// This (canceled) recording followed by `next`, as one recording that keeps this one's id and start time: a
    /// dictation resumed with Undo stays the same dictation in history, retries and Undo.
    func continued(with next: Recording) -> Recording {
        Recording(id: id, samples: samples + next.samples, startedAt: startedAt,
                  speech: SpeechStats(voicedSeconds: speech.voicedSeconds + next.speech.voicedSeconds,
                                      peakDBFS: max(speech.peakDBFS, next.speech.peakDBFS),
                                      isSilent: speech.isSilent && next.speech.isSilent),
                  deviceName: next.deviceName ?? deviceName)
            .with(echo: next.echo ?? echo)
    }

    private func with(echo: EchoCancellationReport?) -> Recording {
        var copy = self
        copy.echo = echo
        return copy
    }
}

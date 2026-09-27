import AppKit
import Observation

/// What the menu bar icon reflects.
enum DictationActivity: Equatable, Sendable { case idle, recording, processing }

/// The capture surface the controller drives. `AudioRecorder` is the real one; tests substitute a fake so
/// no microphone is ever opened.
@MainActor
protocol DictationRecorder: AnyObject {
    var isCapturing: Bool { get }
    /// `prefix`: the canceled recording this capture continues (Undo). What `finish` and `cancel` return then
    /// starts with its audio and keeps its id and start time.
    func start(preferredDeviceUID: String?, continuing prefix: Recording?) throws
    /// Ends capture after `tail` more seconds of audio; `isCapturing` turns false at once.
    func finish(tail: TimeInterval) async -> Recording
    func cancel() -> Recording?
    /// `from` is a monotonic timestamp (`systemUptime`).
    func duckRecording(from: TimeInterval, duration: TimeInterval)
}

extension AudioRecorder: DictationRecorder {}

/// Runs the dictation pipeline (SPEC §4.12): feeds hotkey/pill/recorder input into `DictationMachine`, executes
/// its effects, transcribes finished recordings concurrently and delivers the results strictly in order.
@MainActor @Observable
final class DictationController {
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private let models: ModelStore
    @ObservationIgnored private let account: OpenRouterAccount
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let inserter: TextInserter
    @ObservationIgnored private let hotkeys: HotkeyMonitor
    @ObservationIgnored private let permissions: PermissionsCenter
    @ObservationIgnored private let sounds: SoundPlayer
    @ObservationIgnored private let pillModel: PillModel
    @ObservationIgnored private let toasts: ToastCenter

    // Wiring the composition root adds after init.
    @ObservationIgnored var devices: AudioDeviceCatalog?
    @ObservationIgnored var secureInput: SecureInputMonitor?
    @ObservationIgnored var openHub: ((HubSection) -> Void)?
    @ObservationIgnored var onActivityChanged: ((DictationActivity) -> Void)?
    /// A dictation's text was just pasted where the user is typing (not paste-last, not a toast's Paste Here).
    @ObservationIgnored var onDictationDelivered: (() -> Void)?
    /// A dictation ended with the error shake (a failure, silence, no speech).
    @ObservationIgnored var onDictationFailed: (() -> Void)?
    /// The update toast's "Update".
    @ObservationIgnored var installUpdate: (() -> Void)?

    // Seams for tests: time, capture, transcription and insertion can be replaced.
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var captureDevice: any DictationRecorder
    @ObservationIgnored var transcribeOverride: (@MainActor (Recording, EngineID) async throws -> TranscriptResult)?
    @ObservationIgnored var insertOverride: (@MainActor (String, pid_t?) async -> InsertionOutcome)?
    @ObservationIgnored var copyOverride: (@MainActor (String) -> Void)?
    @ObservationIgnored var pasteNowOverride: (@MainActor (String) async -> InsertionOutcome)?
    @ObservationIgnored var pasteLastOverride: (@MainActor (String) async -> InsertionOutcome)?
    /// Replaces the OpenRouter generation lookup that fills in a delivered cloud transcript's provider.
    @ObservationIgnored var providerLookupOverride: (@MainActor (String) async -> String?)?
    /// TCC's answer right now (about 25 ms), asked only while the cached permission isn't granted.
    @ObservationIgnored var microphoneAuthorizedNow: () -> Bool = { AudioRecorder.isMicrophoneAuthorized }
    /// Replaces the sound player for the dictation cues.
    @ObservationIgnored var playCueOverride: (@MainActor (SoundEffect) -> Void)?
    /// False in tests that fire the machine's timers by hand (`send(.timer(_:))`), so none fires on its own.
    @ObservationIgnored var runsTimers = true

    private(set) var machine = DictationMachine()
    private(set) var activity: DictationActivity = .idle
    /// Recordings waiting to be transcribed or delivered, oldest first.
    private(set) var pendingJobCount = 0
    /// The shortcut's event tap has been down for longer than `shortcutNoticeGrace`: fn does nothing.
    private(set) var isShortcutUnavailable = false
    /// How long the tap may stay down before the user is told (its own retries and brief drops stay quiet).
    @ObservationIgnored var shortcutNoticeGrace: Duration = .seconds(6)

    @ObservationIgnored private var timers: [DictationMachine.TimerID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var queue: [Job] = []
    /// The job whose result is being delivered right now (it has already left `queue`).
    @ObservationIgnored private var deliveringJob: Job?
    /// A refusal found at key-down, reported only if the user commits to dictating (fn+← must stay silent).
    @ObservationIgnored private var pendingRefusal: AppError?
    /// When the last success/error flourish was requested (pill clicks during it don't start a recording).
    @ObservationIgnored private var lastFlash: (phase: PillPhase, at: TimeInterval)?
    /// A flourish that came while the pill showed a press that hasn't committed (arming, the tap window). It
    /// plays when the press folds away; a press that commits drops it, as a recording cuts one on screen.
    @ObservationIgnored private var deferredFlourish: PillPhase?
    /// The press under way began while a job was in flight: until it commits, the processing pill stays exactly
    /// as it is (its width, "Still transcribing…"), so an fn tap or an fn combo doesn't disturb it.
    @ObservationIgnored private var pressKeepsProcessing = false
    @ObservationIgnored private var retained: [UUID: Recording] = [:]
    @ObservationIgnored private var retainedOrder: [UUID] = []
    @ObservationIgnored private var lastCancelledID: UUID?
    /// The canceled recording the capture in progress continues (Undo), while that capture runs.
    @ObservationIgnored private var continuing: Recording?
    /// The recording the next `.resumeCapture` effect continues.
    @ObservationIgnored private var resumeRequest: Recording?
    /// When each failure notice (by dedupe key) last played its sound.
    @ObservationIgnored private var failureCueTimes: [String: TimeInterval] = [:]
    /// Retained recordings whose job came from the Hub: their Retry and Undo update history, never paste.
    @ObservationIgnored private var historyOnlyIDs: Set<UUID> = []
    @ObservationIgnored private var noSpeechQuota = DailyQuota(limit: 3)
    @ObservationIgnored private var historyHintQuota = DailyQuota(limit: 3)
    @ObservationIgnored private var didShowSecureInputNotice = false
    /// The mic was opened for this recording: its device notice ("Using X instead", the AirPods hint) is
    /// decided once the user commits to dictating, so fn combos and quick taps don't use it up.
    @ObservationIgnored private var deviceNoticeDue = false
    @ObservationIgnored private var announcedFallbacks: Set<String> = []
    @ObservationIgnored private var bluetoothHintQuota = DailyQuota(limit: 1)
    @ObservationIgnored private var slowNoticeIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var isStarted = false
    /// The job whose recording is being finished by the current effect batch (its stop cue waits for the tail).
    @ObservationIgnored private var finishingJob: Job?
    @ObservationIgnored private var isTapAvailable = true
    @ObservationIgnored private var shortcutNoticeTask: Task<Void, Never>?

    private static let retainedLimit = 8
    private static let undoMinimumDuration: TimeInterval = 1
    private static let saveCancelledMinimumDuration: TimeInterval = 20
    private static let minimumVoicedSeconds = 0.25
    /// The same failure again within this long updates its notice silently.
    static let repeatedFailureQuietPeriod: TimeInterval = 2
    /// What Undo does after a cancel, in the cancel notices.
    nonisolated static let undoResumesHint = "Undo keeps recording, hands-free."

    init(settings: AppSettings, recorder: AudioRecorder, transcription: TranscriptionService,
         models: ModelStore, account: OpenRouterAccount, history: HistoryStore, inserter: TextInserter,
         hotkeys: HotkeyMonitor, permissions: PermissionsCenter, sounds: SoundPlayer,
         pillModel: PillModel, toasts: ToastCenter) {
        self.settings = settings
        self.recorder = recorder
        self.transcription = transcription
        self.models = models
        self.account = account
        self.history = history
        self.inserter = inserter
        self.hotkeys = hotkeys
        self.permissions = permissions
        self.sounds = sounds
        self.pillModel = pillModel
        self.toasts = toasts
        self.captureDevice = recorder
    }

    /// Wires hotkey, pill, recorder and toast callbacks.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        recorder.onEvent = { [weak self] event in self?.handleRecorderEvent(event) }
        pillModel.onClick = { [weak self] in self?.pillClicked() }
        pillModel.onStop = { [weak self] in self?.send(.pillStop) }
        pillModel.onCancel = { [weak self] in self?.send(.pillCancel) }
        toasts.onAction = { [weak self] notice, action in self?.perform(action, from: notice) }
        toasts.onSound = { [weak self] sound in self?.playCue(sound) }
        let previous = models.onDownloadFinished
        models.onDownloadFinished = { [weak self] engine in
            previous?(engine)
            self?.downloadFinished(engine)
        }
        let previousFailure = models.onFailure
        models.onFailure = { [weak self] engine, error in
            previousFailure?(engine, error)
            self?.modelFailed(engine, error)
        }
        observeMicrophonePermission()
        stateDidChange()
    }

    /// The sticky "transcribe-thing can't hear you" toast lasts only until access is on, however it was turned on
    /// (the toast's button, the Hub, System Settings on its own).
    private func observeMicrophonePermission() {
        withObservationTracking {
            _ = permissions.microphone
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.permissions.microphone == .granted { self.dismissMicrophoneNotices() }
                self.observeMicrophonePermission()
            }
        }
    }

    private func dismissMicrophoneNotices() {
        toasts.dismiss(dedupeKey: Self.microphoneDeniedKey)
        toasts.dismiss(dedupeKey: "mic.request")
    }

    private static let microphoneDeniedKey = "error.\(AppError.microphonePermissionDenied.code)"

    // MARK: - Inputs

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .pttDown: send(.pttDown)
        case .pttUp: send(.pttUp)
        case .pttInterrupted: send(.pttInterrupted)
        case .handsFreeToggle: send(.handsFreeToggle)
        case .cancel: send(.cancel)
        case .pasteLast: pasteLast()
        }
    }

    /// The pill's click, and the menu's "Finish Dictation" while hands-free.
    func toggleHandsFree() {
        switch machine.capture {
        case .locked, .lockedStopPending: send(.pillStop)
        case .arming, .listening: send(.handsFreeToggle)
        case .idle, .tapPending: send(.pillClick)
        }
    }

    /// Discards the current recording (menu or pill X).
    func cancelCurrent() {
        send(.pillCancel)
    }

    func send(_ input: DictationMachine.Input) {
        syncConfig()
        let wasArming = machine.capture.isArming
        let wasIdle = machine.capture == .idle
        let wasRecording = machine.isRecording
        let effects = machine.handle(input, now: clock())
        if !wasRecording, machine.isRecording {
            // Every press starts in the "connecting" state: the meter still holds the last recording's levels,
            // and a refused press never opens the mic, whose start would clear them.
            pillModel.levelMeter.reset()
        }
        if !machine.capture.isUncommittedPress {
            pressKeepsProcessing = false
        } else if wasIdle {
            pressKeepsProcessing = hasPendingWork
        }
        if let refusal = pendingRefusal, wasArming, machine.isRecording, !machine.capture.isArming {
            // The user committed (arming confirmed or hands-free) but capture was refused at key-down.
            pendingRefusal = nil
            execute(machine.handle(.captureFailed(refusal), now: clock()))
        } else {
            execute(effects)
        }
        if !machine.isRecording { pendingRefusal = nil }
        stateDidChange()
    }

    private func pillClicked() {
        if let flash = lastFlash, clock() - flash.at < 1.5 {
            if flash.phase == .error, toasts.notices.isEmpty { openHub?(.home) }
            return
        }
        guard pillModel.phase != .processing else { return }
        send(.pillClick)
    }

    private func handleRecorderEvent(_ event: AudioRecorderEvent) {
        switch event {
        case .deviceLost:
            send(.deviceLost)
        case .failed(let error):
            send(.captureFailed(error))
        case .firstBuffer, .configurationChanged:
            break
        }
    }

    private func syncConfig() {
        // The limit is fixed for the recording in progress: its timers, pill and notices all use one value.
        if !machine.isRecording { machine.config.maxDuration = settings.effectiveMaxRecordingDuration }
        machine.config.doublePressEnabled = settings.doublePressForHandsFree
    }

    // MARK: - Effects

    private func execute(_ effects: [DictationMachine.Effect]) {
        defer { finishingJob = nil }
        // Esc while the only job is already being pasted: nothing to cancel, so no cancel cue either.
        var nothingCancelled = false
        for effect in effects {
            switch effect {
            case .startCapture, .resumeCapture:
                guard let failure = beginCapture(continuing: effect == .resumeCapture ? resumeRequest : nil) else {
                    continue
                }
                if machine.capture.isArming {
                    pendingRefusal = failure
                    continue
                }
                // Hands-free starts are deliberate: report right away and skip the rest of this batch
                // (no lock sound or pill for a session that never started).
                execute(machine.handle(.captureFailed(failure), now: clock()))
                return
            case .stopCaptureAndTranscribe:
                // A vanished device has no tail worth waiting for.
                finishCapture(tail: effects.contains(.notice(.deviceLostTranscribing)) ? 0 : AudioRecorder.stopTail)
            case .cancelCapture(let keepForUndo, let notify):
                cancelCapture(keepForUndo: keepForUndo, notify: notify)
            case .showPill:
                refreshPill()
            case .playSound(let sound):
                if sound == .cancel, nothingCancelled { continue }
                if sound == .stop, let job = finishingJob {
                    // Played once the tail is captured, so the cue never lands in the recording.
                    job.playsStopCue = true
                } else {
                    playCue(sound)
                }
            case .schedule(let id, let after):
                schedule(id, after: after)
            case .cancelTimer(let id):
                cancelTimer(id)
            case .cancelNewestJob:
                nothingCancelled = !cancelNewestJob()
            case .notice(let kind):
                post(kind)
            }
        }
    }

    /// Returns the reason capture can't start, or nil once the mic is live. `prefix`: the canceled recording
    /// this capture continues (Undo).
    private func beginCapture(continuing prefix: Recording? = nil) -> AppError? {
        if let refusal = captureRefusal() { return refusal }
        if captureDevice.isCapturing {
            guard prefix != nil else { return nil }
            // A stray capture would leave the kept audio out; start over with it.
            _ = captureDevice.cancel()
        }
        do {
            try captureDevice.start(preferredDeviceUID: settings.microphoneUID, continuing: prefix)
            continuing = prefix
            deviceNoticeDue = captureDevice === recorder
            // The recorder trusts the cached permission (TCC costs ~25 ms here); re-probe it off the main
            // thread, so access turned off since is refused at the next press.
            permissions.refresh()
            return nil
        } catch let error as AppError {
            return error
        } catch {
            return .microphoneNotResponding(error.localizedDescription)
        }
    }

    /// Checks made before the mic opens: permission and whether the selected engine can run at all.
    /// Downloading or loading models are fine: the job waits for them.
    func captureRefusal() -> AppError? {
        switch permissions.microphone {
        case .granted:
            break
        case .notDetermined, .denied:
            // PermissionsCenter reads TCC asynchronously (right after launch it may not know yet), and nothing
            // tells it when the user turns the mic on in System Settings while transcribe-thing stays in the background.
            guard microphoneAuthorizedNow() else { return .microphonePermissionDenied }
            permissions.refresh()
            dismissMicrophoneNotices()
        }
        let engine = settings.selectedEngine
        if engine.isLocal {
            switch models.state(of: engine) {
            case .notInstalled where !models.hasScannedDisk:
                // Launch: the first disk scan hasn't landed yet. The job waits for it.
                return nil
            case .notInstalled: return .modelNotDownloaded(engine)
            case .failed(let message):
                switch models.lastErrors[engine] {
                case .modelLoadFailed?:
                    // The files are complete: the job loads the model once more before giving up, and a
                    // failure then keeps the recording for Retry.
                    return nil
                case let error?:
                    // A failed download keeps its own error (Try Again, Manage Storage).
                    return error
                case nil:
                    return .modelLoadFailed(engine, message)
                }
            case .downloading, .installed, .preparing, .ready: return nil
            }
        }
        switch account.status {
        case .missing: return .openRouterMissingKey
        case .invalid(let message):
            // Usually final, but a single request's 401 (a brief OpenRouter outage, a key re-enabled since)
            // shouldn't block Gemini for good: check the key in the background, the next press sees the answer.
            account.refreshIfStale(maxAge: 30)
            return .openRouterInvalidKey(message)
        case .failed where account.isKeyUnreadable: return .openRouterKeyUnreadable
        case .checking, .valid, .noCredit, .offline, .failed: return nil
        }
    }

    /// Queues the job right away (FIFO order is decided at release), then waits for the recorder's tail.
    private func finishCapture(tail: TimeInterval) {
        let resumedID = continuing?.id
        continuing = nil
        guard captureDevice.isCapturing else { return }
        let delivery: Delivery = .paste(targetPID: inserter.frontmostPID())
        // A resumed dictation keeps the canceled recording's id, already while its tail is captured.
        let job = Job(recording: nil, engine: settings.selectedEngine, delivery: delivery, id: resumedID)
        queue.append(job)
        _ = machine.handle(.jobStarted, now: clock())
        finishingJob = job
        let device = captureDevice
        // Immediate: the recorder must stop counting as capturing before this returns, or a quick
        // re-press would find the mic "busy" and never start the next recording.
        Task.immediate { [weak self] in
            let recording = await device.finish(tail: tail)
            self?.captured(recording, for: job)
        }
    }

    private func captured(_ recording: Recording, for job: Job) {
        if job.isCancelled {
            // Esc during the tail: the job already left the queue and the cancel cue has played.
            keepCancelled(recording, engine: job.engine, notify: true)
            return
        }
        // A new recording may already be running (re-pressed during the tail): keep the cue out of it.
        if job.playsStopCue { playCue(.stop) }
        guard passesPreflight(recording) else {
            queue.removeAll { $0 === job }
            _ = machine.handle(.jobEnded, now: clock())
            drain()
            return
        }
        job.recording = recording
        run(job)
        stateDidChange()
    }

    /// Rejects flat or speechless recordings before any engine (or Gemini bill) sees them.
    private func passesPreflight(_ recording: Recording) -> Bool {
        if recording.speech.isSilent {
            postFailure(AppError.microphoneSilent.notice(recordingID: nil, fallbackEngine: nil))
            flash(.error)
            return false
        }
        if recording.speech.voicedSeconds < Self.minimumVoicedSeconds {
            reportNoSpeech()
            return false
        }
        return true
    }

    /// "No speech detected": an info notice without a sound (at most `noSpeechQuota` a day, unless `always`) and
    /// the pill's shake. Shared by recordings the recorder finds speechless and engines that answer with no text.
    private func reportNoSpeech(always: Bool = false) {
        if always || noSpeechQuota.take() {
            postFailure(AppError.noSpeech.notice(recordingID: nil, fallbackEngine: nil))
        }
        flash(.error)
    }

    private func cancelCapture(keepForUndo: Bool, notify: Bool) {
        // "Dictation stopped · Undo" offers this recording or nothing, never an older one still retained.
        if keepForUndo { lastCancelledID = nil }
        let resumed = continuing
        continuing = nil
        let recording = captureDevice.isCapturing ? captureDevice.cancel() : nil
        if keepForUndo {
            guard let recording else { return }
            keepCancelled(recording, engine: settings.selectedEngine, notify: notify)
        } else if let resumed {
            // A resumed dictation whose mic failed: its audio (the kept part at least) stays for another Undo.
            keepCancelled(recording ?? resumed, engine: settings.selectedEngine, notify: true)
        }
    }

    /// Keeps a canceled recording for Undo (and in history when it's long). `historyOnly`: it was a Hub
    /// transcription, which Undo transcribes after all instead of recording on.
    private func keepCancelled(_ recording: Recording, engine: EngineID, notify: Bool, historyOnly: Bool = false) {
        guard recording.duration >= Self.undoMinimumDuration else { return }
        retain(recording)
        if historyOnly { historyOnlyIDs.insert(recording.id) }
        lastCancelledID = recording.id
        let saved = recording.duration >= Self.saveCancelledMinimumDuration
        if saved {
            let file = history.saveAudio(recording)
            history.upsert(TranscriptEntry(
                id: recording.id, createdAt: recording.startedAt, text: "", engine: engine,
                status: .cancelled, audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
                audioFileName: file))
        }
        guard notify else { return }
        postCanceled(recording, saved: saved)
    }

    /// "Dictation canceled · Undo" for a kept recording. `note` replaces the line about what Undo does.
    private func postCanceled(_ recording: Recording, saved: Bool, note: String? = nil) {
        let isHubJob = historyOnlyIDs.contains(recording.id)
        var actions = [NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true)]
        var lines = [note ?? (isHubJob ? nil : Self.undoResumesHint)]
        if saved {
            let days = settings.keepFailedRecordingsDays
            if days > 0 { lines.append("Saved in History for \(days) \(days == 1 ? "day" : "days").") }
            if note == nil, historyHintQuota.take() {
                actions.append(NoticeAction(title: "Open History", kind: .openHub(.home)))
            }
        }
        let body = lines.compactMap { $0 }.joined(separator: " ")
        toasts.post(Notice(dedupeKey: "dictation.canceled", style: .info, symbol: "xmark.circle",
                           title: isHubJob ? "Transcription canceled" : "Dictation canceled",
                           body: body.isEmpty ? nil : body, actions: actions,
                           lifetime: .seconds(note == nil ? 6 : 10), recordingID: recording.id))
    }

    /// Posts a failure notice; the same failure again within `repeatedFailureQuietPeriod` of its last sound
    /// replaces the notice without replaying the sound.
    private func postFailure(_ notice: Notice) {
        var notice = notice
        if notice.sound != nil {
            let now = clock()
            if let last = failureCueTimes[notice.dedupeKey], now - last < Self.repeatedFailureQuietPeriod {
                notice.sound = nil
            } else {
                failureCueTimes[notice.dedupeKey] = now
            }
        }
        toasts.post(notice)
    }

    private func playCue(_ sound: SoundEffect) {
        if let playCueOverride { playCueOverride(sound) } else { sounds.play(sound) }
        // Cues that play while the mic is open (start/lock pings, a "1 minute left" alert) stay out of
        // what the engine hears.
        guard captureDevice.isCapturing else { return }
        captureDevice.duckRecording(from: ProcessInfo.processInfo.systemUptime, duration: sounds.duration(of: sound))
    }

    /// Row 4 (selected mic unavailable) and row 10 (Bluetooth mic in use) of the error catalog.
    private func deviceNotice(for choice: InputDeviceChoice?) -> Notice? {
        guard let choice else { return nil }
        switch choice.reason {
        case .fallback(let missingUID):
            let key = missingUID ?? "default"
            guard !announcedFallbacks.contains(key) else { return nil }
            announcedFallbacks.insert(key)
            let missing = missingUID.flatMap { devices?.device(uid: $0)?.name } ?? "Your microphone"
            return Notice(dedupeKey: "mic.fallback", style: .warning, symbol: "mic.badge.xmark",
                          title: "Using \(choice.device.name) instead",
                          body: "\(missing) isn’t available right now.",
                          actions: [NoticeAction(title: "Choose Mic", kind: .chooseMicrophone, isPrimary: true)],
                          lifetime: .seconds(8), sound: .alert)
        case .selected, .systemDefault:
            guard choice.device.isBluetooth, devices?.builtInDevice?.isAvailable == true,
                  bluetoothHintQuota.take() else { return nil }
            return Notice(dedupeKey: "mic.bluetooth", style: .info, symbol: "airpods",
                          title: "AirPods aren’t great for dictation",
                          body: "The built-in mic starts faster and catches more words.",
                          actions: [NoticeAction(title: "Use Built-in Mic", kind: .useBuiltInMicrophone, isPrimary: true)],
                          lifetime: .seconds(10), sound: .alert)
        case .builtInInsteadOfBluetooth:
            return nil
        }
    }

    // MARK: - Timers

    private func schedule(_ id: DictationMachine.TimerID, after delay: TimeInterval) {
        cancelTimer(id)
        guard runsTimers else { return }
        let token = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled, let self, self.timers[id]?.token == token else { return }
            self.timers[id] = nil
            self.timerFired(id)
        }
        timers[id] = (token, task)
    }

    private func cancelTimer(_ id: DictationMachine.TimerID) {
        timers.removeValue(forKey: id)?.task.cancel()
    }

    private func timerFired(_ id: DictationMachine.TimerID) {
        send(.timer(id))
    }

    // MARK: - Jobs (concurrent transcription, FIFO delivery)

    enum Delivery: Equatable {
        /// Paste at the cursor; `targetPID` is the app that was frontmost when recording stopped.
        case paste(targetPID: pid_t?)
        /// Hub retries: update history only.
        case historyOnly
    }

    fileprivate enum Outcome {
        case success(TranscriptResult)
        case failure(AppError)
    }

    @MainActor
    fileprivate final class Job {
        /// nil while the recorder is still capturing the tail.
        var recording: Recording?
        var engine: EngineID
        let delivery: Delivery
        var outcome: Outcome?
        var task: Task<Void, Never>?
        var hintTask: Task<Void, Never>?
        var generation = 0
        var playsStopCue = false
        var isCancelled = false
        private let placeholderID: UUID

        /// `id`: the id the recording will have (a resumed dictation's), when it is known before the audio is.
        init(recording: Recording?, engine: EngineID, delivery: Delivery, id: UUID? = nil) {
            self.recording = recording
            self.engine = engine
            self.delivery = delivery
            self.placeholderID = id ?? UUID()
        }

        /// The recording's id once it exists (history, retry and undo all key on it).
        var id: UUID { recording?.id ?? placeholderID }

        func stop() {
            task?.cancel()
            hintTask?.cancel()
        }
    }

    /// Starts transcribing right away; the result is delivered after every older job's. A recording that is
    /// already queued, being delivered or being recorded on is never queued twice.
    func enqueue(_ recording: Recording, engine: EngineID, delivery: Delivery) {
        guard !isInFlight(recording.id) else { return }
        let job = Job(recording: recording, engine: engine, delivery: delivery)
        queue.append(job)
        _ = machine.handle(.jobStarted, now: clock())
        run(job)
        stateDidChange()
    }

    private func run(_ job: Job) {
        guard let recording = job.recording else { return }
        job.stop()
        job.generation += 1
        job.outcome = nil
        let generation = job.generation
        let engine = job.engine
        job.task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.transcribe(recording, engine: engine)
            guard !Task.isCancelled, job.generation == generation else { return }
            job.outcome = outcome
            job.hintTask?.cancel()
            self.dismissSlowNotice(for: job.id)
            self.drain()
        }
        let hintDelay = Self.slowNoticeDelay(for: engine)
        job.hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hintDelay))
            guard !Task.isCancelled, let self, job.outcome == nil, job.generation == generation else { return }
            self.postSlowNotice(for: job)
        }
    }

    private func transcribe(_ recording: Recording, engine: EngineID) async -> Outcome {
        do {
            if engine.isLocal, transcribeOverride == nil { try await waitForLocalModel(engine) }
            let result: TranscriptResult
            if let transcribeOverride {
                result = try await transcribeOverride(recording, engine)
            } else {
                result = try await transcription.transcribe(recording, engine: engine)
            }
            return .success(result)
        } catch let error as AppError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.engineFailed(engine, "Canceled"))
        } catch {
            return .failure(.engineFailed(engine, error.localizedDescription))
        }
    }

    /// How long a job may run before "taking longer than usual".
    nonisolated static func slowNoticeDelay(for engine: EngineID) -> TimeInterval {
        switch engine.cloudAPI {
        case nil: 3
        case .transcriptions: 10
        case .chatCompletions: 12
        }
    }

    /// A model still downloading can't transcribe yet: wait for it (Esc cancels the job).
    private func waitForLocalModel(_ engine: EngineID) async throws {
        while true {
            try Task.checkCancellation()
            // Right after launch every model reads as not installed until the first disk scan lands.
            guard models.hasScannedDisk else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            switch models.state(of: engine) {
            case .downloading:
                try await Task.sleep(for: .milliseconds(300))
            case .installed:
                if engine == settings.selectedEngine { models.prepare(engine) }
                return
            case .notInstalled:
                throw AppError.modelNotDownloaded(engine)
            case .preparing, .ready, .failed:
                return
            }
        }
    }

    private func drain() {
        defer { stateDidChange() }
        guard !isDelivering, let head = queue.first, let outcome = head.outcome else { return }
        deliveringJob = head
        queue.removeFirst()
        Task { [weak self] in
            guard let self else { return }
            await self.deliver(head, outcome)
            self.deliveringJob = nil
            _ = self.machine.handle(.jobEnded, now: self.clock())
            self.drain()
        }
    }

    private var isDelivering: Bool { deliveringJob != nil }

    /// Queued, being delivered, or being recorded on again (Undo).
    private func isInFlight(_ id: UUID) -> Bool {
        queue.contains { $0.id == id } || deliveringJob?.id == id || continuing?.id == id
    }

    /// False when there was nothing left to cancel (the last result is already being delivered).
    @discardableResult
    private func cancelNewestJob() -> Bool {
        guard let job = queue.last else { return false }
        queue.removeLast()
        job.stop()
        job.isCancelled = true
        dismissSlowNotice(for: job.id)
        _ = machine.handle(.jobEnded, now: clock())
        if let recording = job.recording {
            keepCancelled(recording, engine: job.engine, notify: true, historyOnly: job.delivery == .historyOnly)
        }
        drain()
        return true
    }

    private func deliver(_ job: Job, _ outcome: Outcome) async {
        guard let recording = job.recording else { return }
        switch outcome {
        case .failure(.noSpeech):
            deliverSilence(job)
        case .failure(let error):
            deliverFailure(job, error)
        case .success(let result):
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The engine answered and heard nothing: the user was silent. Not an error.
            guard !text.isEmpty else {
                deliverSilence(job)
                return
            }
            forget(job.id)
            history.upsert(TranscriptEntry(
                id: job.id, createdAt: recording.startedAt, text: text, engine: result.engine,
                status: .success, audioDuration: recording.duration,
                voicedSeconds: recording.speech.voicedSeconds,
                processingTime: result.processingTime, costUSD: result.costUSD, provider: result.provider))
            if result.provider == nil, let generationID = result.generationID {
                resolveProvider(entryID: job.id, generationID: generationID, engine: result.engine, text: text)
            }
            switch job.delivery {
            case .historyOnly:
                toasts.post(Notice(dedupeKey: "retry.\(job.id)", style: .success, symbol: "checkmark.circle.fill",
                                   title: "Transcribed with \(result.engine.shortName)",
                                   body: "It’s in your history.",
                                   actions: [NoticeAction(title: "Copy", kind: .copyText(text), isPrimary: true)],
                                   lifetime: .seconds(5)))
            case .paste(let target):
                let insertion = await insert(text, expectedPID: target)
                handleInsertion(insertion, text: text, celebrate: true)
            }
        }
    }

    /// Asks OpenRouter who served a delivered cloud transcript, in the background, and records it on the history
    /// entry, unless the entry changed meanwhile (deleted, or retried with another engine).
    private func resolveProvider(entryID: UUID, generationID: String, engine: EngineID, text: String) {
        Task { [weak self] in
            guard let self else { return }
            let name: String?
            if let override = self.providerLookupOverride {
                name = await override(generationID)
            } else {
                name = await self.transcription.servedProvider(generationID: generationID)
            }
            guard let name, var entry = self.history.entry(id: entryID), entry.status == .success,
                  entry.engine == engine, entry.text == text, entry.provider == nil else { return }
            entry.provider = name
            self.history.upsert(entry)
        }
    }

    /// A recording that turned out to be silence leaves nothing behind: no history entry, no kept audio, no
    /// Retry. One that already had a failed or canceled row (a retry, a resumed dictation) takes the row and its
    /// audio along, and always gets the notice, so a row never vanishes without a word.
    private func deliverSilence(_ job: Job) {
        forget(job.id)
        let hadRow = history.entry(id: job.id).map { $0.status != .success } ?? false
        if hadRow { history.delete(job.id) }
        Log.engine.info("No speech from \(job.engine.rawValue, privacy: .public)")
        reportNoSpeech(always: hadRow)
    }

    private func deliverFailure(_ job: Job, _ error: AppError) {
        guard let recording = job.recording else { return }
        let file = history.saveAudio(recording)
        retain(recording)
        if job.delivery == .historyOnly { historyOnlyIDs.insert(job.id) }
        // A downloaded model that isn't loaded yet loads for the retry, so it counts too.
        let fallback = usableFallback(excluding: job.engine, after: error)
        let notice = error.notice(recordingID: job.id, fallbackEngine: fallback, engine: job.engine)
        history.upsert(TranscriptEntry(
            id: job.id, createdAt: recording.startedAt, text: "", engine: job.engine, status: .failed,
            audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
            errorMessage: notice.title, audioFileName: file ?? history.entry(id: job.id)?.audioFileName))
        Log.engine.error("Transcription failed: \(error.code, privacy: .public)")
        postFailure(notice)
        flash(.error)
    }

    // MARK: - Insertion

    private func insert(_ text: String, expectedPID: pid_t?) async -> InsertionOutcome {
        if let insertOverride { return await insertOverride(text, expectedPID) }
        return await inserter.insert(text, expectedPID: expectedPID)
    }

    private func copy(_ text: String) {
        if let copyOverride { copyOverride(text) } else { inserter.copy(text) }
    }

    private func handleInsertion(_ outcome: InsertionOutcome, text: String, celebrate: Bool) {
        Log.app.notice("Insertion outcome: \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .pasted:
            // A paste landing mid-recording must not leak its tick into the new recording.
            if !machine.isRecording { sounds.play(.paste) }
            if celebrate {
                flash(.success)
                onDictationDelivered?()
            }
        case .noEditableTarget:
            toasts.post(transcriptCard(text, title: "Nowhere to paste",
                                       body: "Or click a text field and press \(pasteLastHint).", pasteHere: false))
        case .targetChanged:
            toasts.post(transcriptCard(text, title: "You switched apps", body: "Paste here, or copy it.", pasteHere: true))
        case .accessibilityMissing:
            copy(text)
            var notice = AppError.accessibilityMissing.notice(recordingID: nil, fallbackEngine: nil)
            notice.transcript = text
            notice.actions = [NoticeAction(title: "Allow Access", kind: .openSettingsPane(.accessibility), isPrimary: true),
                              NoticeAction(title: "Copy Again", kind: .copyText(text))]
            toasts.post(notice)
        case .failed(let reason):
            Log.app.error("Paste failed: \(reason, privacy: .public)")
            toasts.post(transcriptCard(text, title: "Couldn’t paste", body: "Copy it, or try pasting again.", pasteHere: true))
        }
    }

    private func transcriptCard(_ text: String, title: String, body: String, pasteHere: Bool) -> Notice {
        var actions: [NoticeAction] = []
        if pasteHere { actions.append(NoticeAction(title: "Paste Here", kind: .pasteText(text), isPrimary: true)) }
        actions.append(NoticeAction(title: "Copy", kind: .copyText(text), isPrimary: !pasteHere))
        return Notice(dedupeKey: "transcript.\(text.hashValue)", style: .info, symbol: "doc.on.clipboard",
                      title: title, body: body, transcript: text, actions: actions, lifetime: .seconds(20))
    }

    private var pasteLastHint: String {
        settings.shortcuts[.pasteLast]?.compactDescription ?? "⌘ fn V"
    }

    // MARK: - Paste last

    /// Copy and paste in one: the last transcript goes on the clipboard (it stays there even with "Restore the
    /// clipboard after pasting" on) and is pasted where the user is typing, if anywhere.
    func pasteLast() {
        guard let text = history.lastSuccessfulText else {
            toasts.post(Notice(dedupeKey: "pasteLast.empty", style: .info, symbol: "text.badge.xmark",
                               title: "Nothing to paste yet", body: "Dictate something first.", lifetime: .seconds(3)))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome: InsertionOutcome
            if let override = self.pasteLastOverride {
                outcome = await override(text)
            } else {
                outcome = await self.inserter.insert(text, expectedPID: nil, keepOnClipboard: true)
            }
            switch outcome {
            case .pasted, .accessibilityMissing:
                // Without Accessibility the inserter has already copied it, and the notice says so.
                self.handleInsertion(outcome, text: text, celebrate: false)
            case .noEditableTarget, .targetChanged:
                self.leaveOnClipboard(text, title: "Nowhere to paste")
            case .failed(let reason):
                Log.app.error("Paste last failed: \(reason, privacy: .public)")
                self.leaveOnClipboard(text, title: "Couldn’t paste")
            }
        }
    }

    /// Paste last's "copy" half when the paste can't happen.
    private func leaveOnClipboard(_ text: String, title: String) {
        copy(text)
        toasts.post(Notice(dedupeKey: "pasteLast.copied", style: .info, symbol: "doc.on.clipboard",
                           title: title, body: "Your text is on the clipboard.", lifetime: .seconds(3)))
    }

    // MARK: - Notice actions

    func perform(_ action: NoticeAction, from notice: Notice) {
        switch action.kind {
        case .copyText(let text):
            copy(text)
            return
        case .pasteText(let text):
            toasts.dismiss(notice.id)
            Task { [weak self] in
                guard let self else { return }
                let outcome: InsertionOutcome
                if let override = self.pasteNowOverride {
                    outcome = await override(text)
                } else {
                    outcome = await self.inserter.pasteNow(text)
                }
                // Anything but a paste brings the text back (a card, or the Accessibility notice).
                self.handleInsertion(outcome, text: text, celebrate: false)
            }
            return
        default:
            break
        }
        toasts.dismiss(notice.id)
        switch action.kind {
        case .openSettingsPane(.accessibility) where permissions.accessibility != .granted:
            // The first request shows the system prompt, which also adds transcribe-thing to the list; later ones open
            // the pane. Both watch for the grant.
            permissions.requestAccessibility()
        case .openSettingsPane(let pane):
            permissions.open(pane)
        case .openHub(let section):
            openHub?(section)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .download(let engine):
            startDownload(engine)
        case .retry:
            retry(recordingID: notice.recordingID, engine: nil)
        case .retryWith(let engine):
            retry(recordingID: notice.recordingID, engine: engine)
        case .selectEngine(let engine):
            models.select(engine)
            toasts.post(Notice(dedupeKey: "engine.selected", style: .success, symbol: engine.symbolName,
                               title: "Now using \(engine.displayName)", lifetime: .seconds(3)))
        case .undoCancel:
            undo(recordingID: notice.recordingID ?? lastCancelledID)
        case .chooseMicrophone:
            openHub?(.microphone)
        case .useBuiltInMicrophone:
            useBuiltInMicrophone()
        case .installUpdate:
            installUpdate?()
        case .dismiss, .copyText, .pasteText:
            break
        }
    }

    /// Hub history "Retry" (failed or canceled rows) with any engine.
    func retry(_ entry: TranscriptEntry, with engine: EngineID) {
        guard !isInFlight(entry.id) else { return }
        guard let recording = recording(for: entry.id) else {
            postRecordingGone()
            return
        }
        enqueue(recording, engine: engine, delivery: .historyOnly)
    }

    private func retry(recordingID: UUID?, engine: EngineID?) {
        guard let id = recordingID else { return }
        if let waiting = queue.first(where: { $0.id == id }) {
            // Still in the queue ("Use Parakeet v3 · Cloud Instead" while Parakeet loads): switch engines in place.
            if let engine, engine != waiting.engine, waiting.outcome == nil {
                waiting.engine = engine
                run(waiting)
            }
            return
        }
        guard !isInFlight(id) else { return }
        guard let recording = recording(for: id) else {
            postRecordingGone()
            return
        }
        let chosen = engine ?? history.entry(id: id)?.engine ?? settings.selectedEngine
        enqueue(recording, engine: chosen, delivery: redeliveryTarget(for: id))
    }

    /// Where a retried or undone recording goes: back to history for Hub jobs, else the cursor now.
    private func redeliveryTarget(for id: UUID) -> Delivery {
        historyOnlyIDs.contains(id) ? .historyOnly : .paste(targetPID: inserter.frontmostPID())
    }

    /// Undo of a cancel: the dictation picks up again hands-free, its kept audio first, and nothing is transcribed
    /// or pasted until the user stops (Esc cancels it again, all of it). A canceled Hub transcription is
    /// transcribed after all, into history.
    private func undo(recordingID: UUID?) {
        guard let id = recordingID, let recording = recording(for: id) else {
            postRecordingGone()
            return
        }
        if historyOnlyIDs.contains(id) {
            enqueue(recording, engine: settings.selectedEngine, delivery: .historyOnly)
            return
        }
        // Already being transcribed (a Hub retry of it) or recorded on.
        guard !isInFlight(id) else { return }
        let saved = history.entry(id: id)?.status == .cancelled
        guard !machine.isRecording else {
            postCanceled(recording, saved: saved, note: "Finish this dictation first, then Undo.")
            return
        }
        resumeRequest = recording
        send(.resume(prefix: recording.duration))
        resumeRequest = nil
        if continuing?.id != id {
            // The mic didn't start (its error is showing): the audio stays for another Undo.
            postCanceled(recording, saved: saved, note: Self.undoResumesHint)
        }
    }

    private func startDownload(_ engine: EngineID) {
        models.download(engine)
        let size = engine.approxDownloadBytes.map { "About \(Fmt.bytes($0)). " } ?? ""
        toasts.post(Notice(dedupeKey: "download.\(engine.rawValue)", style: .info, symbol: "arrow.down.circle",
                           title: "Downloading \(engine.displayName)",
                           body: "\(size)You’ll get a notice when it’s ready.",
                           actions: [NoticeAction(title: "Show Progress", kind: .openHub(.models), isPrimary: true)],
                           lifetime: .seconds(6)))
    }

    private func downloadFinished(_ engine: EngineID) {
        toasts.post(Notice(dedupeKey: "download.\(engine.rawValue)", style: .success, symbol: "checkmark.circle.fill",
                           title: "\(engine.displayName) is ready",
                           body: engine == settings.selectedEngine ? "Hold \(pttHint) and start talking." : nil,
                           lifetime: .seconds(5), sound: .success))
    }

    /// Downloads and loads run in the background (often after the window that started them closed), so
    /// their failures surface as notices. A failed dictation's notice for the same error shares the dedupe key.
    private func modelFailed(_ engine: EngineID, _ error: AppError) {
        if case .modelLoadFailed = error, engine != settings.selectedEngine { return }
        postFailure(error.notice(recordingID: nil, fallbackEngine: usableFallback(excluding: engine, after: error),
                                 engine: engine))
    }

    private func useBuiltInMicrophone() {
        guard let builtIn = devices?.devices.first(where: { $0.transport == .builtIn && $0.isAvailable }) else {
            openHub?(.microphone)
            return
        }
        settings.microphoneUID = builtIn.id
        toasts.post(Notice(dedupeKey: "mic.switched", style: .success, symbol: "laptopcomputer",
                           title: "Using \(builtIn.name)", lifetime: .seconds(3)))
    }

    private func postRecordingGone() {
        toasts.post(Notice(dedupeKey: "recording.gone", style: .warning, symbol: "waveform.slash",
                           title: "That recording is gone",
                           body: "\(Brand.name) keeps audio only for failed or canceled dictations, and only for a while.",
                           lifetime: .seconds(5), sound: .alert))
    }

    // MARK: - Machine notices

    private func post(_ kind: DictationMachine.NoticeKind) {
        let minutes = Int((machine.config.maxDuration / 60).rounded())
        switch kind {
        case .oneMinuteLeft:
            toasts.post(Notice(dedupeKey: "limit", style: .warning, symbol: "timer", title: "1 minute left",
                               body: "Recording stops at \(minutes) min and gets transcribed.",
                               lifetime: .seconds(6), sound: .alert))
        case .limitReached:
            finishingJob?.playsStopCue = true
            toasts.post(Notice(dedupeKey: "limit", style: .info, symbol: "timer",
                               title: "Reached the \(minutes)-minute limit",
                               body: "Transcribing everything so far. Start again anytime.",
                               lifetime: .seconds(5), sound: finishingJob == nil ? .stop : nil))
        case .stoppedByOtherKey:
            guard let id = lastCancelledID, retained[id] != nil else { return }
            toasts.post(Notice(dedupeKey: "dictation.canceled", style: .info, symbol: "keyboard",
                               title: "Dictation stopped",
                               body: "You pressed another key while holding \(pttHint). \(Self.undoResumesHint)",
                               actions: [NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true)],
                               lifetime: .seconds(6), recordingID: id))
        case .deviceLostTranscribing:
            toasts.post(Notice(dedupeKey: "mic.lost", style: .warning, symbol: "mic.slash.fill",
                               title: "Microphone disconnected",
                               body: "\(Brand.name) is transcribing what you said up to that point.",
                               actions: [NoticeAction(title: "Choose Mic", kind: .chooseMicrophone)],
                               lifetime: .seconds(8), sound: .alert))
        case .captureFailed(let error):
            reportCaptureFailure(error)
        }
    }

    private func reportCaptureFailure(_ error: AppError) {
        if error == .microphonePermissionDenied, permissions.microphone == .notDetermined {
            let permissions = permissions
            Task { _ = await permissions.requestMicrophone() }
            toasts.post(Notice(dedupeKey: "mic.request", style: .info, symbol: "mic.fill",
                               title: "Allow microphone access",
                               body: "Choose Allow in the macOS prompt, then try again.",
                               lifetime: .seconds(8)))
        } else {
            let engine = settings.selectedEngine
            postFailure(error.notice(recordingID: nil, fallbackEngine: usableFallback(excluding: engine, after: error),
                                     engine: engine))
        }
        flash(.error)
    }

    private func postSlowNotice(for job: Job) {
        var fallback = usableFallback(excluding: job.engine)
        var notice: Notice
        switch models.state(of: job.engine) {
        case .downloading(let progress) where job.engine.isLocal:
            notice = AppError.modelDownloading(job.engine, progress.fraction).notice(recordingID: nil, fallbackEngine: nil)
        case .preparing where job.engine.isLocal, .installed where job.engine.isLocal:
            // Only an engine that can start right now is any faster than waiting for this load.
            fallback = readyFallback(excluding: job.engine)
            notice = AppError.modelPreparing(job.engine).notice(recordingID: nil, fallbackEngine: nil)
        default:
            guard job.engine.isCloud else { return }
            notice = Notice(dedupeKey: "slow", style: .info, symbol: "hourglass",
                            title: "\(job.engine.shortName) is taking longer than usual",
                            body: "Keep waiting, or press \(cancelHint) to cancel.", lifetime: .seconds(10))
        }
        notice.dedupeKey = "slow.\(job.id)"
        notice.recordingID = job.id
        notice.lifetime = .sticky
        notice.actions = fallback.map {
            [NoticeAction(title: "Use \($0.shortName) Instead", kind: .retryWith($0), isPrimary: true)]
        } ?? []
        slowNoticeIDs[job.id] = notice.id
        toasts.post(notice)
    }

    private func dismissSlowNotice(for jobID: UUID) {
        guard let id = slowNoticeIDs.removeValue(forKey: jobID) else { return }
        toasts.dismiss(id)
    }

    // MARK: - Shortcut availability

    /// The event tap came up or went down. Down for longer than a brief drop, it becomes a sticky notice
    /// (after onboarding, which explains Accessibility itself) and a Hub card; up again, both go away.
    func shortcutAvailabilityChanged(_ available: Bool) {
        guard available != isTapAvailable else { return }
        isTapAvailable = available
        shortcutNoticeTask?.cancel()
        shortcutNoticeTask = nil
        if available {
            if isShortcutUnavailable { isShortcutUnavailable = false }
            toasts.dismiss(dedupeKey: Notice.shortcutUnavailableKey)
            return
        }
        let grace = shortcutNoticeGrace
        shortcutNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, !self.isTapAvailable else { return }
            self.shortcutNoticeTask = nil
            self.isShortcutUnavailable = true
            guard self.settings.onboardingCompleted else { return }
            self.toasts.post(.shortcutUnavailable(accessibility: self.permissions.accessibility,
                                                  likelyStale: self.permissions.accessibilityLikelyStale,
                                                  shortcut: self.pttHint))
        }
    }

    private func showSecureInputNoticeIfNeeded() {
        guard !didShowSecureInputNotice, let secureInput, secureInput.isActive,
              machine.capture.isListeningOrLocked else { return }
        didShowSecureInputNotice = true
        let owner = secureInput.owningAppName.map { " in \($0)" } ?? ""
        let handsFree = settings.shortcuts[.handsFree]?.compactDescription ?? "fn space"
        toasts.post(Notice(dedupeKey: "secureInput", style: .warning, symbol: "lock.shield",
                           title: "Secure typing is on\(owner)",
                           body: "Holding \(pttHint) still works. \(handsFree) and \(cancelHint) work again once it’s off.",
                           actions: [NoticeAction(title: "Dismiss", kind: .dismiss)],
                           lifetime: .seconds(10), sound: .alert))
    }

    private var pttHint: String { settings.shortcuts[.pushToTalk]?.compactDescription ?? "fn" }
    private var cancelHint: String { settings.shortcuts[.cancel]?.compactDescription ?? "esc" }

    // MARK: - Engines and recordings

    /// Engines to fall back to from `engine`, in order: the same model on the other side (Parakeet · Cloud ↔
    /// Parakeet on this Mac), then Parakeet on this Mac, then Parakeet · Cloud (Gemini's fallbacks).
    static func fallbackCandidates(for engine: EngineID) -> [EngineID] {
        let ordered = [engine.localCounterpart, engine.cloudCounterpart].compactMap { $0 }
            + EngineID.localEngines + EngineID.cloudTranscriptionEngines
        var candidates: [EngineID] = []
        for candidate in ordered where candidate != engine && !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    /// An engine other than `engine` that can start at once, offered as "Retry with …" for a saved recording: a
    /// loaded local model, or a cloud one while the key is valid, unless `error` (the key's, the credit's, the
    /// connection's) would stop it too.
    private func readyFallback(excluding engine: EngineID, after error: AppError? = nil) -> EngineID? {
        Self.fallbackCandidates(for: engine).first { candidate in
            if candidate.isLocal { return models.state(of: candidate) == .ready }
            guard case .valid = account.status else { return false }
            return error?.stopsEveryCloudModel != true
        }
    }

    /// `readyFallback`, else a downloaded local model that isn't loaded yet (it loads for the retry), also
    /// offered as "Use …" when nothing was recorded.
    private func usableFallback(excluding engine: EngineID, after error: AppError? = nil) -> EngineID? {
        readyFallback(excluding: engine, after: error) ?? Self.fallbackCandidates(for: engine).first {
            guard $0.isLocal else { return false }
            switch models.state(of: $0) {
            case .installed, .preparing: return true
            default: return false
            }
        }
    }

    private func retain(_ recording: Recording) {
        retained[recording.id] = recording
        retainedOrder.removeAll { $0 == recording.id }
        retainedOrder.append(recording.id)
        while retainedOrder.count > Self.retainedLimit {
            let evicted = retainedOrder.removeFirst()
            retained[evicted] = nil
            historyOnlyIDs.remove(evicted)
        }
    }

    private func forget(_ id: UUID) {
        retained[id] = nil
        retainedOrder.removeAll { $0 == id }
        historyOnlyIDs.remove(id)
    }

    private func recording(for id: UUID) -> Recording? {
        if let kept = retained[id] { return kept }
        return history.entry(id: id).flatMap { history.loadRecording(for: $0) }
    }

    // MARK: - Pill and status

    private var hasPendingWork: Bool { !queue.isEmpty || isDelivering }

    /// The pill's phase as recordings count it: a press that hasn't committed reads as the phase under it (rest or
    /// processing), though the pill already shows it, so a quick tap or an fn combo is never taken for a
    /// recording (onboarding practice).
    var committedPillPhase: PillPhase {
        let phase = pillModel.phase
        guard machine.capture.isUncommittedPress, phase.isRecording else { return phase }
        return pendingJobCount > 0 ? .processing : .rest
    }

    /// A one-shot success check or error shake. PillModel keeps the flourish on screen for its minimum time
    /// and settles back by itself, even when the next `refreshPill` already asks for rest.
    private func flash(_ phase: PillPhase) {
        lastFlash = (phase, clock())
        if phase == .error { onDictationFailed?() }
        showFlourish(phase)
    }

    /// Only a real recording suppresses the flourish. The dots of a press that hasn't committed hold it back
    /// until the press folds away (a quick tap, an fn combo), so the check or the shake is never lost to it.
    private func showFlourish(_ phase: PillPhase) {
        guard !machine.capture.isListeningOrLocked else { return }
        if machine.capture.isUncommittedPress, !pressKeepsProcessing {
            deferredFlourish = phase
            return
        }
        deferredFlourish = nil
        // Leave any recording phase first, so the shake lands on the idle/processing pill.
        refreshPill()
        if phase == .error {
            // Turns an idle or processing pill into the error flash, or re-shakes one already showing.
            pillModel.shakeTrigger += 1
        } else {
            pillModel.phase = phase
        }
    }

    /// Plays the flourish held back during a press once the press has folded away, or drops it if the press
    /// committed.
    private func replayDeferredFlourish() {
        guard let flourish = deferredFlourish, !machine.capture.isUncommittedPress else { return }
        deferredFlourish = nil
        guard machine.capture == .idle else { return }
        lastFlash = (flourish, clock())
        showFlourish(flourish)
    }

    private func refreshPill() {
        let idle: PillPhase = hasPendingWork ? .processing : .rest
        let phase: PillPhase
        switch machine.capture {
        case .arming, .tapPending:
            // From key-down on: the "connecting" dots until the first buffer, then the voice. Over a job in
            // flight, the processing pill (already on screen) waits for the press to commit.
            phase = pressKeepsProcessing ? idle : .listening
        case .listening:
            phase = .listening
        case .locked, .lockedStopPending:
            phase = .locked
        case .idle:
            phase = idle
        }
        // An idle request doesn't cut a success/error flourish short: PillModel holds it for its minimum time.
        if pillModel.phase != phase { pillModel.phase = phase }

        if phase.isRecording, let started = machine.recordingStartedAt {
            let wallStart = Date().addingTimeInterval(started - clock())
            if pillModel.recordingStartedAt.map({ abs($0.timeIntervalSince(wallStart)) > 0.5 }) ?? true {
                pillModel.recordingStartedAt = wallStart
            }
        } else if pillModel.recordingStartedAt != nil {
            pillModel.recordingStartedAt = nil
        }
        let limit = machine.config.maxDuration
        if pillModel.limitSeconds != limit { pillModel.limitSeconds = limit }
    }

    private func stateDidChange() {
        if hotkeys.isBusy != machine.isBusy { hotkeys.isBusy = machine.isBusy }
        let count = queue.count + (isDelivering ? 1 : 0)
        if pendingJobCount != count { pendingJobCount = count }
        refreshPill()
        replayDeferredFlourish()
        showSecureInputNoticeIfNeeded()
        if !machine.isRecording {
            deviceNoticeDue = false
        } else if machine.capture.isListeningOrLocked, deviceNoticeDue {
            deviceNoticeDue = false
            if let notice = deviceNotice(for: recorder.lastChoice) { toasts.post(notice) }
        }
        let next: DictationActivity = machine.capture.isListeningOrLocked ? .recording : (hasPendingWork ? .processing : .idle)
        if next != activity {
            activity = next
            onActivityChanged?(next)
        }
    }
}

extension DictationMachine.Capture {
    var isArming: Bool {
        if case .arming = self { true } else { false }
    }

    /// Key down but not committed yet: arming, or the double-press window after a quick tap. The pill shows it,
    /// but nothing counts it as a recording.
    var isUncommittedPress: Bool {
        switch self {
        case .arming, .tapPending: true
        case .idle, .listening, .locked, .lockedStopPending: false
        }
    }

    /// Recording past the confirm delay. Arming already shows the pill, but its sound, notices and the menu bar
    /// state wait, so fn combos and quick taps stay quiet.
    var isListeningOrLocked: Bool {
        switch self {
        case .listening, .locked, .lockedStopPending: true
        case .idle, .arming, .tapPending: false
        }
    }
}

/// "At most N times a day" for gentle notices.
struct DailyQuota: Equatable {
    let limit: Int
    private var day: Date?
    private var used = 0

    init(limit: Int) {
        self.limit = limit
    }

    mutating func take(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        if today != day {
            day = today
            used = 0
        }
        guard used < limit else { return false }
        used += 1
        return true
    }
}

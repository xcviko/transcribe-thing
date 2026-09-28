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
    /// Replaces the whole generation lookup (provider, timing); wins over `providerLookupOverride`.
    @ObservationIgnored var generationLookupOverride: (@MainActor (String) async -> GenerationDetails?)?
    /// Replaces the clean-up request: the transcript and the engine that wrote it (the model is the job's).
    @ObservationIgnored var cleanupOverride: (@MainActor (String, EngineID) async throws -> TranscriptResult)?
    /// Replaces how long a clean-up may take (`CleanupModel.timeout(forCharacterCount:)`).
    @ObservationIgnored var cleanupTimeoutOverride: TimeInterval?
    /// Replaces how long a job runs before "taking longer than usual" (`slowNoticeDelay(for:)`).
    @ObservationIgnored var slowNoticeDelayOverride: TimeInterval?
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
    /// The engine each recording being transcribed or delivered right now uses, by recording id: History shows
    /// those rows as transcribing and keeps them from being sent again.
    private(set) var transcribingEngines: [UUID: EngineID] = [:]
    /// What is being made for each recording right now, by recording id: a transcription (a job, as in
    /// `transcribingEngines`) or a clean-up (a dictation's own, or one asked for from History). History's Versions
    /// menu shows it and offers nothing else for that recording meanwhile.
    private(set) var runningVersions: [UUID: TranscriptVersionKind] = [:]
    /// The shortcut's event tap has been down for longer than `shortcutNoticeGrace`: fn does nothing.
    private(set) var isShortcutUnavailable = false
    /// What this dictation goes to instead of the main model alone (Switch model): clean-up or an extra model; nil
    /// for the main model. It lasts while the dictation records: its job keeps it, the next dictation starts on the
    /// main model, and an Undo-resume brings back the canceled dictation's.
    private(set) var modelOverride: ModelChoice?
    /// The extra model transcribing this dictation, if `modelOverride` is one.
    var engineOverride: EngineID? { modelOverride?.switchEngine }
    /// How long a push-to-talk hold lasts before the pill hints at Switch model.
    @ObservationIgnored var switchHintDelay: TimeInterval = 1.5
    /// How long the tap may stay down before the user is told (its own retries and brief drops stay quiet).
    @ObservationIgnored var shortcutNoticeGrace: Duration = .seconds(6)

    @ObservationIgnored private var timers: [DictationMachine.TimerID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var queue: [Job] = []
    /// The job whose result is being delivered right now (it has already left `queue`).
    @ObservationIgnored private var deliveringJob: Job?
    /// A refusal found at key-down, reported only if the user commits to dictating (fn+← must stay silent).
    @ObservationIgnored private var pendingRefusal: AppError?
    /// When the last error shake was requested (pill clicks during it open the Hub instead of recording).
    @ObservationIgnored private var lastErrorFlashAt: TimeInterval?
    /// A shake that came while the pill showed a press that hasn't committed (arming, the tap window). It
    /// plays when the press folds away; a press that commits drops it, as a recording cuts one on screen.
    @ObservationIgnored private var isErrorFlashDeferred = false
    /// The words the deferred flash carries ("No speech detected"), or nil for the plain shake.
    @ObservationIgnored private var deferredErrorMessage: String?
    /// The press under way began while a job was in flight: until it commits, the processing pill stays exactly
    /// as it is (its width, "Still transcribing…"), so an fn tap or an fn combo doesn't disturb it.
    @ObservationIgnored private var pressKeepsProcessing = false
    @ObservationIgnored private var retained: [UUID: Recording] = [:]
    @ObservationIgnored private var retainedOrder: [UUID] = []
    @ObservationIgnored private var lastCancelledID: UUID?
    /// The engine each canceled recording kept for Undo was dictated with (an extra model is resumed with it).
    @ObservationIgnored private var cancelledEngines: [UUID: EngineID] = [:]
    /// Kept recordings of dictations on clean-up (canceled or failed): Undo and Retry pick them up on clean-up again.
    @ObservationIgnored private var cleanupIDs: Set<UUID> = []
    @ObservationIgnored private var switchHintTask: Task<Void, Never>?
    /// The push-to-talk hold (its key-down time) the hint timer runs for.
    @ObservationIgnored private var switchHintHold: TimeInterval?
    /// The canceled recording the capture in progress continues (Undo), while that capture runs.
    @ObservationIgnored private var continuing: Recording?
    /// The recording the next `.resumeCapture` effect continues.
    @ObservationIgnored private var resumeRequest: Recording?
    /// When each failure notice (by dedupe key) last played its sound.
    @ObservationIgnored private var failureCueTimes: [String: TimeInterval] = [:]
    /// Retained recordings whose job came from the Hub: their Retry and Undo update history, never paste.
    @ObservationIgnored private var historyOnlyIDs: Set<UUID> = []
    /// The engine a failed Transcribe Again used, which its notice's Retry uses again (the entry keeps the engine
    /// of the text it still shows).
    @ObservationIgnored private var retryEngines: [UUID: EngineID] = [:]
    /// Clean-ups asked for from History, by recording id: the version being made (whose text, which model).
    @ObservationIgnored private var historyCleanups: [UUID: TranscriptVersionKind] = [:]
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
        pillModel.onSelectModel = { [weak self] choice in self?.selectModelForCurrentDictation(choice) }
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
        case .cycleEngine: send(.cycleEngine)
        }
    }

    /// The Switch model shortcut: the next choice for the dictation being recorded, main model → clean-up → each
    /// extra model (`settings.switchChoices`) → main model.
    func cycleEngine() {
        send(.cycleEngine)
    }

    /// The pill's model menu (hands-free): `choice` for the dictation being recorded; the main model, clean-up or
    /// any extra model.
    func selectModelForCurrentDictation(_ choice: ModelChoice) {
        guard machine.isRecording else { return }
        let target: ModelChoice? = choice == .engine(settings.selectedEngine) ? nil : choice
        guard target != modelOverride else { return }
        if let target {
            guard isCloudKeyUsable else {
                rejectSwitchWithoutKey()
                return
            }
            guard fits(target) else {
                rejectSwitchTooLong()
                return
            }
        }
        switchModel(to: target)
        stateDidChange()
    }

    /// The engine the dictation being recorded goes to: the extra model picked for it, else the main model.
    var effectiveEngine: EngineID { engineOverride ?? settings.selectedEngine }

    /// The Switch model shortcut can do something: clean-up or an extra model takes part, and the OpenRouter key works.
    var canSwitchModels: Bool { !settings.switchChoices.isEmpty && isCloudKeyUsable }

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
            // Every press starts with an empty equalizer: the meter still holds the last recording's levels,
            // and a refused press never opens the mic, whose start would clear them.
            pillModel.levelMeter.reset()
            // Its start cue follows in 120 ms: the sound output (AirPods wake slowly) starts now, off the main thread.
            sounds.warmUp()
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
        if !machine.isRecording {
            pendingRefusal = nil
            // The dictation is over (its job and any kept recording hold the choice): the next one starts on the
            // main model.
            if modelOverride != nil { modelOverride = nil }
        }
        stateDidChange()
    }

    private func pillClicked() {
        if let flashedAt = lastErrorFlashAt, clock() - flashedAt < 1.5 {
            if toasts.notices.isEmpty { openHub?(.home) }
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
        if !machine.isRecording { machine.config.maxDuration = settings.maxRecordingDuration(for: effectiveEngine) }
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
            case .cycleEngine:
                advanceEngine()
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

    /// Checks made before the mic opens: permission and whether the dictation's engine can run at all.
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
        let engine = effectiveEngine
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
        let job = Job(recording: nil, engine: effectiveEngine, delivery: delivery, id: resumedID)
        job.cleansUp = modelOverride == .cleanup
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
            keepCancelled(recording, engine: job.engine, cleansUp: job.cleansUp, notify: true)
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
            flashError()
            return false
        }
        if recording.speech.voicedSeconds < Self.minimumVoicedSeconds {
            reportNoSpeech()
            return false
        }
        return true
    }

    /// "No speech detected", every time: said inside the pill, in place of the error glyph and without the shake.
    /// With no pill at all (Never mode) it is the quiet info notice instead. Shared by recordings the recorder
    /// finds speechless and engines that answer with no text.
    private func reportNoSpeech() {
        if settings.pillMode == .never {
            postFailure(AppError.noSpeech.notice(recordingID: nil, fallbackEngine: nil))
        }
        flashError(message: PillMetrics.noSpeechText)
    }

    private func cancelCapture(keepForUndo: Bool, notify: Bool) {
        // "Dictation stopped · Undo" offers this recording or nothing, never an older one still retained.
        if keepForUndo { lastCancelledID = nil }
        let resumed = continuing
        continuing = nil
        let recording = captureDevice.isCapturing ? captureDevice.cancel() : nil
        if keepForUndo {
            guard let recording else { return }
            keepCancelled(recording, engine: effectiveEngine, cleansUp: modelOverride == .cleanup, notify: notify)
        } else if let resumed {
            // A resumed dictation whose mic failed: its audio (the kept part at least) stays for another Undo.
            keepCancelled(recording ?? resumed, engine: effectiveEngine, cleansUp: modelOverride == .cleanup, notify: true)
        }
    }

    /// Keeps a canceled recording for Undo (and in history when it's long). `historyOnly`: it was a Hub
    /// transcription, which Undo transcribes after all instead of recording on. `keepsEntry`: it was Transcribe
    /// Again, whose entry keeps its text instead of turning into a canceled row.
    private func keepCancelled(_ recording: Recording, engine: EngineID, cleansUp: Bool = false, notify: Bool,
                               historyOnly: Bool = false, keepsEntry: Bool = false) {
        guard recording.duration >= Self.undoMinimumDuration else { return }
        retain(recording)
        cancelledEngines[recording.id] = engine
        if cleansUp { cleanupIDs.insert(recording.id) } else { cleanupIDs.remove(recording.id) }
        if historyOnly { historyOnlyIDs.insert(recording.id) }
        lastCancelledID = recording.id
        let saved = !keepsEntry && recording.duration >= Self.saveCancelledMinimumDuration
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
        /// `cleanup`: how the clean-up of the text went, when the dictation was cleaned up.
        case success(TranscriptResult, cleanup: CleanupOutcome? = nil)
        case failure(AppError)
    }

    fileprivate enum CleanupOutcome {
        case cleaned(TranscriptResult)
        /// Timed out, failed or came back empty (nil): the original text stands.
        case failed(AppError?)
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
        /// Transcribe Again of a successful entry: the result replaces its text in place, and a failure or a
        /// cancel leaves the entry as it is.
        var replacesTranscript = false
        /// A dictation on clean-up (Switch model): its transcript is tidied before it's pasted.
        var cleansUp = false
        /// Its text is with the clean-up model now: the transcription itself is done.
        var isCleaningUp: Bool { uncleaned != nil }
        /// The finished transcript being cleaned up, kept should the clean-up be canceled.
        var uncleaned: TranscriptResult?
        /// The clean-up model tidying it: the one selected when the transcript came back.
        var cleanupModel: CleanupModel?
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
    /// already queued, being delivered or being recorded on is never queued twice. `cleansUp`: a dictation on
    /// clean-up, picked up again.
    func enqueue(_ recording: Recording, engine: EngineID, delivery: Delivery, cleansUp: Bool = false) {
        guard !isInFlight(recording.id) else { return }
        let job = Job(recording: recording, engine: engine, delivery: delivery)
        job.cleansUp = cleansUp
        job.replacesTranscript = delivery == .historyOnly && history.entry(id: recording.id)?.status == .success
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
        job.uncleaned = nil
        job.cleanupModel = nil
        job.task = Task { [weak self] in
            guard let self else { return }
            var outcome = await self.transcribe(recording, engine: engine)
            guard !Task.isCancelled, job.generation == generation else { return }
            if case .success(let result, _) = outcome, self.cleansUp(job, result) {
                // Still processing as far as the pill goes: the text is pasted once it's tidied (or given up on).
                let model = self.settings.cleanupModel
                job.uncleaned = result
                job.cleanupModel = model
                job.hintTask?.cancel()
                self.dismissSlowNotice(for: job.id)
                self.stateDidChange()
                let cleanup = await self.runCleanup(result.text, of: result.engine, by: model)
                guard !Task.isCancelled, job.generation == generation else { return }
                outcome = .success(result, cleanup: cleanup)
            }
            job.outcome = outcome
            job.hintTask?.cancel()
            self.dismissSlowNotice(for: job.id)
            self.drain()
        }
        let hintDelay = slowNoticeDelayOverride ?? Self.slowNoticeDelay(for: engine)
        job.hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hintDelay))
            guard !Task.isCancelled, let self, job.outcome == nil, !job.isCleaningUp,
                  job.generation == generation else { return }
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

    /// A dictation on clean-up (Switch model) is tidied before it's delivered, while there's a prompt to follow.
    /// A transcript made again from History (a new version of an existing row) isn't: History offers Clean Up.
    private func cleansUp(_ job: Job, _ result: TranscriptResult) -> Bool {
        job.cleansUp && settings.hasCleanupPrompt && CleanupModel.canClean(result.engine) && !job.replacesTranscript
            && !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Tidies `text` (written by `source`) with the clean-up model `model`, giving up after its timeout. Never
    /// throws: a failure, a timeout or an empty answer is `.failed`, and the original text stands.
    private func runCleanup(_ text: String, of source: EngineID, by model: CleanupModel) async -> CleanupOutcome {
        // A key already known not to work would fail the request too: no round trip, and the notice says why.
        if let keyProblem = cleanupKeyProblem {
            Log.engine.info("Clean-up skipped: \(keyProblem.code, privacy: .public)")
            return .failed(keyProblem)
        }
        let timeout = cleanupTimeoutOverride ?? CleanupModel.timeout(forCharacterCount: text.count)
        do {
            var result: TranscriptResult
            if let cleanupOverride {
                result = try await Self.within(timeout, source: source) { try await cleanupOverride(text, source) }
            } else {
                let transcription = transcription
                result = try await Self.within(timeout, source: source) {
                    try await transcription.cleanUp(text, of: source, by: model, timeout: timeout)
                }
            }
            result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.text.isEmpty else {
                Log.engine.info("Clean-up returned no text; keeping the original")
                return .failed(nil)
            }
            return .cleaned(result)
        } catch let error as AppError {
            Log.engine.error("Clean-up failed: \(error.code, privacy: .public)")
            return .failed(error)
        } catch {
            return .failed(nil)
        }
    }

    /// Why the OpenRouter key can't clean up right now, as far as the account knows (nil while it may).
    private var cleanupKeyProblem: AppError? {
        switch account.status {
        case .missing: .openRouterMissingKey
        case .invalid(let message): .openRouterInvalidKey(message)
        case .noCredit where account.status.isKeyLimitReached: .openRouterKeyLimit("")
        case .noCredit: .openRouterNoCredits("")
        case .failed where account.isKeyUnreadable: .openRouterKeyUnreadable
        case .checking, .valid, .offline, .failed: nil
        }
    }

    /// `work`, or `AppError.timeout(source)` once `seconds` pass (then `work` is cancelled).
    private static func within(_ seconds: TimeInterval, source: EngineID,
                               _ work: @escaping @MainActor () async throws -> TranscriptResult) async throws -> TranscriptResult {
        try await withThrowingTaskGroup(of: TranscriptResult?.self) { group in
            group.addTask { @MainActor in try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else { throw AppError.timeout(source) }
            return result
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
        queue.contains { $0.id == id } || deliveringJob?.id == id || continuing?.id == id || historyCleanups[id] != nil
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
        if let recording = job.recording, let uncleaned = job.uncleaned, job.outcome == nil {
            keepUncleaned(job, recording, uncleaned)
        } else if let recording = job.recording {
            keepCancelled(recording, engine: job.engine, cleansUp: job.cleansUp, notify: true,
                          historyOnly: job.delivery == .historyOnly,
                          keepsEntry: job.replacesTranscript)
        }
        drain()
        return true
    }

    /// Canceled while its transcript was being cleaned up: only the clean-up and the paste are called off. The
    /// finished transcript goes to History, with a card to paste it from; Retry would only make it again.
    private func keepUncleaned(_ job: Job, _ recording: Recording, _ result: TranscriptResult) {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        forget(job.id)
        toasts.dismiss(recordingID: job.id)
        let version = result.version(text: text)
        let file = settings.keepSuccessfulRecordingsDays > 0 ? history.saveAudio(recording) : nil
        history.upsert(TranscriptEntry(
            id: job.id, createdAt: recording.startedAt, engine: result.engine, status: .success,
            audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
            audioFileName: file, versions: [version]))
        resolveGeneration(of: version, entryID: job.id)
        toasts.post(transcriptCard(text, title: "Clean-up canceled",
                                   body: "The original is in History. Paste it here, or copy it.", pasteHere: true))
    }

    private func deliver(_ job: Job, _ outcome: Outcome) async {
        guard let recording = job.recording else { return }
        switch outcome {
        case .failure(.noSpeech):
            deliverSilence(job)
        case .failure(let error):
            deliverFailure(job, error)
        case .success(let result, let cleanup):
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The engine answered and heard nothing: the user was silent. Not an error.
            guard !text.isEmpty else {
                deliverSilence(job)
                return
            }
            forget(job.id)
            // An older notice's Retry or Undo would transcribe it yet again, or record on, now that its audio is kept.
            toasts.dismiss(recordingID: job.id)
            if job.replacesTranscript {
                deliverTranscriptAgain(job, result, text: text)
                return
            }
            // The raw transcript is always a version; a clean-up that worked is another, and the one delivered.
            var versions = [result.version(text: text)]
            var delivered = text
            var cleanupFailed = false
            var cleanupError: AppError?
            let cleanupModel = job.cleanupModel ?? settings.cleanupModel
            switch cleanup {
            case .cleaned(let cleaned)?:
                versions.append(cleaned.version(.cleanup(of: result.engine, by: cleanupModel)))
                delivered = cleaned.text
            case .failed(let error)?:
                cleanupFailed = true
                cleanupError = error
            case nil:
                break
            }
            // Kept a while so History can transcribe it again with another model. Saved again even when a failed or
            // canceled row had it: an Undo-resumed dictation's file holds only the part before the cancel.
            let file = settings.keepSuccessfulRecordingsDays > 0 ? history.saveAudio(recording) : nil
            history.upsert(TranscriptEntry(
                id: job.id, createdAt: recording.startedAt, engine: result.engine, status: .success,
                audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
                audioFileName: file, versions: versions))
            for version in versions { resolveGeneration(of: version, entryID: job.id) }
            switch job.delivery {
            case .historyOnly:
                let kind = versions.last?.kind ?? .transcription(result.engine)
                toasts.post(Notice(dedupeKey: "retry.\(job.id)", style: .success, symbol: "checkmark.circle.fill",
                                   title: "Transcribed with \(kind.shortName)",
                                   body: "It’s in your history.",
                                   actions: [NoticeAction(title: "Copy", kind: .copyText(delivered), isPrimary: true)],
                                   lifetime: .seconds(5)))
                if cleanupFailed { postCleanupFallback(pasted: false, error: cleanupError, model: cleanupModel) }
            case .paste(let target):
                let insertion = await insert(delivered, expectedPID: target)
                handleInsertion(insertion, text: delivered, isDictation: true)
                if cleanupFailed { postCleanupFallback(pasted: true, error: cleanupError, model: cleanupModel) }
            }
        }
    }

    /// The quiet word that a dictation's clean-up didn't happen: its original text was delivered instead. A key
    /// problem (every dictation would hit it until it's fixed or clean-up is off) points to Models.
    private func postCleanupFallback(pasted: Bool, error: AppError?, model: CleanupModel) {
        let keyProblem = error?.stopsEveryCloudModel == true && error != .offline
        toasts.post(Notice(dedupeKey: "cleanup.fallback", style: .info, symbol: "wand.and.sparkles",
                           title: pasted ? "Couldn’t clean up · pasted the original" : "Couldn’t clean up · kept the original",
                           body: Self.cleanupFailureReason(error, model: model),
                           actions: keyProblem ? [NoticeAction(title: "Open Models", kind: .openHub(.models), isPrimary: true)] : [],
                           lifetime: .seconds(keyProblem ? 6 : 4)))
    }

    /// Transcribe With (History): the new text becomes the entry's current version (same row, date and audio; the
    /// others stay in its Versions menu) and a card offers it for pasting wherever the user wants. Never pasted by
    /// itself: the user is in the Hub. An entry deleted meanwhile isn't brought back; the card still has the text.
    private func deliverTranscriptAgain(_ job: Job, _ result: TranscriptResult, text: String) {
        let version = result.version(text: text)
        if var entry = history.entry(id: job.id), entry.status == .success {
            entry.addVersion(version)
            history.upsert(entry)
            resolveGeneration(of: version, entryID: job.id)
        }
        toasts.post(transcriptCard(text, title: "Transcribed with \(result.engine.shortName)",
                                   body: "Updated in History. Paste here, or copy it.", pasteHere: true))
    }

    /// Asks OpenRouter about a delivered cloud version in the background, once its response didn't name the
    /// provider: who served it, and how long the generation took. Recorded on the entry's version unless that
    /// version changed meanwhile (deleted, or made again).
    private func resolveGeneration(of version: TranscriptVersion, entryID: UUID) {
        guard version.metadata.provider == nil, let generationID = version.metadata.generationID else { return }
        let kind = version.kind
        Task { [weak self] in
            guard let self else { return }
            let details: GenerationDetails?
            if let override = self.generationLookupOverride {
                details = await override(generationID)
            } else if let override = self.providerLookupOverride {
                details = await override(generationID).map { GenerationDetails(provider: $0) }
            } else {
                details = await self.transcription.generationDetails(generationID: generationID)
            }
            guard let details, var entry = self.history.entry(id: entryID), entry.status == .success,
                  entry.version(kind)?.metadata.generationID == generationID else { return }
            entry.updateMetadata(of: kind) { metadata in
                metadata.provider = metadata.provider ?? details.provider
                metadata.latency = metadata.latency ?? details.latency
                metadata.generationTime = metadata.generationTime ?? details.generationTime
                metadata.costUSD = metadata.costUSD ?? details.costUSD
                if details.reasoningTokens != nil, metadata.usage?.reasoningTokens == nil {
                    var usage = metadata.usage ?? TokenUsage()
                    usage.reasoningTokens = details.reasoningTokens
                    metadata.usage = usage
                }
            }
            self.history.upsert(entry)
        }
    }

    /// A recording that turned out to be silence leaves nothing behind: no history entry, no kept audio, no
    /// Retry. One that already had a failed or canceled row (a retry, a resumed dictation) takes the row and its
    /// audio along; "No speech detected" still says why, so a row never vanishes without a word.
    private func deliverSilence(_ job: Job) {
        forget(job.id)
        let hadRow = history.entry(id: job.id).map { $0.status != .success } ?? false
        if hadRow { history.delete(job.id) }
        Log.engine.info("No speech from \(job.engine.rawValue, privacy: .public)")
        reportNoSpeech()
    }

    private func deliverFailure(_ job: Job, _ error: AppError) {
        guard let recording = job.recording else { return }
        if job.replacesTranscript {
            deliverTranscriptAgainFailure(job, recording, error)
            return
        }
        let file = history.saveAudio(recording)
        retain(recording)
        if job.delivery == .historyOnly { historyOnlyIDs.insert(job.id) }
        if job.cleansUp { cleanupIDs.insert(job.id) }
        // A downloaded model that isn't loaded yet loads for the retry, so it counts too.
        let fallback = usableFallback(excluding: job.engine, after: error)
        let notice = error.notice(recordingID: job.id, fallbackEngine: fallback, engine: job.engine)
        history.upsert(TranscriptEntry(
            id: job.id, createdAt: recording.startedAt, text: "", engine: job.engine, status: .failed,
            audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
            errorMessage: notice.title, audioFileName: file ?? history.entry(id: job.id)?.audioFileName))
        Log.engine.error("Transcription failed: \(error.code, privacy: .public)")
        postFailure(notice)
        flashError()
    }

    /// A failed Transcribe Again leaves the entry and its text alone; the notice's Retry uses the same engine, and
    /// its "Retry with" never offers an engine the entry already has a version from.
    private func deliverTranscriptAgainFailure(_ job: Job, _ recording: Recording, _ error: AppError) {
        retain(recording)
        historyOnlyIDs.insert(job.id)
        retryEngines[job.id] = job.engine
        let fallback = usableFallback(excluding: job.engine, after: error, alsoExcluding: usedEngines(of: job.id))
        Log.engine.error("Transcribe again failed: \(error.code, privacy: .public)")
        postFailure(error.notice(recordingID: job.id, fallbackEngine: fallback, engine: job.engine))
        flashError()
    }

    // MARK: - Insertion

    private func insert(_ text: String, expectedPID: pid_t?) async -> InsertionOutcome {
        if let insertOverride { return await insertOverride(text, expectedPID) }
        return await inserter.insert(text, expectedPID: expectedPID)
    }

    private func copy(_ text: String) {
        if let copyOverride { copyOverride(text) } else { inserter.copy(text) }
    }

    /// `isDictation`: a dictation's own delivery, not paste-last or a toast's Paste Here. The pasted text is the
    /// confirmation; the pill just goes back to rest.
    private func handleInsertion(_ outcome: InsertionOutcome, text: String, isDictation: Bool) {
        Log.app.notice("Insertion outcome: \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .pasted:
            // A paste landing mid-recording must not leak its tick into the new recording.
            if !machine.isRecording { sounds.play(.paste) }
            if isDictation { onDictationDelivered?() }
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
                self.handleInsertion(outcome, text: text, isDictation: false)
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
                self.handleInsertion(outcome, text: text, isDictation: false)
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

    // MARK: - History versions

    /// The Versions menu: the row shows its version of `kind` (switching needs no audio).
    func showVersion(_ kind: TranscriptVersionKind, of entryID: UUID) {
        history.selectVersion(kind, of: entryID)
    }

    /// The Versions menu's "Transcribe With": makes the version of `kind` the entry doesn't have yet, into history
    /// only, with a card to paste it from afterwards. A transcription needs the recording; a clean-up only the
    /// text it tidies. A version the entry already has is shown instead of being made twice.
    func makeVersion(_ kind: TranscriptVersionKind, of entry: TranscriptEntry) {
        switch kind {
        case .transcription(let engine): retry(entry, with: engine)
        case .cleanup(let source, let model): cleanUp(entry, of: source, by: model)
        }
    }

    /// Clean Up from History: `model` tidies the entry's `source` transcript, which becomes a new version and the
    /// current one. Works without the audio. Nothing happens while something else runs for the recording.
    private func cleanUp(_ entry: TranscriptEntry, of source: EngineID, by model: CleanupModel) {
        guard entry.status == .success, CleanupModel.canClean(source), !isInFlight(entry.id),
              let raw = history.entry(id: entry.id)?.version(.transcription(source)) else { return }
        let kind = TranscriptVersionKind.cleanup(of: source, by: model)
        guard !(history.entry(id: entry.id)?.hasVersion(kind) ?? false) else {
            showVersion(kind, of: entry.id)
            return
        }
        guard settings.hasCleanupPrompt else {
            toasts.post(Notice(dedupeKey: "cleanup.noPrompt", style: .info, symbol: "wand.and.sparkles",
                               title: "Clean-up needs a prompt", body: "Write one in Models, or use the example.",
                               actions: [NoticeAction(title: "Open Models", kind: .openHub(.models), isPrimary: true)],
                               lifetime: .seconds(6)))
            return
        }
        let id = entry.id
        historyCleanups[id] = kind
        stateDidChange()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runCleanup(raw.text, of: source, by: model)
            self.historyCleanups[id] = nil
            defer { self.stateDidChange() }
            switch outcome {
            case .cleaned(let result):
                let version = result.version(kind)
                if var current = self.history.entry(id: id), current.status == .success {
                    current.addVersion(version)
                    self.history.upsert(current)
                    self.resolveGeneration(of: version, entryID: id)
                }
                self.toasts.post(self.transcriptCard(result.text, title: "Cleaned up with \(model.shortName)",
                                                     body: "Updated in History. Paste here, or copy it.", pasteHere: true))
            case .failed(let error):
                self.toasts.post(Notice(dedupeKey: "cleanup.failed.\(id)", style: .warning, symbol: "wand.and.sparkles",
                                        title: "Couldn’t clean up", body: Self.cleanupFailureReason(error, model: model),
                                        lifetime: .seconds(6), sound: .alert))
            }
        }
    }

    /// Why a clean-up didn't happen, in a sentence about the text and the clean-up model that tried (the error
    /// notices' own titles speak of Gemini and recordings).
    nonisolated static func cleanupFailureReason(_ error: AppError?, model cleanupModel: CleanupModel) -> String {
        let model = cleanupModel.shortName
        return switch error {
        case nil: "\(model) returned no text."
        case .timeout?: "\(model) took too long."
        case .openRouterMissingKey?: "Add your OpenRouter key in Models."
        case .openRouterKeyUnreadable?: "Your OpenRouter key couldn’t be read from the Keychain."
        case .openRouterInvalidKey?: "Your OpenRouter key was rejected."
        case .openRouterNoCredits?: "You’re out of OpenRouter credit."
        case .openRouterKeyLimit?: "Your OpenRouter key hit its spending limit."
        case .openRouterRateLimited?: "OpenRouter is rate-limiting requests. Try again in a moment."
        case .openRouterNoRoute?: "OpenRouter found no \(cleanupModel.providerName) route for your key."
        case .openRouterProviderUnavailable?: "\(cleanupModel.providerName) is unavailable."
        case .openRouterServer?: "OpenRouter ran into a problem."
        case .openRouterTruncated?: "\(model) stopped before finishing."
        case .openRouterRefused?, .openRouterBadRequest?: "\(model) couldn’t process the text."
        case .offline?: "You’re offline."
        case let error?: error.notice(recordingID: nil, fallbackEngine: nil).title
        }
    }

    /// Hub history: "Retry" of a failed or canceled row, or "Transcribe With" of a transcript, with any engine the
    /// transcript has no version from (one it has is shown instead). Only into history, never pasted.
    func retry(_ entry: TranscriptEntry, with engine: EngineID) {
        guard !isInFlight(entry.id) else { return }
        if let current = history.entry(id: entry.id), current.status == .success,
           current.hasVersion(.transcription(engine)) {
            showVersion(.transcription(engine), of: entry.id)
            return
        }
        guard let recording = recording(for: entry.id) else {
            postRecordingGone()
            return
        }
        enqueue(recording, engine: engine, delivery: .historyOnly)
    }

    private func retry(recordingID: UUID?, engine: EngineID?) {
        guard let id = recordingID else { return }
        if let waiting = queue.first(where: { $0.id == id }) {
            // Still in the queue ("Use Parakeet v3 · Cloud Instead" while Parakeet loads): switch engines in place,
            // unless it's Transcribe With and the transcript already has that model's version (never run twice).
            if let engine, engine != waiting.engine, waiting.outcome == nil, !waiting.isCleaningUp,
               !(waiting.replacesTranscript && usedEngines(of: id).contains(engine)) {
                waiting.engine = engine
                run(waiting)
                stateDidChange()
            }
            return
        }
        guard !isInFlight(id) else { return }
        guard let recording = recording(for: id) else {
            postRecordingGone()
            return
        }
        let chosen = engine ?? retryEngines[id] ?? history.entry(id: id)?.engine ?? settings.selectedEngine
        if let entry = history.entry(id: id), entry.status == .success, entry.hasVersion(.transcription(chosen)) {
            // Never the same model twice on one recording: the text it wrote is already there.
            showVersion(.transcription(chosen), of: id)
            return
        }
        let delivery = redeliveryTarget(for: id)
        enqueue(recording, engine: chosen, delivery: delivery, cleansUp: delivery != .historyOnly && cleanupIDs.contains(id))
    }

    /// Where a retried or undone recording goes: back to history for Hub jobs, else the cursor now. A recording
    /// already transcribed (its audio kept for Transcribe Again) goes back to its row, which keeps the old text.
    private func redeliveryTarget(for id: UUID) -> Delivery {
        historyOnlyIDs.contains(id) || history.entry(id: id)?.status == .success
            ? .historyOnly : .paste(targetPID: inserter.frontmostPID())
    }

    /// Undo of a cancel: the dictation picks up again hands-free, its kept audio first, and nothing is transcribed
    /// or pasted until the user stops (Esc cancels it again, all of it). A canceled Hub transcription is
    /// transcribed after all, into history.
    private func undo(recordingID: UUID?) {
        guard let id = recordingID, let recording = recording(for: id) else {
            postRecordingGone()
            return
        }
        let engine = cancelledEngines[id] ?? history.entry(id: id)?.engine
        if historyOnlyIDs.contains(id) {
            enqueue(recording, engine: engine ?? settings.selectedEngine, delivery: .historyOnly)
            return
        }
        // Transcribed since (from History): there's no dictation left to pick up, and its text is in History.
        guard history.entry(id: id)?.status != .success else { return }
        // Already being transcribed (a Hub retry of it) or recorded on.
        guard !isInFlight(id) else { return }
        let saved = history.entry(id: id)?.status == .cancelled
        guard !machine.isRecording else {
            postCanceled(recording, saved: saved, note: "Finish this dictation first, then Undo.")
            return
        }
        resumeRequest = recording
        // The same dictation goes on, with the model it had (its limit too); `send` drops it if the mic won't start.
        modelOverride = cleanupIDs.contains(id) ? .cleanup : engine.flatMap { $0.isSwitchModel ? .engine($0) : nil }
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
                           body: "\(Brand.name) keeps recordings only for a while. Choose how long in General → History.",
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
            let engine = effectiveEngine
            postFailure(error.notice(recordingID: nil, fallbackEngine: usableFallback(excluding: engine, after: error),
                                     engine: engine))
        }
        flashError()
    }

    private func postSlowNotice(for job: Job) {
        // Transcribe With never offers a model the transcript already has a version from.
        let used = job.replacesTranscript ? usedEngines(of: job.id) : []
        var fallback = usableFallback(excluding: job.engine, alsoExcluding: used)
        var notice: Notice
        switch models.state(of: job.engine) {
        case .downloading(let progress) where job.engine.isLocal:
            notice = AppError.modelDownloading(job.engine, progress.fraction).notice(recordingID: nil, fallbackEngine: nil)
        case .preparing where job.engine.isLocal, .installed where job.engine.isLocal:
            // Only an engine that can start right now is any faster than waiting for this load.
            fallback = readyFallback(excluding: job.engine, alsoExcluding: used)
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

    /// The engines a successful entry already has a transcription from (none for a failed or canceled row).
    private func usedEngines(of id: UUID) -> Set<EngineID> {
        guard let entry = history.entry(id: id), entry.status == .success else { return [] }
        return Set(entry.versions.compactMap { if case .transcription(let engine) = $0.kind { engine } else { nil } })
    }

    /// An engine other than `engine` that can start at once, offered as "Retry with …" for a saved recording: a
    /// loaded local model, or a cloud one while the key is valid, unless `error` (the key's, the credit's, the
    /// connection's) would stop it too.
    /// `alsoExcluding`: engines not worth offering either (those the transcript being made again has versions from).
    private func readyFallback(excluding engine: EngineID, after error: AppError? = nil,
                               alsoExcluding others: Set<EngineID> = []) -> EngineID? {
        Self.fallbackCandidates(for: engine).first { candidate in
            guard !others.contains(candidate) else { return false }
            if candidate.isLocal { return models.state(of: candidate) == .ready }
            guard case .valid = account.status else { return false }
            return error?.stopsEveryCloudModel != true
        }
    }

    /// `readyFallback`, else a downloaded local model that isn't loaded yet (it loads for the retry), also
    /// offered as "Use …" when nothing was recorded.
    private func usableFallback(excluding engine: EngineID, after error: AppError? = nil,
                                alsoExcluding others: Set<EngineID> = []) -> EngineID? {
        readyFallback(excluding: engine, after: error, alsoExcluding: others) ?? Self.fallbackCandidates(for: engine).first {
            guard $0.isLocal, !others.contains($0) else { return false }
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
            cancelledEngines[evicted] = nil
            cleanupIDs.remove(evicted)
            retryEngines[evicted] = nil
        }
    }

    private func forget(_ id: UUID) {
        retained[id] = nil
        retainedOrder.removeAll { $0 == id }
        historyOnlyIDs.remove(id)
        cancelledEngines[id] = nil
        cleanupIDs.remove(id)
        retryEngines[id] = nil
    }

    // MARK: - Switch model

    /// Whether OpenRouter would take a Gemini request: a key that isn't known to be missing, rejected, unreadable
    /// or out of credit (a check in progress or offline is given the benefit of the doubt).
    private var isCloudKeyUsable: Bool {
        switch account.status {
        case .missing, .invalid, .noCredit: false
        case .failed where account.isKeyUnreadable: false
        case .checking, .valid, .offline, .failed: true
        }
    }

    /// An extra model needs at least this much of its limit left to be switched to.
    private static let switchMinimumRemaining: TimeInterval = 10

    /// `engine` can still take the whole recording (Gemini stops at 7 minutes).
    private func fitsRecording(_ engine: EngineID) -> Bool {
        guard let started = machine.recordingStartedAt else { return true }
        return settings.maxRecordingDuration(for: engine) - (clock() - started) >= Self.switchMinimumRemaining
    }

    /// `choice` can still take the whole recording: clean-up has the main model's limit.
    private func fits(_ choice: ModelChoice) -> Bool {
        choice.switchEngine.map(fitsRecording) ?? true
    }

    /// The machine's `.cycleEngine`: main model → clean-up → each extra model (`settings.switchChoices`) → main
    /// model. Extra models that can't take the recording any more are skipped.
    private func advanceEngine() {
        let choices = settings.switchChoices
        guard !choices.isEmpty else { return }
        guard isCloudKeyUsable else {
            rejectSwitchWithoutKey()
            return
        }
        let cycle: [ModelChoice?] = [nil] + choices.filter(fits).map(Optional.some)
        let index = cycle.firstIndex(of: modelOverride) ?? 0
        let next = cycle[(index + 1) % cycle.count]
        guard next != modelOverride else {
            rejectSwitchTooLong()
            return
        }
        switchModel(to: next)
        // Found it: the hint has nothing left to teach.
        if settings.switchHintShownCount < AppSettings.switchHintLimit {
            settings.switchHintShownCount = AppSettings.switchHintLimit
        }
    }

    /// Another choice for this dictation: its limit (Gemini's is shorter), the pill's chip and a soft tick.
    private func switchModel(to choice: ModelChoice?) {
        modelOverride = choice
        execute(machine.changeLimit(to: settings.maxRecordingDuration(for: effectiveEngine), now: clock()))
        pillModel.engineChipPulse &+= 1
        if pillModel.showsTabHint { pillModel.showsTabHint = false }
        playCue(.modelSwitch)
    }

    /// No usable OpenRouter key: the engine stays, the pill shakes and a notice says what Gemini needs.
    private func rejectSwitchWithoutKey() {
        pillModel.shakeTrigger += 1
        if case .invalid = account.status { account.refreshIfStale(maxAge: 30) }
        toasts.post(Self.switchWithoutKeyNotice(account.status, choices: settings.switchChoices))
    }

    /// What a switch to clean-up or an extra model (`choices`, what Switch model steps through) says when the
    /// OpenRouter key can't pay for it.
    static func switchWithoutKeyNotice(_ status: KeyStatus, choices: [ModelChoice]) -> Notice {
        let subject = choices.allSatisfy(\.cleansUp) ? "Clean-up needs"
            : choices.contains(.cleanup) ? "Clean-up and Gemini need" : "Gemini needs"
        if case .noCredit = status {
            return Notice(dedupeKey: switchModelNoticeKey, style: .warning, symbol: "creditcard",
                          title: "\(subject) OpenRouter credit", body: "Add credit to use extra models.",
                          actions: [NoticeAction(title: "Add Credit", kind: .openURL(OpenRouterLinks.credits), isPrimary: true)],
                          lifetime: .seconds(8))
        }
        let body = switch status {
        case .invalid: "OpenRouter rejected yours. Update it to use extra models."
        case .failed: "\(Brand.name) can’t read yours. Check it to use extra models."
        default: "Add one to use extra models."
        }
        return Notice(dedupeKey: switchModelNoticeKey, style: .warning, symbol: "key.fill",
                      title: "\(subject) an OpenRouter key", body: body,
                      actions: [NoticeAction(title: "Add Key", kind: .openHub(.models), isPrimary: true)],
                      lifetime: .seconds(8))
    }

    /// Every extra model's limit is (nearly) used up by this recording.
    private func rejectSwitchTooLong() {
        pillModel.shakeTrigger += 1
        let minutes = Int((OpenRouterClient.maxRecordingDuration / 60).rounded())
        toasts.post(Notice(dedupeKey: Self.switchModelNoticeKey, style: .info, symbol: "timer",
                           title: "Too long for Gemini",
                           body: "Gemini takes up to \(minutes) minutes of audio. This dictation stays on \(settings.selectedEngine.shortName).",
                           lifetime: .seconds(6)))
    }

    static let switchModelNoticeKey = "switchModel"

    /// Starts the hint timer when a push-to-talk hold confirms, and hides the hint when the hold ends.
    private func updateSwitchHint() {
        guard case .listening(let downAt) = machine.capture else {
            switchHintTask?.cancel()
            switchHintTask = nil
            switchHintHold = nil
            if pillModel.showsTabHint { pillModel.showsTabHint = false }
            return
        }
        guard switchHintHold != downAt else { return }
        switchHintHold = downAt
        switchHintTask?.cancel()
        guard runsTimers else { return }
        let delay = max(0, downAt + switchHintDelay - clock())
        switchHintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.showSwitchHintIfDue()
        }
    }

    /// The hint timer's action (tests call it directly): a push-to-talk hold on the main model that has lasted
    /// `switchHintDelay` shows the Switch model hint, its first `AppSettings.switchHintLimit` times.
    func showSwitchHintIfDue() {
        guard case .listening(let downAt) = machine.capture, clock() - downAt >= switchHintDelay - 0.01,
              !pillModel.showsTabHint, modelOverride == nil, canSwitchModels,
              settings.shortcuts[.switchModel] != nil,
              settings.switchHintShownCount < AppSettings.switchHintLimit else { return }
        settings.switchHintShownCount += 1
        pillModel.showsTabHint = true
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

    /// A one-shot error shake. PillModel keeps the flourish on screen for its minimum time and settles back by
    /// itself, even when the next `refreshPill` already asks for rest.
    /// `message` says it in words inside the capsule instead of the glyph and the shake.
    private func flashError(message: String? = nil) {
        lastErrorFlashAt = clock()
        onDictationFailed?()
        showErrorFlash(message: message)
    }

    /// Only a real recording suppresses the shake. The dots of a press that hasn't committed hold it back
    /// until the press folds away (a quick tap, an fn combo), so the shake is never lost to it.
    private func showErrorFlash(message: String? = nil) {
        guard !machine.capture.isListeningOrLocked else { return }
        if machine.capture.isUncommittedPress, !pressKeepsProcessing {
            isErrorFlashDeferred = true
            deferredErrorMessage = message
            return
        }
        isErrorFlashDeferred = false
        deferredErrorMessage = nil
        // Leave any recording phase first, so the shake lands on the idle/processing pill.
        refreshPill()
        // Turns an idle or processing pill into the error flash, or re-shakes one already showing. Set after the
        // refresh: leaving for rest or processing clears the words.
        pillModel.errorMessage = message
        pillModel.shakeTrigger += 1
    }

    /// Plays the shake held back during a press once the press has folded away, or drops it if the press
    /// committed.
    private func replayDeferredErrorFlash() {
        guard isErrorFlashDeferred, !machine.capture.isUncommittedPress else { return }
        isErrorFlashDeferred = false
        guard machine.capture == .idle else { return }
        lastErrorFlashAt = clock()
        showErrorFlash(message: deferredErrorMessage)
    }

    private func refreshPill() {
        let idle: PillPhase = hasPendingWork ? .processing : .rest
        let phase: PillPhase
        switch machine.capture {
        case .arming:
            // From key-down on: an empty equalizer until the first buffer, then the voice. Over a job in
            // flight, the processing pill (already on screen) waits for the press to commit; once the job is
            // gone, the held key shows its dots again unless the job's shake is still on screen.
            let showsShake = pillModel.visiblePhase == .error
            phase = pressKeepsProcessing && (hasPendingWork || showsShake) ? idle : .listening
        case .tapPending:
            phase = pressKeepsProcessing ? idle : .listening
        case .listening:
            phase = .listening
        case .locked, .lockedStopPending:
            phase = .locked
        case .idle:
            phase = idle
        }
        // An idle request doesn't cut the error flourish short: PillModel holds it for its minimum time.
        if pillModel.phase != phase { pillModel.phase = phase }
        // The chip stays through processing until the dictation's text lands.
        let session = phase.isRecording || modelOverride != nil
            ? modelOverride
            : (phase == .processing ? processingSessionModel : nil)
        if pillModel.sessionModel != session { pillModel.sessionModel = session }

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

    /// The choice of the newest dictation still being transcribed or pasted (Hub jobs don't count): an extra model
    /// or clean-up.
    private var processingSessionModel: ModelChoice? {
        let jobs = (deliveringJob.map { [$0] } ?? []) + queue
        guard let newest = jobs.last(where: { $0.delivery != .historyOnly }) else { return nil }
        if newest.engine.isSwitchModel { return .engine(newest.engine) }
        return newest.cleansUp ? .cleanup : nil
    }

    private func stateDidChange() {
        if hotkeys.isBusy != machine.isBusy { hotkeys.isBusy = machine.isBusy }
        if hotkeys.isRecording != machine.isRecording { hotkeys.isRecording = machine.isRecording }
        updateSwitchHint()
        let count = queue.count + (isDelivering ? 1 : 0)
        if pendingJobCount != count { pendingJobCount = count }
        var transcribing: [UUID: EngineID] = [:]
        var running: [UUID: TranscriptVersionKind] = [:]
        for job in (deliveringJob.map { [$0] } ?? []) + queue where job.recording != nil {
            transcribing[job.id] = job.engine
            running[job.id] = job.isCleaningUp
                ? .cleanup(of: job.engine, by: job.cleanupModel ?? settings.cleanupModel) : .transcription(job.engine)
        }
        for (id, kind) in historyCleanups { running[id] = kind }
        if transcribingEngines != transcribing { transcribingEngines = transcribing }
        if runningVersions != running { runningVersions = running }
        refreshPill()
        replayDeferredErrorFlash()
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
            sounds.setDictationActive(next != .idle)
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

import AppKit
import Observation

/// What the menu bar icon reflects.
enum DictationActivity: Equatable, Sendable { case idle, recording, processing }

/// Why a version asked for from Home didn't come: its row says so until it's dismissed or something else is made
/// for the recording.
struct HomeFailure: Equatable, Sendable {
    /// What was being made.
    var kind: TranscriptVersionKind
    /// Said after `kind.failureTitle`, which names the model already: "It took too long.", "OpenAI is unavailable."
    var reason: String
    /// The recording's audio couldn't be read, so trying again can't help.
    var isRecordingGone = false

    /// A transcription whose recording couldn't be read.
    static func recordingGone(_ kind: TranscriptVersionKind) -> HomeFailure {
        HomeFailure(kind: kind, reason: "Recording no longer kept", isRecordingGone: true)
    }
}

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
    /// Replaces how long a clean-up may take to start answering (`CleanupModel.timeout(forCharacterCount:)`).
    @ObservationIgnored var cleanupTimeoutOverride: TimeInterval?
    /// Replaces how long a job waits for its local model before saying so (`modelWaitNoticeDelay`).
    @ObservationIgnored var waitNoticeDelayOverride: TimeInterval?
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
    /// What is being made for each recording right now, by recording id: a dictation's transcription or clean-up,
    /// or Home work (`homeWork`). History shows it in the row, and its Versions menu offers nothing else for that
    /// recording meanwhile.
    private(set) var runningVersions: [UUID: TranscriptVersionKind] = [:]
    /// What Home is making for each recording right now, by recording id (its row can cancel it).
    private(set) var homeWork: [UUID: TranscriptVersionKind] = [:]
    /// Why the last version Home asked for didn't come, by recording id, until dismissed or new work starts.
    private(set) var homeFailures: [UUID: HomeFailure] = [:]
    /// The shortcut's event tap has been down for longer than `shortcutNoticeGrace`: fn does nothing.
    private(set) var isShortcutUnavailable = false
    /// What this dictation goes to instead of the main model (Switch model, the pill's menu); nil for the main
    /// model. It lasts while the dictation records: its job keeps it, the next dictation starts on the main model,
    /// and an Undo-resume brings back the canceled dictation's.
    private(set) var modelOverride: ModelChoice?
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
    /// as it is (its width, its count), so an fn tap or an fn combo doesn't disturb it.
    @ObservationIgnored private var pressKeepsProcessing = false
    @ObservationIgnored private var retained: [UUID: Recording] = [:]
    @ObservationIgnored private var retainedOrder: [UUID] = []
    @ObservationIgnored private var lastCancelledID: UUID?
    /// The engine each canceled recording kept for Undo was dictated with (Undo resumes on its model).
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
    /// The task making each `homeWork` version, by recording id.
    @ObservationIgnored private var homeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var didShowSecureInputNotice = false
    /// The mic was opened for this recording: its device notice ("Using X instead", the AirPods hint) is
    /// decided once the user commits to dictating, so fn combos and quick taps don't use it up.
    @ObservationIgnored private var deviceNoticeDue = false
    @ObservationIgnored private var announcedFallbacks: Set<String> = []
    @ObservationIgnored private var bluetoothHintQuota = DailyQuota(limit: 1)
    /// The notice of each job waiting for its local model (`postModelWaitNotice`), by job id.
    @ObservationIgnored private var waitNoticeIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var isStarted = false
    /// The job whose recording is being finished by the current effect batch (its stop cue waits for the tail).
    @ObservationIgnored private var finishingJob: Job?
    @ObservationIgnored private var isTapAvailable = true
    @ObservationIgnored private var shortcutNoticeTask: Task<Void, Never>?

    private static let retainedLimit = 8
    /// Audio kept in memory for Undo and Retry, in seconds, past which the oldest recordings History also has on disk
    /// are let go (`retain`): an hour-long recording alone is 230 MB of samples.
    @ObservationIgnored var retainedSecondsLimit: TimeInterval = 30 * 60
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
        pillModel.unavailableReason = { [weak self] choice in self?.unavailableReason(choice) }
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
        history.onRemove = { [weak self] ids in self?.entriesRemoved(ids) }
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
        case .cycleEngineRepeat: repeatCycle()
        }
    }

    /// The Switch model shortcut: the next model for the dictation being recorded, in the order of the lineup from
    /// the main model on (`ModelLineup.cycle`), back to the main model after the last.
    func cycleEngine() {
        send(.cycleEngine)
    }

    /// The pill's model menu (hands-free): `choice` for the dictation being recorded, any model of the cycle.
    func selectModelForCurrentDictation(_ choice: ModelChoice) {
        guard machine.isRecording else { return }
        let target: ModelChoice? = choice == settings.lineup.main ? nil : choice
        guard target != modelOverride else { return }
        if let target, let refusal = switchRefusal(target) {
            rejectSwitch(blocked: [(target, refusal)])
            return
        }
        switchModel(to: target)
        stateDidChange()
    }

    /// The model the dictation being recorded goes to: the one picked for it, else the main model.
    var effectiveChoice: ModelChoice { modelOverride ?? settings.lineup.main }

    /// The engine that hears it: `effectiveChoice`'s, with Parakeet where `AppSettings.parakeetEngine` runs it.
    var effectiveEngine: EngineID { effectiveChoice.engine(parakeet: settings.parakeetEngine) }

    /// The Switch model shortcut can do something: the cycle has another model that can take this dictation now
    /// (the main model always can).
    var canSwitchModels: Bool {
        let lineup = settings.lineup
        return lineup.cycle.contains { $0 != effectiveChoice && ($0 == lineup.main || switchRefusal($0) == nil) }
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
        if engine.isLocal { return localRefusal(engine) }
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

    /// Why the local model `engine` can't take a dictation at all, or nil when the job can wait for it (downloading,
    /// installed, loading, ready, no disk scan yet) or load it once more (a failed load).
    private func localRefusal(_ engine: EngineID) -> AppError? {
        switch models.state(of: engine) {
        case .notInstalled where !models.hasScannedDisk:
            // Launch: the first disk scan hasn't landed yet. The job waits for it.
            return nil
        case .notInstalled: return .modelNotDownloaded(engine)
        case .failed(let message):
            switch models.lastErrors[engine] {
            case .modelLoadFailed?:
                // The files are complete: the job loads the model once more before giving up, and a failure then
                // keeps the recording for Retry.
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

    /// Queues the job right away (FIFO order is decided at release), then waits for the recorder's tail.
    private func finishCapture(tail: TimeInterval) {
        let resumedID = continuing?.id
        continuing = nil
        guard captureDevice.isCapturing else { return }
        // A resumed dictation keeps the canceled recording's id, already while its tail is captured.
        let job = Job(recording: nil, engine: effectiveEngine, targetPID: inserter.frontmostPID(), id: resumedID)
        job.cleansUp = effectiveChoice.cleansUp
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
            keepCancelled(recording, engine: effectiveEngine, cleansUp: effectiveChoice.cleansUp, notify: notify)
        } else if let resumed {
            // A resumed dictation whose mic failed: its audio (the kept part at least) stays for another Undo.
            keepCancelled(recording ?? resumed, engine: effectiveEngine, cleansUp: effectiveChoice.cleansUp,
                          notify: true)
        }
    }

    /// Keeps a canceled recording for Undo (and in history when it's long).
    private func keepCancelled(_ recording: Recording, engine: EngineID, cleansUp: Bool = false, notify: Bool) {
        guard recording.duration >= Self.undoMinimumDuration else { return }
        retain(recording)
        cancelledEngines[recording.id] = engine
        if cleansUp { cleanupIDs.insert(recording.id) } else { cleanupIDs.remove(recording.id) }
        lastCancelledID = recording.id
        if recording.duration >= Self.saveCancelledMinimumDuration {
            let file = history.saveAudio(recording)
            history.upsert(TranscriptEntry(
                id: recording.id, createdAt: recording.startedAt, text: "", engine: engine,
                status: .cancelled, audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
                audioFileName: file))
        }
        guard notify else { return }
        postCanceled(recording)
    }

    /// "Dictation canceled · Undo", nothing more (a long enough recording is in History too). After an Undo that
    /// couldn't pick the recording up, `note` says why.
    private func postCanceled(_ recording: Recording, note: String? = nil) {
        toasts.post(Notice(dedupeKey: "dictation.canceled", style: .info, symbol: "xmark.circle",
                           title: "Dictation canceled", body: note,
                           actions: [NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true)],
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
        // Cues that play while the mic is open (start/lock pings, a model switch's tick, a notice's alert) stay out
        // of what the engine hears.
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
        /// The app that was frontmost when recording stopped: the text is pasted at the cursor there.
        let targetPID: pid_t?
        var outcome: Outcome?
        var task: Task<Void, Never>?
        var hintTask: Task<Void, Never>?
        var generation = 0
        var playsStopCue = false
        var isCancelled = false
        /// A dictation on clean-up: its transcript is tidied before it's pasted.
        var cleansUp = false
        /// Its text is with the clean-up model now: the transcription itself is done.
        var isCleaningUp: Bool { uncleaned != nil }
        /// The finished transcript being cleaned up, kept should the clean-up be canceled.
        var uncleaned: TranscriptResult?
        /// How many tokens its model is thinking or writing, as far as the stream shows (`streamed(_:for:)`): nil until
        /// the first streamed character, and always for Parakeet. The processing pill shows the newest job's.
        var count: PillTokenCount?
        /// How characters of the stream under way turn into that count, learned from History for its model.
        var estimate = TokenEstimate()
        private let placeholderID: UUID

        /// `id`: the id the recording will have (a resumed dictation's), when it is known before the audio is.
        init(recording: Recording?, engine: EngineID, targetPID: pid_t?, id: UUID? = nil) {
            self.recording = recording
            self.engine = engine
            self.targetPID = targetPID
            self.placeholderID = id ?? UUID()
        }

        /// The recording's id once it exists (history, retry and undo all key on it).
        var id: UUID { recording?.id ?? placeholderID }

        func stop() {
            task?.cancel()
            hintTask?.cancel()
        }
    }

    /// Starts transcribing right away; the result is pasted at the cursor in `targetPID` after every older job's. A
    /// recording that is already queued, being delivered, being recorded on or worked on from Home is never queued
    /// twice.
    /// `cleansUp`: a dictation on clean-up, picked up again.
    func enqueue(_ recording: Recording, engine: EngineID, targetPID: pid_t?, cleansUp: Bool = false) {
        guard !isInFlight(recording.id) else { return }
        let job = Job(recording: recording, engine: engine, targetPID: targetPID)
        job.cleansUp = cleansUp
        queue.append(job)
        _ = machine.handle(.jobStarted, now: clock())
        run(job)
        stateDidChange()
    }

    private func run(_ job: Job) {
        guard let recording = job.recording else { return }
        // Its paste puts the clipboard back: that is read while the dictation is transcribed, not at the ⌘V.
        inserter.prepareToPaste()
        job.stop()
        job.generation += 1
        job.outcome = nil
        let generation = job.generation
        let engine = job.engine
        job.uncleaned = nil
        job.count = nil
        job.estimate = TokenEstimate.learned(from: history.entries, modelID: engine.openRouterModelID)
        // Only a streamed answer has tokens to count: Gemini's (Parakeet has none).
        let progress = engine.cloudAPI == .chatCompletions ? streamProgress(for: job, generation: generation) : nil
        job.task = Task { [weak self] in
            guard let self else { return }
            var outcome = await self.transcribe(recording, engine: engine, progress: progress)
            guard !Task.isCancelled, job.generation == generation else { return }
            if case .success(let result, _) = outcome, self.cleansUp(job, result) {
                // Still processing as far as the pill goes: the text is pasted once it's tidied (or given up on).
                job.uncleaned = result
                job.count = nil
                job.estimate = TokenEstimate.learned(from: self.history.entries,
                                                     modelID: CleanupModel.default.openRouterModelID)
                job.hintTask?.cancel()
                self.dismissWaitNotice(for: job.id)
                self.stateDidChange()
                let cleanup = await self.runCleanup(result.text, of: result.engine, by: .default,
                                                    progress: self.streamProgress(for: job, generation: generation))
                guard !Task.isCancelled, job.generation == generation else { return }
                outcome = .success(result, cleanup: cleanup)
            }
            job.outcome = outcome
            job.hintTask?.cancel()
            self.dismissWaitNotice(for: job.id)
            self.drain()
        }
        // A cloud model that takes long is simply at work (Esc cancels it); only a local model that isn't there yet
        // is worth a word.
        guard engine.isLocal else { return }
        let hintDelay = waitNoticeDelayOverride ?? Self.modelWaitNoticeDelay
        job.hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hintDelay))
            guard !Task.isCancelled, let self, job.outcome == nil, !job.isCleaningUp,
                  job.generation == generation else { return }
            self.postModelWaitNotice(for: job)
        }
    }

    /// Where a dictation job's stream reports how far it has come: to the main actor, and on to the pill while the
    /// job still runs this attempt (`generation`).
    private func streamProgress(for job: Job, generation: Int) -> @Sendable (ChatStreamProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, job.generation == generation else { return }
                self.streamed(progress, for: job.id)
            }
        }
    }

    /// A dictation's stream has come this far: its count, for the processing pill. Only a streamed request counts:
    /// Gemini's, or a clean-up's (not the Parakeet transcript before it). Ignored once the job has its outcome or
    /// isn't queued any more (canceled, delivered), and for anything else (Home's work never counts).
    func streamed(_ progress: ChatStreamProgress, for id: UUID) {
        guard let job = queue.first(where: { $0.id == id }), job.outcome == nil,
              job.engine.cloudAPI == .chatCompletions || job.isCleaningUp else { return }
        job.count = job.estimate.count(for: progress)
        refreshPill()
    }

    /// `background`: Home's work, which lets dictations have the local model first. `progress`: a dictation's, for
    /// the pill (Home never passes one).
    private func transcribe(_ recording: Recording, engine: EngineID, background: Bool = false,
                            progress: (@Sendable (ChatStreamProgress) -> Void)? = nil) async -> Outcome {
        do {
            if engine.isLocal, transcribeOverride == nil { try await waitForLocalModel(engine) }
            let result: TranscriptResult
            if let transcribeOverride {
                result = try await transcribeOverride(recording, engine)
            } else {
                result = try await transcription.transcribe(recording, engine: engine, background: background,
                                                            progress: progress)
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

    /// A dictation on clean-up is tidied before it's delivered.
    private func cleansUp(_ job: Job, _ result: TranscriptResult) -> Bool {
        job.cleansUp && CleanupModel.canClean(result.engine)
            && !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Tidies `text` (written by `source`) with the clean-up model `model`, giving up when its answer hasn't started
    /// within its timeout (`TranscriptionService.cleanUp`: one that streams runs to its end). Never throws: a failure,
    /// a timeout or an empty answer is `.failed`, and the original text stands. `progress`: a dictation's, for the
    /// pill (Home never passes one).
    private func runCleanup(_ text: String, of source: EngineID, by model: CleanupModel,
                            progress: (@Sendable (ChatStreamProgress) -> Void)? = nil) async -> CleanupOutcome {
        // A key already known not to work would fail the request too: no round trip, and the notice says why.
        if let keyProblem = openRouterKeyProblem {
            Log.engine.info("Clean-up skipped: \(keyProblem.code, privacy: .public)")
            return .failed(keyProblem)
        }
        let timeout = cleanupTimeoutOverride ?? CleanupModel.timeout(forCharacterCount: text.count)
        do {
            var result: TranscriptResult
            if let cleanupOverride {
                result = try await Self.within(timeout, source: source) { try await cleanupOverride(text, source) }
            } else {
                result = try await transcription.cleanUp(text, of: source, by: model, timeout: timeout,
                                                         progress: progress)
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

    /// Why the OpenRouter key can't pay for a request right now, as far as the account knows (nil while it may: a
    /// check in progress, offline, a failed check). Clean-up and Switch model ask before any round trip.
    private var openRouterKeyProblem: AppError? {
        switch account.status {
        case .missing: .openRouterMissingKey
        case .invalid(let message): .openRouterInvalidKey(message)
        case .noCredit where account.status.isKeyLimitReached: .openRouterKeyLimit("")
        case .noCredit: .openRouterNoCredits("")
        case .failed where account.isKeyUnreadable: .openRouterKeyUnreadable
        case .checking, .valid, .offline, .failed: nil
        }
    }

    /// `work`, or `AppError.timeout(source)` once `seconds` pass (then `work` is cancelled): the deadline of
    /// `cleanupOverride`, which streams nothing.
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

    /// How long a dictation waits for a local model that is still downloading or loading before a notice says so
    /// and offers another model.
    nonisolated static let modelWaitNoticeDelay: TimeInterval = 3

    /// A model still downloading can't transcribe yet: wait for it (Esc cancels a dictation, Cancel Home's work).
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
                if engine == settings.parakeetEngine { models.prepare(engine) }
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

    /// Queued, being delivered, being recorded on again (Undo), or worked on from Home.
    func isInFlight(_ id: UUID) -> Bool {
        queue.contains { $0.id == id } || deliveringJob?.id == id || continuing?.id == id || homeWork[id] != nil
    }

    /// False when there was nothing left to cancel (the last result is already being delivered).
    @discardableResult
    private func cancelNewestJob() -> Bool {
        guard let job = queue.last else { return false }
        queue.removeLast()
        job.stop()
        job.isCancelled = true
        dismissWaitNotice(for: job.id)
        _ = machine.handle(.jobEnded, now: clock())
        if let recording = job.recording, let uncleaned = job.uncleaned, job.outcome == nil {
            keepUncleaned(job, recording, uncleaned)
        } else if let recording = job.recording {
            keepCancelled(recording, engine: job.engine, cleansUp: job.cleansUp, notify: true)
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
        history.upsert(TranscriptEntry(
            id: job.id, createdAt: recording.startedAt, engine: result.engine, status: .success,
            audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
            audioFileName: history.saveAudio(recording), versions: [version]))
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
            // The raw transcript is always a version; a clean-up that worked is another, and the one delivered.
            var versions = [result.version(text: text)]
            var delivered = text
            var cleanupFailed = false
            var cleanupError: AppError?
            let cleanupModel = CleanupModel.default
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
            // Kept as long as the entry, so History can transcribe it again with another model. Saved again even when
            // a failed or canceled row had it: an Undo-resumed dictation's file holds only the part before the cancel.
            history.upsert(TranscriptEntry(
                id: job.id, createdAt: recording.startedAt, engine: result.engine, status: .success,
                audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
                audioFileName: history.saveAudio(recording), versions: versions))
            for version in versions { resolveGeneration(of: version, entryID: job.id) }
            // Only what is pasted follows General → Pasting: History, the cards and Copy keep the text as it came.
            let insertion = await insert(pasted(delivered), expectedPID: job.targetPID)
            handleInsertion(insertion, text: delivered, isDictation: true)
            if cleanupFailed { postCleanupFallback(error: cleanupError, model: cleanupModel) }
        }
    }

    /// The quiet word that a dictation's clean-up didn't happen: its original text was pasted instead. A key
    /// problem (every dictation would hit it until it's fixed or clean-up is off) points to Models.
    private func postCleanupFallback(error: AppError?, model: CleanupModel) {
        let keyProblem = error?.stopsEveryCloudModel == true && error != .offline
        toasts.post(Notice(dedupeKey: "cleanup.fallback", style: .info, symbol: "wand.and.sparkles",
                           title: "Couldn’t clean up · pasted the original",
                           body: Self.cleanupFailureReason(error, model: model),
                           actions: keyProblem ? [NoticeAction(title: "Open Models", kind: .openHub(.models), isPrimary: true)] : [],
                           lifetime: .seconds(keyProblem ? 6 : 4)))
    }

    /// Asks OpenRouter about a delivered cloud version in the background when its response left something out: the
    /// provider, the cost, or for a chat answer (one with token usage) how long the generation took, which a stream
    /// cut short before its accounting chunk never says. Fills only what's missing, on the entry's version unless
    /// that version changed meanwhile (deleted, or made again).
    private func resolveGeneration(of version: TranscriptVersion, entryID: UUID) {
        let metadata = version.metadata
        guard let generationID = metadata.generationID,
              metadata.provider == nil || metadata.costUSD == nil
                || (metadata.usage != nil && metadata.generationTime == nil) else { return }
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
        let file = history.saveAudio(recording)
        retain(recording)
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

    // MARK: - Insertion

    private func insert(_ text: String, expectedPID: pid_t?) async -> InsertionOutcome {
        if let insertOverride { return await insertOverride(text, expectedPID) }
        return await inserter.insert(text, expectedPID: expectedPID)
    }

    private func copy(_ text: String) {
        if let copyOverride { copyOverride(text) } else { inserter.copy(text) }
    }

    /// `text` as the app pastes it: with General → Pasting's space after it and without its final period
    /// (`PastedText`).
    private func pasted(_ text: String) -> String {
        PastedText.prepare(text, addsSpace: settings.addsSpaceAfterText, removesFinalPeriod: settings.removesFinalPeriod)
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
            // Nothing goes on the clipboard unasked: the card holds the text until the user copies it.
            var notice = AppError.accessibilityMissing.notice(recordingID: nil, fallbackEngine: nil)
            notice.transcript = text
            notice.actions = [NoticeAction(title: "Allow Access", kind: .openSettingsPane(.accessibility), isPrimary: true),
                              NoticeAction(title: "Copy", kind: .copyText(text))]
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

    /// The last transcript is pasted where the user is typing, and the clipboard stays as it was, as with every paste.
    /// When it can't be pasted, a card holds it with Copy, like a dictation's.
    func pasteLast() {
        guard let text = history.lastSuccessfulText else {
            toasts.post(Notice(dedupeKey: "pasteLast.empty", style: .info, symbol: "text.badge.xmark",
                               title: "Nothing to paste yet", body: "Dictate something first.", lifetime: .seconds(3)))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome: InsertionOutcome
            let pasted = self.pasted(text)
            if let override = self.pasteLastOverride {
                outcome = await override(pasted)
            } else {
                outcome = await self.inserter.insert(pasted, expectedPID: nil)
            }
            self.handleInsertion(outcome, text: text, isDictation: false)
        }
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
                let pasted = self.pasted(text)
                if let override = self.pasteNowOverride {
                    outcome = await override(pasted)
                } else {
                    outcome = await self.inserter.pasteNow(pasted)
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
            // "Use Parakeet v3": where Parakeet runs, and Parakeet in place of a Gemini main model.
            models.select(engine)
            if settings.lineup.main == .gemini { settings.lineup.main = .parakeet }
            let main = settings.lineup.main, parakeet = settings.parakeetEngine
            toasts.post(Notice(dedupeKey: "engine.selected", style: .success, symbol: main.symbolName(parakeet: parakeet),
                               title: "Now using \(main.title(parakeet: parakeet))", lifetime: .seconds(3)))
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

    // MARK: - Home work

    /// The Versions menu: the row shows its version of `kind` (switching needs no audio).
    func showVersion(_ kind: TranscriptVersionKind, of entryID: UUID) {
        history.selectVersion(kind, of: entryID)
    }

    /// Home's Versions menu (and a failed or canceled row's Retry): makes the version of `kind` the entry doesn't
    /// have yet, into history only. A transcription needs the recording; a clean-up only the text it tidies. A
    /// version the entry already has is shown instead of being made twice.
    ///
    /// Home work stays in Home. It runs in a task of its own beside dictations, never in their queue, so it never
    /// holds a dictation's paste back, and Esc neither waits for it nor cancels it. The local model still takes one
    /// recording at a time: Home's waits behind every dictation's, though one it already started finishes first. No
    /// pill, notice or sound: its row shows it running (with Cancel, `cancelHomeWork(for:)`), then the new version,
    /// or why it didn't come (`homeFailures`). Deleting the row cancels it.
    func makeVersion(_ kind: TranscriptVersionKind, of entry: TranscriptEntry) {
        switch kind {
        case .transcription(let engine): retry(entry, with: engine)
        case .cleanup(let source, let model): cleanUp(entry, of: source, by: model)
        }
    }

    /// Home: "Retry" of a failed or canceled row, or "Transcribe With" of a transcript, with any engine the
    /// transcript has no version from (one it has is shown instead). Nothing happens while something else runs for
    /// the recording.
    func retry(_ entry: TranscriptEntry, with engine: EngineID) {
        let id = entry.id
        guard !isInFlight(id) else { return }
        let kind = TranscriptVersionKind.transcription(engine)
        if let current = history.entry(id: id), current.status == .success, current.hasVersion(kind) {
            showVersion(kind, of: id)
            return
        }
        guard let recording = recording(for: id) else {
            homeFailures[id] = .recordingGone(kind)
            return
        }
        beginHomeWork(kind, for: id)
        homeTasks[id] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.transcribe(recording, engine: engine, background: true)
            guard self.endHomeWork(for: id) else { return }
            self.land(outcome, of: recording, engine: engine)
        }
    }

    /// Clean Up from Home: `model` tidies the entry's `source` transcript, which becomes a new version and the
    /// current one. Works without the audio. Nothing happens while something else runs for the recording, or for a
    /// transcript with no text.
    private func cleanUp(_ entry: TranscriptEntry, of source: EngineID, by model: CleanupModel) {
        let id = entry.id
        guard entry.status == .success, CleanupModel.canClean(source), !isInFlight(id),
              let raw = history.entry(id: id)?.version(.transcription(source)),
              !raw.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let kind = TranscriptVersionKind.cleanup(of: source, by: model)
        guard !(history.entry(id: id)?.hasVersion(kind) ?? false) else {
            showVersion(kind, of: id)
            return
        }
        beginHomeWork(kind, for: id)
        homeTasks[id] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runCleanup(raw.text, of: source, by: model)
            guard self.endHomeWork(for: id) else { return }
            switch outcome {
            case .cleaned(let result):
                let version = result.version(kind)
                guard var current = self.history.entry(id: id), current.status == .success else { return }
                current.addVersion(version)
                self.history.upsert(current)
                self.resolveGeneration(of: version, entryID: id)
            case .failed(let error):
                guard self.history.entry(id: id) != nil else { return }
                self.homeFailures[id] = HomeFailure(kind: kind, reason: Self.homeFailureReason(error, making: kind))
            }
        }
    }

    /// Home's Cancel in the row: stops what is being made for the recording. Nothing of it lands; the entry stays as
    /// it was.
    func cancelHomeWork(for id: UUID) {
        guard let task = homeTasks.removeValue(forKey: id) else { return }
        task.cancel()
        homeWork[id] = nil
        stateDidChange()
    }

    /// The row's failure line, dismissed.
    func dismissHomeFailure(for id: UUID) {
        homeFailures[id] = nil
    }

    /// Rows deleted (Delete, Clear All, Auto-delete, the oldest past the history's limit) take their Home work along:
    /// nothing of it would land, and there is no Cancel left to stop it. The Hub's Undo brings the row back as it was.
    private func entriesRemoved(_ ids: [UUID]) {
        for id in ids {
            cancelHomeWork(for: id)
            homeFailures[id] = nil
        }
    }

    /// Home starts making `kind` for the recording: the row shows it running, and its last failure goes.
    private func beginHomeWork(_ kind: TranscriptVersionKind, for id: UUID) {
        homeFailures[id] = nil
        homeWork[id] = kind
        stateDidChange()
    }

    /// A Home task is done making its version: false when it was canceled meanwhile, and then nothing lands.
    private func endHomeWork(for id: UUID) -> Bool {
        guard !Task.isCancelled else { return false }
        homeTasks[id] = nil
        homeWork[id] = nil
        stateDidChange()
        return true
    }

    /// A transcription made from Home lands in its row. A transcript gets it as a new version, the current one (same
    /// row, date and audio; the others stay in its Versions menu); a failed or canceled dictation becomes that
    /// transcript. When it doesn't come, a transcript stays as it was and its row says why; a failed or canceled
    /// dictation's row says why itself, as History always has. An entry deleted meanwhile isn't brought back.
    private func land(_ outcome: Outcome, of recording: Recording, engine: EngineID) {
        let id = recording.id
        guard let entry = history.entry(id: id) else { return }
        let failure: AppError
        switch outcome {
        case .success(let result, _):
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                failure = .noSpeech
                break
            }
            forget(id)
            // An older notice's Retry or Undo would transcribe it yet again, or record on.
            toasts.dismiss(recordingID: id)
            let version = result.version(text: text)
            if entry.status == .success {
                var updated = entry
                updated.addVersion(version)
                history.upsert(updated)
            } else {
                history.upsert(TranscriptEntry(
                    id: id, createdAt: recording.startedAt, engine: result.engine, status: .success,
                    audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
                    audioFileName: history.saveAudio(recording), versions: [version]))
            }
            resolveGeneration(of: version, entryID: id)
            return
        case .failure(let error):
            failure = error
        }
        Log.engine.error("Home transcription failed: \(failure.code, privacy: .public)")
        let kind = TranscriptVersionKind.transcription(engine)
        guard entry.status != .success else {
            homeFailures[id] = HomeFailure(kind: kind, reason: Self.homeFailureReason(failure, making: kind))
            return
        }
        // Its row says why itself, naming the model as a failed dictation's does: the notice's title ("Gemini Flash
        // took too long"), or for an engine's own failure (titled only "Couldn't transcribe") the line naming it.
        let notice = failure.notice(recordingID: nil, fallbackEngine: nil, engine: engine)
        let reason = if case .engineFailed = failure, let body = notice.body { body } else { notice.title }
        history.upsert(TranscriptEntry(
            id: id, createdAt: recording.startedAt, text: "", engine: engine, status: .failed,
            audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
            errorMessage: reason, audioFileName: history.saveAudio(recording) ?? entry.audioFileName))
    }

    /// Why a version asked for from Home didn't come, as its row says it after "Couldn't transcribe with Gemini
    /// Flash" or "Couldn't clean up with GPT-6 Luna": that names the model already, so this says "It". A key, credit
    /// or connection problem reads the same whichever model it stopped.
    nonisolated static func homeFailureReason(_ error: AppError?, making kind: TranscriptVersionKind) -> String {
        switch (error, kind) {
        case (nil, _): "It returned no text."
        case (.timeout?, _): "It took too long."
        case (.openRouterTruncated?, _): "It stopped before finishing."
        case (.openRouterRefused?, .cleanup), (.openRouterBadRequest?, .cleanup): "It couldn’t process the text."
        case (let error?, .cleanup(_, let model)): cleanupFailureReason(error, model: model)
        case (.openRouterRefused?, _), (.openRouterBadRequest?, _): "It couldn’t process this recording."
        case (.engineFailed?, _): "It ran into a problem."
        case (.modelNotDownloaded?, _): "It isn’t downloaded yet."
        case (.modelLoadFailed?, _): "It couldn’t be loaded."
        case (.openRouterNoRoute?, _): "It isn’t available for your key."
        case (.openRouterProviderUnavailable?, .transcription(let engine)) where engine.cloudAPI == .transcriptions:
            "OpenRouter couldn’t reach its provider."
        case (let error?, .transcription(let engine)):
            accountFailureReason(error) ?? error.notice(recordingID: nil, fallbackEngine: nil, engine: engine).title
        }
    }

    /// Why a clean-up didn't happen, in a sentence about the text and the clean-up model that tried (the error
    /// notices' own titles speak of Gemini and recordings).
    nonisolated static func cleanupFailureReason(_ error: AppError?, model cleanupModel: CleanupModel) -> String {
        if let error, let reason = accountFailureReason(error) { return reason }
        let model = cleanupModel.shortName
        return switch error {
        case nil: "\(model) returned no text."
        case .timeout?: "\(model) took too long."
        case .openRouterNoRoute?: "OpenRouter found no \(cleanupModel.providerName) route for your key."
        case .openRouterProviderUnavailable?: "\(cleanupModel.providerName) is unavailable."
        case .openRouterTruncated?: "\(model) stopped before finishing."
        case .openRouterRefused?, .openRouterBadRequest?: "\(model) couldn’t process the text."
        case let error?: error.notice(recordingID: nil, fallbackEngine: nil).title
        }
    }

    /// A key, credit or connection problem, or OpenRouter's own: the same sentence whichever model it stopped.
    private nonisolated static func accountFailureReason(_ error: AppError) -> String? {
        switch error {
        case .openRouterMissingKey: "Add your OpenRouter key in Models."
        case .openRouterKeyUnreadable: "Your OpenRouter key couldn’t be read from the Keychain."
        case .openRouterInvalidKey: "Your OpenRouter key was rejected."
        case .openRouterNoCredits: "You’re out of OpenRouter credit."
        case .openRouterKeyLimit: "Your OpenRouter key hit its spending limit."
        case .openRouterRateLimited: "OpenRouter is rate-limiting requests. Try again in a moment."
        case .openRouterServer: "OpenRouter ran into a problem."
        case .offline: "You’re offline."
        default: nil
        }
    }

    // MARK: - Retry and Undo from notices

    /// A notice's Retry or "Use … Instead": the dictation is transcribed again and pasted where the user is now.
    private func retry(recordingID: UUID?, engine: EngineID?) {
        guard let id = recordingID else { return }
        if let waiting = queue.first(where: { $0.id == id }) {
            // Still in the queue ("Use Parakeet v3 · Cloud Instead" while Parakeet loads): switch engines in place.
            if let engine, engine != waiting.engine, waiting.outcome == nil, !waiting.isCleaningUp {
                waiting.engine = engine
                run(waiting)
                stateDidChange()
            }
            return
        }
        guard !isInFlight(id) else { return }
        // Transcribed since (from Home): its text is in History, and a notice never pastes it or makes it again.
        guard history.entry(id: id)?.status != .success else { return }
        guard let recording = recording(for: id) else {
            postRecordingGone()
            return
        }
        let chosen = engine ?? history.entry(id: id)?.engine ?? settings.mainEngine
        enqueue(recording, engine: chosen, targetPID: inserter.frontmostPID(), cleansUp: cleanupIDs.contains(id))
    }

    /// Undo of a cancel: the dictation picks up again hands-free, its kept audio first, and nothing is transcribed
    /// or pasted until the user stops (Esc cancels it again, all of it).
    private func undo(recordingID: UUID?) {
        guard let id = recordingID, let recording = recording(for: id) else {
            postRecordingGone()
            return
        }
        // Transcribed since (from Home): there's no dictation left to pick up, and its text is in History.
        guard history.entry(id: id)?.status != .success else { return }
        // Already being transcribed (from Home) or recorded on.
        guard !isInFlight(id) else { return }
        guard !machine.isRecording else {
            postCanceled(recording, note: "Finish this dictation first, then Undo.")
            return
        }
        let engine = cancelledEngines[id] ?? history.entry(id: id)?.engine ?? settings.mainEngine
        let choice = ModelChoice(engine: engine, cleansUp: cleanupIDs.contains(id))
        resumeRequest = recording
        // The same dictation goes on, with the model it had; `send` drops it if the mic won't start.
        modelOverride = choice == settings.lineup.main ? nil : choice
        send(.resume(prefix: recording.duration))
        resumeRequest = nil
        if continuing?.id != id {
            // The mic didn't start (its error is showing): the audio stays for another Undo.
            postCanceled(recording, note: Self.undoResumesHint)
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
                           body: engine == settings.mainEngine ? "Hold \(pttHint) and start talking." : nil,
                           lifetime: .seconds(5), sound: .success))
    }

    /// Downloads and loads run in the background (often after the window that started them closed), so
    /// their failures surface as notices. A failed dictation's notice for the same error shares the dedupe key.
    private func modelFailed(_ engine: EngineID, _ error: AppError) {
        // A load nothing needs now (Parakeet on this Mac while the lineup runs it elsewhere) stays quiet.
        if case .modelLoadFailed = error, !(engine == settings.parakeetEngine && settings.usesLocalParakeet) { return }
        // A load Home work waits for: its row says why. A dictation that needs the model says it in its own notice.
        if case .modelLoadFailed = error, homeWork.values.contains(.transcription(engine)) { return }
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

    /// A notice's Retry or Undo found no audio to use (Home says it in the row: `HomeFailure.recordingGone`).
    private func postRecordingGone() {
        toasts.post(Notice(dedupeKey: "recording.gone", style: .warning, symbol: "waveform.slash",
                           title: "That recording is gone",
                           body: "Its audio isn’t on this Mac any more.",
                           lifetime: .seconds(5), sound: .alert))
    }

    // MARK: - Machine notices

    private func post(_ kind: DictationMachine.NoticeKind) {
        switch kind {
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

    /// A dictation still waiting for its local model says so: "Still downloading Parakeet v3 · 42%" or "Getting
    /// Parakeet v3 ready…", with "Use … Instead" when another model could take it now. Nothing once the model is at
    /// work.
    private func postModelWaitNotice(for job: Job) {
        var fallback = usableFallback(excluding: job.engine)
        var notice: Notice
        switch models.state(of: job.engine) {
        case .downloading(let progress):
            notice = AppError.modelDownloading(job.engine, progress.fraction).notice(recordingID: nil, fallbackEngine: nil)
        case .preparing, .installed:
            // Only an engine that can start right now is any faster than waiting for this load.
            fallback = usableFallback(excluding: job.engine, readyNow: true)
            notice = AppError.modelPreparing(job.engine).notice(recordingID: nil, fallbackEngine: nil)
        case .notInstalled, .ready, .failed:
            return
        }
        notice.dedupeKey = "slow.\(job.id)"
        notice.recordingID = job.id
        notice.lifetime = .sticky
        notice.actions = fallback.map {
            [NoticeAction(title: "Use \($0.shortName) Instead", kind: .retryWith($0), isPrimary: true)]
        } ?? []
        waitNoticeIDs[job.id] = notice.id
        toasts.post(notice)
    }

    private func dismissWaitNotice(for jobID: UUID) {
        guard let id = waitNoticeIDs.removeValue(forKey: jobID) else { return }
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
    /// Cancel is always Esc.
    private var cancelHint: String { Shortcut.escape.compactDescription }

    // MARK: - Engines and recordings

    /// Engines to fall back to from `engine`, in order: the same model on the other side (Parakeet · Cloud ↔
    /// Parakeet on this Mac); from Gemini, Parakeet where `parakeet` runs it first, then on the other side. Only
    /// Parakeet: Gemini is never offered in another model's place.
    static func fallbackCandidates(for engine: EngineID, parakeet: EngineID) -> [EngineID] {
        let ordered = [engine.localCounterpart, engine.cloudCounterpart].compactMap { $0 }
            + [parakeet] + EngineID.parakeetRuntimes
        var candidates: [EngineID] = []
        for candidate in ordered where candidate != engine && !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    /// The engine offered in place of `engine`: "Retry with …" or "Use … Instead" for a saved recording, "Use …"
    /// when nothing was recorded. The first of `fallbackCandidates` that can run it: a local model once it's
    /// downloaded (one that isn't loaded yet loads for the retry, so from Gemini Parakeet on this Mac, where it runs,
    /// comes before Parakeet · Cloud even then), or only once it's loaded with `readyNow`; a cloud one while the key is
    /// valid, unless `error` (the key's, the credit's, the connection's) would stop it too.
    private func usableFallback(excluding engine: EngineID, after error: AppError? = nil,
                                readyNow: Bool = false) -> EngineID? {
        Self.fallbackCandidates(for: engine, parakeet: settings.parakeetEngine).first { candidate in
            if candidate.isLocal {
                switch models.state(of: candidate) {
                case .ready: return true
                case .installed, .preparing: return !readyNow
                case .notInstalled, .downloading, .failed: return false
                }
            }
            guard case .valid = account.status else { return false }
            return error?.stopsEveryCloudModel != true
        }
    }

    private func retain(_ recording: Recording) {
        retained[recording.id] = recording
        retainedOrder.removeAll { $0 == recording.id }
        retainedOrder.append(recording.id)
        while retainedOrder.count > Self.retainedLimit {
            let evicted = retainedOrder.removeFirst()
            retained[evicted] = nil
            cancelledEngines[evicted] = nil
            cleanupIDs.remove(evicted)
        }
        // Past `retainedSecondsLimit` of audio, the oldest recordings whose audio History keeps on disk let go of
        // their samples (Undo and Retry read them back, and keep their model); the newest always stays.
        var seconds = retained.values.reduce(0) { $0 + $1.duration }
        for id in retainedOrder.dropLast() where seconds > retainedSecondsLimit {
            guard let kept = retained[id], history.entry(id: id)?.audioFileName != nil else { continue }
            retained[id] = nil
            seconds -= kept.duration
        }
    }

    /// The recordings kept in memory right now: tests.
    var retainedRecordingIDs: Set<UUID> { Set(retained.keys) }

    private func forget(_ id: UUID) {
        retained[id] = nil
        retainedOrder.removeAll { $0 == id }
        cancelledEngines[id] = nil
        cleanupIDs.remove(id)
    }

    // MARK: - Switch model

    /// Why `choice` can't take the dictation being recorded now, or nil when it can: the OpenRouter key when it goes
    /// through it (`openRouterKeyProblem`), then Parakeet on this Mac when it uses it (`localRefusal`).
    private func switchRefusal(_ choice: ModelChoice) -> AppError? {
        let parakeet = settings.parakeetEngine
        if choice.needsOpenRouter(parakeet: parakeet), let keyProblem = openRouterKeyProblem { return keyProblem }
        if choice.usesLocalParakeet(parakeet: parakeet) { return localRefusal(parakeet) }
        return nil
    }

    /// The pill menu's suffix for a model that can't take this dictation now ("Needs key", "Not downloaded"); nil for
    /// the main model, which always can, and for any other that can.
    private func unavailableReason(_ choice: ModelChoice) -> String? {
        guard choice != settings.lineup.main, switchRefusal(choice) != nil else { return nil }
        let parakeet = settings.parakeetEngine
        return EngineReadiness.of(choice, parakeet: parakeet, localState: models.state(of: parakeet),
                                  keyStatus: account.status, localError: models.lastErrors[parakeet])
            .unavailableReason ?? "Unavailable"
    }

    /// The Switch model key held down: a step, with its tick, at every autorepeat of the keyboard, however fast
    /// (the ticks ring over each other). Nothing to switch to, it stays quiet: the press already said why.
    private func repeatCycle() {
        guard machine.isRecording, canSwitchModels else { return }
        send(.cycleEngine)
    }

    /// The machine's `.cycleEngine`: the next model of the cycle after this dictation's, wrapping around to the main
    /// model. One that can't take the dictation now (`switchRefusal`) is skipped; with none to land on, the switch is
    /// rejected.
    private func advanceEngine() {
        let lineup = settings.lineup
        let cycle = lineup.cycle
        let current = effectiveChoice
        let start = cycle.firstIndex(of: current) ?? 0
        var blocked: [(choice: ModelChoice, error: AppError)] = []
        for offset in 1...cycle.count {
            let choice = cycle[(start + offset) % cycle.count]
            guard choice != current else { continue }
            if choice != lineup.main, let refusal = switchRefusal(choice) {
                blocked.append((choice, refusal))
                continue
            }
            switchModel(to: choice == lineup.main ? nil : choice)
            // Found it: the hint has nothing left to teach.
            if settings.switchHintShownCount < AppSettings.switchHintLimit {
                settings.switchHintShownCount = AppSettings.switchHintLimit
            }
            return
        }
        // A cycle of one has nothing to step to, and nothing to say.
        guard !blocked.isEmpty else { return }
        rejectSwitch(blocked: blocked)
    }

    /// Another choice for this dictation: the pill's chip and a soft tick.
    private func switchModel(to choice: ModelChoice?) {
        modelOverride = choice
        pillModel.engineChipPulse &+= 1
        if pillModel.showsTabHint { pillModel.showsTabHint = false }
        playCue(.modelSwitch)
    }

    /// A switch that can't happen: the model stays, the pill shakes, and a notice says why. What the OpenRouter key
    /// can't pay for (every step it blocked), or else the first blocked step's own problem ("Parakeet v3 isn’t
    /// downloaded yet", with Download).
    private func rejectSwitch(blocked: [(choice: ModelChoice, error: AppError)]) {
        pillModel.shakeTrigger += 1
        let keyProblem = openRouterKeyProblem
        let keyBlocked = blocked.filter { keyProblem != nil && $0.error == keyProblem }.map(\.choice)
        if !keyBlocked.isEmpty {
            if case .invalid = account.status { account.refreshIfStale(maxAge: 30) }
            toasts.post(Self.switchWithoutKeyNotice(account.status, blocked: keyBlocked))
        } else if let first = blocked.first {
            var notice = first.error.notice(recordingID: nil, fallbackEngine: nil, engine: settings.parakeetEngine)
            notice.dedupeKey = Self.switchModelNoticeKey
            toasts.post(notice)
        }
    }

    /// What a switch to models the OpenRouter key can't pay for (`blocked`, in cycle order) says: "Gemini needs an
    /// OpenRouter key", "Clean-up and Gemini need OpenRouter credit".
    static func switchWithoutKeyNotice(_ status: KeyStatus, blocked: [ModelChoice]) -> Notice {
        let list = ModelChoice.sentenceList(blocked.isEmpty ? [.gemini] : blocked)
        let subject = "\(list.names) \(list.isPlural ? "need" : "needs")"
        if case .noCredit = status {
            return Notice(dedupeKey: switchModelNoticeKey, style: .warning, symbol: "creditcard",
                          title: "\(subject) OpenRouter credit", body: "Add credit to switch models.",
                          actions: [NoticeAction(title: "Add Credit", kind: .openURL(OpenRouterLinks.credits), isPrimary: true)],
                          lifetime: .seconds(8))
        }
        let body = switch status {
        case .invalid: "OpenRouter rejected yours. Update it to switch models."
        case .failed: "\(Brand.name) can’t read yours. Check it to switch models."
        default: "Add one to switch models while dictating."
        }
        return Notice(dedupeKey: switchModelNoticeKey, style: .warning, symbol: "key.fill",
                      title: "\(subject) an OpenRouter key", body: body,
                      actions: [NoticeAction(title: "Add Key", kind: .openHub(.models), isPrimary: true)],
                      lifetime: .seconds(8))
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
        // The dictation's model from key-down until its text lands: the tint (and the chip) stay through processing.
        let session: ModelChoice? = if phase.isRecording || modelOverride != nil {
            effectiveChoice
        } else if phase == .processing, let job = pillJob {
            ModelChoice(engine: job.engine, cleansUp: job.cleansUp)
        } else {
            nil
        }
        if pillModel.sessionModel != session { pillModel.sessionModel = session }
        // The same job's count: with several in flight, the newest one's.
        let count = phase == .processing ? pillJob?.count : nil
        if pillModel.tokenCount != count { pillModel.tokenCount = count }

        if phase.isRecording, let started = machine.recordingStartedAt {
            let wallStart = Date().addingTimeInterval(started - clock())
            if pillModel.recordingStartedAt.map({ abs($0.timeIntervalSince(wallStart)) > 0.5 }) ?? true {
                pillModel.recordingStartedAt = wallStart
            }
        } else if pillModel.recordingStartedAt != nil {
            pillModel.recordingStartedAt = nil
        }
    }

    /// The job the processing pill speaks for: the newest dictation still being transcribed, or the one being pasted.
    private var pillJob: Job? { queue.last ?? deliveringJob }

    private func stateDidChange() {
        if hotkeys.isBusy != machine.isBusy { hotkeys.isBusy = machine.isBusy }
        if hotkeys.isRecording != machine.isRecording { hotkeys.isRecording = machine.isRecording }
        updateSwitchHint()
        let count = queue.count + (isDelivering ? 1 : 0)
        if pendingJobCount != count { pendingJobCount = count }
        var running = homeWork
        for job in (deliveringJob.map { [$0] } ?? []) + queue where job.recording != nil {
            running[job.id] = job.isCleaningUp
                ? .cleanup(of: job.engine, by: .default) : .transcription(job.engine)
        }
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

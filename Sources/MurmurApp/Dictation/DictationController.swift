import AppKit
import Observation

/// What the menu bar icon reflects.
enum DictationActivity: Equatable, Sendable { case idle, recording, processing }

/// The capture surface the controller drives. `AudioRecorder` is the real one; tests substitute a fake so
/// no microphone is ever opened.
@MainActor
protocol DictationRecorder: AnyObject {
    var isCapturing: Bool { get }
    func start(preferredDeviceUID: String?) throws
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
    /// True while a finished dictation has nowhere sensible to go (onboarding's key-practice steps): it is
    /// kept in history and the pill flashes success, but nothing is pasted.
    @ObservationIgnored var deliversQuietly: (() -> Bool)?

    // Seams for tests: time, capture, transcription and insertion can be replaced.
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var captureDevice: any DictationRecorder
    @ObservationIgnored var transcribeOverride: (@MainActor (Recording, EngineID) async throws -> TranscriptResult)?
    @ObservationIgnored var insertOverride: (@MainActor (String, pid_t?) async -> InsertionOutcome)?
    @ObservationIgnored var copyOverride: (@MainActor (String) -> Void)?

    private(set) var machine = DictationMachine()
    private(set) var activity: DictationActivity = .idle
    /// Recordings waiting to be transcribed or delivered, oldest first.
    private(set) var pendingJobCount = 0

    @ObservationIgnored private var timers: [DictationMachine.TimerID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var isDelivering = false
    /// A refusal found at key-down, reported only if the user commits to dictating (fn+← must stay silent).
    @ObservationIgnored private var pendingRefusal: MurmurError?
    /// When the last success/error flourish was requested (pill clicks during it don't start a recording).
    @ObservationIgnored private var lastFlash: (phase: PillPhase, at: TimeInterval)?
    @ObservationIgnored private var retained: [UUID: Recording] = [:]
    @ObservationIgnored private var retainedOrder: [UUID] = []
    @ObservationIgnored private var lastCancelledID: UUID?
    @ObservationIgnored private var noSpeechQuota = DailyQuota(limit: 3)
    @ObservationIgnored private var historyHintQuota = DailyQuota(limit: 3)
    @ObservationIgnored private var didShowSecureInputNotice = false
    /// A device notice ("Using X instead", the AirPods hint) held until the user commits to dictating.
    @ObservationIgnored private var pendingDeviceNotice: Notice?
    @ObservationIgnored private var announcedFallbacks: Set<String> = []
    @ObservationIgnored private var bluetoothHintQuota = DailyQuota(limit: 1)
    @ObservationIgnored private var slowNoticeIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var isStarted = false
    /// The job whose recording is being finished by the current effect batch (its stop cue waits for the tail).
    @ObservationIgnored private var finishingJob: Job?

    private static let retainedLimit = 8
    private static let undoMinimumDuration: TimeInterval = 1
    private static let saveCancelledMinimumDuration: TimeInterval = 20
    private static let minimumVoicedSeconds = 0.25

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
        stateDidChange()
    }

    // MARK: - Inputs

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .pttDown: send(.pttDown)
        case .pttUp: send(.pttUp)
        case .pttInterrupted: send(.pttInterrupted)
        case .handsFreeToggle: send(.handsFreeToggle)
        case .cancel: send(.cancel)
        case .pasteLast: pasteLast()
        case .copyLast: copyLast()
        }
    }

    /// Menu bar "Start Hands-free Dictation" / "Finish Dictation".
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
        let effects = machine.handle(input, now: clock())
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
        machine.config.maxDuration = settings.maxRecordingDuration
        machine.config.doublePressEnabled = settings.doublePressForHandsFree
    }

    // MARK: - Effects

    private func execute(_ effects: [DictationMachine.Effect]) {
        defer { finishingJob = nil }
        for effect in effects {
            switch effect {
            case .startCapture:
                guard let failure = beginCapture() else { continue }
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
                cancelNewestJob()
            case .notice(let kind):
                post(kind)
            }
        }
    }

    /// Returns the reason capture can't start, or nil once the mic is live.
    private func beginCapture() -> MurmurError? {
        if let refusal = captureRefusal() { return refusal }
        guard !captureDevice.isCapturing else { return nil }
        do {
            try captureDevice.start(preferredDeviceUID: settings.microphoneUID)
            pendingDeviceNotice = captureDevice === recorder ? deviceNotice(for: recorder.lastChoice) : nil
            return nil
        } catch let error as MurmurError {
            return error
        } catch {
            return .microphoneNotResponding(error.localizedDescription)
        }
    }

    /// Checks made before the mic opens: permission and whether the selected engine can run at all.
    /// Downloading or loading models are fine: the job waits for them.
    func captureRefusal() -> MurmurError? {
        switch permissions.microphone {
        case .granted:
            break
        case .notDetermined where AudioRecorder.isMicrophoneAuthorized:
            // PermissionsCenter reads TCC asynchronously; right after launch it may not know yet.
            break
        case .notDetermined, .denied:
            return .microphonePermissionDenied
        }
        let engine = settings.selectedEngine
        if engine.isLocal {
            switch models.state(of: engine) {
            case .notInstalled: return .modelNotDownloaded(engine)
            case .failed(let message): return .modelLoadFailed(engine, message)
            case .downloading, .installed, .preparing, .ready: return nil
            }
        }
        switch account.status {
        case .missing: return .openRouterMissingKey
        case .invalid(let message): return .openRouterInvalidKey(message)
        case .checking, .valid, .noCredit, .offline, .failed: return nil
        }
    }

    /// Queues the job right away (FIFO order is decided at release), then waits for the recorder's tail.
    private func finishCapture(tail: TimeInterval) {
        guard captureDevice.isCapturing else { return }
        let delivery: Delivery = deliversQuietly?() == true ? .quiet : .paste(targetPID: inserter.frontmostPID())
        let job = Job(recording: nil, engine: settings.selectedEngine, delivery: delivery)
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
        if job.playsStopCue { sounds.play(.stop) }
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
            toasts.post(MurmurError.microphoneSilent.notice(recordingID: nil, fallbackEngine: nil))
            flash(.error)
            return false
        }
        if recording.speech.voicedSeconds < Self.minimumVoicedSeconds {
            if noSpeechQuota.take() {
                toasts.post(MurmurError.noSpeech.notice(recordingID: nil, fallbackEngine: nil))
            }
            flash(.error)
            return false
        }
        return true
    }

    private func cancelCapture(keepForUndo: Bool, notify: Bool) {
        guard captureDevice.isCapturing else { return }
        let recording = captureDevice.cancel()
        guard keepForUndo, let recording else { return }
        keepCancelled(recording, engine: settings.selectedEngine, notify: notify)
    }

    private func keepCancelled(_ recording: Recording, engine: EngineID, notify: Bool) {
        guard recording.duration >= Self.undoMinimumDuration else { return }
        retain(recording)
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
        var actions = [NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true)]
        var body: String?
        if saved {
            let days = settings.keepFailedRecordingsDays
            body = days > 0 ? "Saved in History for \(days) \(days == 1 ? "day" : "days")." : nil
            if historyHintQuota.take() {
                actions.append(NoticeAction(title: "Open History", kind: .openHub(.home)))
            }
        }
        toasts.post(Notice(dedupeKey: "dictation.canceled", style: .info, symbol: "xmark.circle",
                           title: "Dictation canceled", body: body, actions: actions,
                           lifetime: .seconds(6), recordingID: recording.id))
    }

    private func playCue(_ sound: SoundEffect) {
        sounds.play(sound)
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
        /// History and a success flash, no paste and no notice.
        case quiet
    }

    fileprivate enum Outcome {
        case success(TranscriptResult)
        case failure(MurmurError)
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
        private let placeholderID = UUID()

        init(recording: Recording?, engine: EngineID, delivery: Delivery) {
            self.recording = recording
            self.engine = engine
            self.delivery = delivery
        }

        /// The recording's id once it exists (history, retry and undo all key on it).
        var id: UUID { recording?.id ?? placeholderID }

        func stop() {
            task?.cancel()
            hintTask?.cancel()
        }
    }

    /// Starts transcribing right away; the result is delivered after every older job's.
    func enqueue(_ recording: Recording, engine: EngineID, delivery: Delivery) {
        guard !queue.contains(where: { $0.id == recording.id }) else { return }
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
        job.hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(engine.isLocal ? 3 : 12))
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
        } catch let error as MurmurError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.engineFailed(engine, "Canceled"))
        } catch {
            return .failure(.engineFailed(engine, error.localizedDescription))
        }
    }

    /// A model still downloading can't transcribe yet: wait for it (Esc cancels the job).
    private func waitForLocalModel(_ engine: EngineID) async throws {
        while true {
            try Task.checkCancellation()
            switch models.state(of: engine) {
            case .downloading:
                try await Task.sleep(for: .milliseconds(300))
            case .installed:
                if engine == settings.selectedEngine { models.prepare(engine) }
                return
            case .notInstalled:
                throw MurmurError.modelNotDownloaded(engine)
            case .preparing, .ready, .failed:
                return
            }
        }
    }

    private func drain() {
        defer { stateDidChange() }
        guard !isDelivering, let head = queue.first, let outcome = head.outcome else { return }
        isDelivering = true
        queue.removeFirst()
        Task { [weak self] in
            guard let self else { return }
            await self.deliver(head, outcome)
            self.isDelivering = false
            _ = self.machine.handle(.jobEnded, now: self.clock())
            self.drain()
        }
    }

    private func cancelNewestJob() {
        guard let job = queue.last else { return }
        queue.removeLast()
        job.stop()
        job.isCancelled = true
        dismissSlowNotice(for: job.id)
        _ = machine.handle(.jobEnded, now: clock())
        if let recording = job.recording {
            keepCancelled(recording, engine: job.engine, notify: true)
        }
        drain()
    }

    private func deliver(_ job: Job, _ outcome: Outcome) async {
        guard let recording = job.recording else { return }
        switch outcome {
        case .failure(let error):
            deliverFailure(job, error)
        case .success(let result):
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                deliverFailure(job, .emptyResult(result.engine))
                return
            }
            forget(job.id)
            history.upsert(TranscriptEntry(
                id: job.id, createdAt: recording.startedAt, text: text, engine: result.engine,
                status: .success, audioDuration: recording.duration,
                voicedSeconds: recording.speech.voicedSeconds,
                processingTime: result.processingTime, costUSD: result.costUSD))
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
            case .quiet:
                flash(.success)
            }
        }
    }

    private func deliverFailure(_ job: Job, _ error: MurmurError) {
        guard let recording = job.recording else { return }
        let file = history.saveAudio(recording)
        retain(recording)
        let notice = error.notice(recordingID: job.id, fallbackEngine: readyFallback(excluding: job.engine))
        history.upsert(TranscriptEntry(
            id: job.id, createdAt: recording.startedAt, text: "", engine: job.engine, status: .failed,
            audioDuration: recording.duration, voicedSeconds: recording.speech.voicedSeconds,
            errorMessage: notice.title, audioFileName: file ?? history.entry(id: job.id)?.audioFileName))
        Log.engine.error("Transcription failed: \(error.code, privacy: .public)")
        toasts.post(notice)
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
        switch outcome {
        case .pasted:
            // A paste landing mid-recording must not leak its tick into the new recording.
            if !machine.isRecording { sounds.play(.paste) }
            if celebrate { flash(.success) }
        case .noEditableTarget:
            toasts.post(transcriptCard(text, title: "Nowhere to paste",
                                       body: "Or click a text field and press \(pasteLastHint).", pasteHere: false))
        case .targetChanged:
            toasts.post(transcriptCard(text, title: "You switched apps", body: "Paste here, or copy it.", pasteHere: true))
        case .accessibilityMissing:
            copy(text)
            var notice = MurmurError.accessibilityMissing.notice(recordingID: nil, fallbackEngine: nil)
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

    // MARK: - Paste / copy last

    func pasteLast() {
        guard let text = history.lastSuccessfulText else {
            toasts.post(Notice(dedupeKey: "pasteLast.empty", style: .info, symbol: "text.badge.xmark",
                               title: "Nothing to paste yet", body: "Dictate something first.", lifetime: .seconds(3)))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.insert(text, expectedPID: nil)
            self.handleInsertion(outcome, text: text, celebrate: false)
        }
    }

    func copyLast() {
        guard let text = history.lastSuccessfulText else {
            toasts.post(Notice(dedupeKey: "copyLast.empty", style: .info, symbol: "text.badge.xmark",
                               title: "Nothing to copy yet", body: "Dictate something first.", lifetime: .seconds(3)))
            return
        }
        copy(text)
        toasts.post(Notice(dedupeKey: "copyLast", style: .success, symbol: "doc.on.doc",
                           title: "Copied last transcript", lifetime: .seconds(1.5)))
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
                let outcome = await self.inserter.pasteNow(text)
                if outcome == .pasted { self.sounds.play(.paste) }
            }
            return
        default:
            break
        }
        toasts.dismiss(notice.id)
        switch action.kind {
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
        case .showPillNow:
            settings.pillHiddenUntil = nil
        case .dismiss, .copyText, .pasteText:
            break
        }
    }

    /// Hub history "Retry" (failed or canceled rows) with any engine.
    func retry(_ entry: TranscriptEntry, with engine: EngineID) {
        guard !queue.contains(where: { $0.id == entry.id }) else { return }
        guard let recording = recording(for: entry.id) else {
            postRecordingGone()
            return
        }
        enqueue(recording, engine: engine, delivery: .historyOnly)
    }

    private func retry(recordingID: UUID?, engine: EngineID?) {
        guard let id = recordingID else { return }
        if let waiting = queue.first(where: { $0.id == id }) {
            // Still in the queue ("Use Parakeet instead" while Whisper loads): switch engines in place.
            if let engine, engine != waiting.engine, waiting.outcome == nil {
                waiting.engine = engine
                run(waiting)
            }
            return
        }
        guard let recording = recording(for: id) else {
            postRecordingGone()
            return
        }
        let chosen = engine ?? history.entry(id: id)?.engine ?? settings.selectedEngine
        enqueue(recording, engine: chosen, delivery: .paste(targetPID: inserter.frontmostPID()))
    }

    /// Transcribes a canceled recording after all and pastes it wherever the cursor is now.
    private func undo(recordingID: UUID?) {
        guard let id = recordingID, let recording = recording(for: id) else {
            postRecordingGone()
            return
        }
        guard passesPreflight(recording) else { return }
        enqueue(recording, engine: settings.selectedEngine, delivery: .paste(targetPID: inserter.frontmostPID()))
    }

    private func startDownload(_ engine: EngineID) {
        models.download(engine)
        let size = engine.approxDownloadBytes.map { "About \(Fmt.bytes($0)). " } ?? ""
        toasts.post(Notice(dedupeKey: "download.\(engine.rawValue)", style: .info, symbol: "arrow.down.circle",
                           title: "Downloading \(engine.displayName)",
                           body: "\(size)Murmur lets you know when it’s ready.",
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
    private func modelFailed(_ engine: EngineID, _ error: MurmurError) {
        if case .modelLoadFailed = error, engine != settings.selectedEngine { return }
        toasts.post(error.notice(recordingID: nil, fallbackEngine: usableFallback(excluding: engine)))
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
                           body: "Murmur keeps audio only for failed or canceled dictations, and only for a while.",
                           lifetime: .seconds(5), sound: .alert))
    }

    // MARK: - Machine notices

    private func post(_ kind: DictationMachine.NoticeKind) {
        let minutes = settings.maxRecordingMinutes
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
                               body: "You pressed another key while holding \(pttHint).",
                               actions: [NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true)],
                               lifetime: .seconds(6), recordingID: id))
        case .deviceLostTranscribing:
            toasts.post(Notice(dedupeKey: "mic.lost", style: .warning, symbol: "mic.slash.fill",
                               title: "Microphone disconnected",
                               body: "Murmur is transcribing what you said up to that point.",
                               actions: [NoticeAction(title: "Choose Mic", kind: .chooseMicrophone)],
                               lifetime: .seconds(8), sound: .alert))
        case .captureFailed(let error):
            reportCaptureFailure(error)
        }
    }

    private func reportCaptureFailure(_ error: MurmurError) {
        if error == .microphonePermissionDenied, permissions.microphone == .notDetermined {
            let permissions = permissions
            Task { _ = await permissions.requestMicrophone() }
            toasts.post(Notice(dedupeKey: "mic.request", style: .info, symbol: "mic.fill",
                               title: "Allow microphone access",
                               body: "Choose Allow in the macOS prompt, then try again.",
                               lifetime: .seconds(8)))
        } else {
            toasts.post(error.notice(recordingID: nil, fallbackEngine: usableFallback(excluding: settings.selectedEngine)))
        }
        flash(.error)
    }

    private func postSlowNotice(for job: Job) {
        let fallback = readyFallback(excluding: job.engine)
        var notice: Notice
        switch models.state(of: job.engine) {
        case .downloading(let progress) where job.engine.isLocal:
            notice = MurmurError.modelDownloading(job.engine, progress.fraction).notice(recordingID: nil, fallbackEngine: nil)
        case .preparing where job.engine.isLocal, .installed where job.engine.isLocal:
            notice = MurmurError.modelPreparing(job.engine).notice(recordingID: nil, fallbackEngine: nil)
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

    /// A loaded local engine other than `engine`, offered as "Retry with …" for a saved recording.
    private func readyFallback(excluding engine: EngineID) -> EngineID? {
        EngineID.localEngines.first { $0 != engine && models.state(of: $0) == .ready }
    }

    /// A downloaded local engine other than `engine`, offered as "Use …" when nothing was recorded.
    private func usableFallback(excluding engine: EngineID) -> EngineID? {
        readyFallback(excluding: engine) ?? EngineID.localEngines.first {
            guard $0 != engine else { return false }
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
            retained[retainedOrder.removeFirst()] = nil
        }
    }

    private func forget(_ id: UUID) {
        retained[id] = nil
        retainedOrder.removeAll { $0 == id }
    }

    private func recording(for id: UUID) -> Recording? {
        if let kept = retained[id] { return kept }
        return history.entry(id: id).flatMap { history.loadRecording(for: $0) }
    }

    // MARK: - Pill and status

    private var hasPendingWork: Bool { !queue.isEmpty || isDelivering }

    /// A one-shot success check or error shake. PillModel keeps the flourish on screen for its minimum time
    /// and settles back by itself, even when the next `refreshPill` already asks for rest.
    private func flash(_ phase: PillPhase) {
        lastFlash = (phase, clock())
        guard !machine.capture.isListeningOrLocked else { return }
        // Leave any recording phase first, so the shake lands on the idle/processing pill.
        refreshPill()
        if phase == .error {
            // Turns an idle or processing pill into the error flash, or re-shakes one already showing.
            pillModel.shakeTrigger += 1
        } else {
            pillModel.phase = phase
        }
    }

    private func refreshPill() {
        let phase: PillPhase
        switch machine.capture {
        case .listening:
            phase = .listening
        case .locked, .lockedStopPending:
            phase = .locked
        case .idle, .arming, .tapPending:
            phase = hasPendingWork ? .processing : .rest
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
        showSecureInputNoticeIfNeeded()
        if !machine.isRecording {
            pendingDeviceNotice = nil
        } else if machine.capture.isListeningOrLocked, let notice = pendingDeviceNotice {
            pendingDeviceNotice = nil
            toasts.post(notice)
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

    /// Recording with the UI showing (arming is still invisible).
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

import AppKit
import Observation

/// Composition root, built once by the AppDelegate (or per snapshot via `preview()`).
@MainActor
final class AppEnvironment {
    let paths: AppPaths
    let settings: AppSettings
    let keyStore: KeyFileStore
    let levelMeter: LevelMeter
    let devices: AudioDeviceCatalog
    let recorder: AudioRecorder
    let openRouterClient: OpenRouterClient
    let account: OpenRouterAccount
    /// The user's OpenAI-compatible endpoint, which takes Gemini's requests instead of OpenRouter while it's set up
    /// and on.
    let proxy: VertexProxyAccount
    let models: ModelStore
    let transcription: TranscriptionService
    let history: HistoryStore
    /// Recorded calls, apart from History (`CallStore`), how they're noticed and recorded (`CallMonitor`), and
    /// transcribed (`CallTranscriber`).
    let calls: CallStore
    let callTranscriber: CallTranscriber
    let callMonitor: CallMonitor
    let permissions: PermissionsCenter
    let hotkeys: HotkeyMonitor
    let inserter: TextInserter
    let secureInput: SecureInputMonitor
    let launchAtLogin: LaunchAtLogin
    let sounds: SoundPlayer
    let pillModel: PillModel
    let toasts: ToastCenter
    let pill: PillController
    let dictation: DictationController
    let updates: UpdateCenter
    let windows: WindowCoordinator
    let menuBar: MenuBarController
    /// The diagnostic log's launch, settings, permissions and microphone lines, and Export Logs….
    let diagnostics: DiagnosticsCenter
    /// Preview environments never start services.
    let isPreview: Bool

    private var isStarted = false
    private var maintenanceTask: Task<Void, Never>?
    private var compressionTask: Task<Void, Never>?
    private var activationObserver: MainNotificationObserver?

    init(paths: AppPaths, settings: AppSettings, keyStore: KeyFileStore, levelMeter: LevelMeter,
         devices: AudioDeviceCatalog, recorder: AudioRecorder, openRouterClient: OpenRouterClient,
         account: OpenRouterAccount, proxy: VertexProxyAccount, models: ModelStore,
         transcription: TranscriptionService,
         history: HistoryStore, calls: CallStore, permissions: PermissionsCenter, hotkeys: HotkeyMonitor,
         inserter: TextInserter, secureInput: SecureInputMonitor, launchAtLogin: LaunchAtLogin,
         sounds: SoundPlayer, pillModel: PillModel, toasts: ToastCenter, pill: PillController,
         dictation: DictationController, updates: UpdateCenter, windows: WindowCoordinator,
         menuBar: MenuBarController, isPreview: Bool) {
        self.paths = paths
        self.settings = settings
        self.keyStore = keyStore
        self.levelMeter = levelMeter
        self.devices = devices
        self.recorder = recorder
        self.openRouterClient = openRouterClient
        self.account = account
        self.proxy = proxy
        self.models = models
        self.transcription = transcription
        self.history = history
        self.calls = calls
        let callModel: @MainActor () -> CallModel = { [settings] in settings.callModel }
        callTranscriber = CallTranscriber(store: calls,
                                          send: CallTranscriber.openRouter(client: openRouterClient, account: account,
                                                                           proxy: proxy, model: callModel),
                                          sendText: CallTranscriber.openRouterText(client: openRouterClient,
                                                                                   account: account, proxy: proxy,
                                                                                   model: callModel))
        callMonitor = CallMonitor(settings: settings, store: calls, transcriber: callTranscriber,
                                  dependencies: .live(settings: settings))
        self.permissions = permissions
        self.hotkeys = hotkeys
        self.inserter = inserter
        self.secureInput = secureInput
        self.launchAtLogin = launchAtLogin
        self.sounds = sounds
        self.pillModel = pillModel
        self.toasts = toasts
        self.pill = pill
        self.dictation = dictation
        self.updates = updates
        self.windows = windows
        self.menuBar = menuBar
        self.isPreview = isPreview
        diagnostics = DiagnosticsCenter(log: .shared, settings: settings, keyStore: keyStore, account: account,
                                        proxy: proxy, permissions: permissions, devices: devices)
        windows.environment = self
        menuBar.environment = self
        wire()
    }

    static func live() -> AppEnvironment {
        let paths = AppPaths.live()
        let settings = AppSettings()
        return assemble(
            paths: paths,
            settings: settings,
            keyStore: KeyFileStore(url: paths.keyFile),
            levelMeter: LevelMeter(),
            devices: AudioDeviceCatalog(),
            makeAccount: { keyStore, client in OpenRouterAccount(keyStore: keyStore, client: client) },
            proxy: VertexProxyAccount(keyStore: KeyFileStore(url: paths.vertexProxyKeyFile), settings: settings),
            models: ModelStore(paths: paths, settings: settings),
            history: HistoryStore(paths: paths, settings: settings),
            calls: CallStore(paths: paths, settings: settings),
            permissions: PermissionsCenter(),
            hotkeys: HotkeyMonitor(settings: settings),
            secureInput: SecureInputMonitor(),
            launchAtLogin: LaunchAtLogin(),
            makeUpdates: { settings, toasts in UpdateCenter.live(settings: settings, toasts: toasts, paths: paths) },
            isPreview: false
        )
    }

    /// In-memory everything with fixture data; nothing is started. `releases`: what the update feed lists (by
    /// default nothing newer than the preview's version).
    static func preview(releases: [Release] = PreviewFixtures.releases(upTo: PreviewFixtures.installedVersion)) -> AppEnvironment {
        let settings = AppSettings.inMemory()
        settings.onboardingCompleted = true
        return assemble(
            paths: .temporary(),
            settings: settings,
            keyStore: .inMemory(),
            levelMeter: .preview(level: 0.55),
            devices: .preview(),
            makeAccount: { _, _ in .preview(status: .valid(PreviewFixtures.keyInfo)) },
            proxy: .preview(status: .notSet, settings: settings),
            models: .preview(states: [.parakeet: .ready]),
            history: .preview(entries: PreviewFixtures.history()),
            calls: .preview(calls: []),
            permissions: .preview(mic: .granted, ax: .granted),
            hotkeys: .preview(),
            secureInput: .preview(),
            launchAtLogin: .preview(),
            makeUpdates: { settings, toasts in UpdateCenter.preview(settings: settings, toasts: toasts, releases: releases) },
            isPreview: true
        )
    }

    private static func assemble(
        paths: AppPaths, settings: AppSettings, keyStore: KeyFileStore, levelMeter: LevelMeter,
        devices: AudioDeviceCatalog,
        makeAccount: (KeyFileStore, OpenRouterClient) -> OpenRouterAccount,
        proxy: VertexProxyAccount,
        models: ModelStore, history: HistoryStore, calls: CallStore, permissions: PermissionsCenter,
        hotkeys: HotkeyMonitor,
        secureInput: SecureInputMonitor, launchAtLogin: LaunchAtLogin,
        makeUpdates: (AppSettings, ToastCenter) -> UpdateCenter, isPreview: Bool
    ) -> AppEnvironment {
        let recorder = AudioRecorder(levelMeter: levelMeter, devices: devices, settings: settings)
        let client = OpenRouterClient()
        let account = makeAccount(keyStore, client)
        let transcription = TranscriptionService(models: models, account: account, client: client, proxy: proxy)
        transcription.vocabulary = { [settings] in settings.dictionary.words }
        transcription.reasoningEffort = { [settings] in settings.reasoningEffort(for: $0) }
        let inserter = TextInserter()
        let sounds = SoundPlayer(settings: settings)
        let pillModel = PillModel(settings: settings, levelMeter: levelMeter)
        let toasts = ToastCenter()
        let pill = PillController(model: pillModel, toasts: toasts, settings: settings)
        let dictation = DictationController(
            settings: settings, recorder: recorder, transcription: transcription, models: models,
            account: account, history: history, inserter: inserter, hotkeys: hotkeys,
            permissions: permissions, sounds: sounds, pillModel: pillModel, toasts: toasts)
        return AppEnvironment(
            paths: paths, settings: settings, keyStore: keyStore, levelMeter: levelMeter, devices: devices,
            recorder: recorder, openRouterClient: client, account: account, proxy: proxy, models: models,
            transcription: transcription, history: history, calls: calls, permissions: permissions, hotkeys: hotkeys,
            inserter: inserter, secureInput: secureInput, launchAtLogin: launchAtLogin, sounds: sounds,
            pillModel: pillModel, toasts: toasts, pill: pill, dictation: dictation,
            updates: makeUpdates(settings, toasts),
            windows: WindowCoordinator(settings: settings), menuBar: MenuBarController(),
            isPreview: isPreview)
    }

    /// Cross-object references that are safe in previews too (no side effects).
    private func wire() {
        dictation.devices = devices
        dictation.secureInput = secureInput
        dictation.openHub = { [weak self] section in self?.windows.showHub(section) }
        dictation.onActivityChanged = { [weak self] activity in self?.menuBar.show(activity) }
        dictation.onDictationDelivered = { [weak self] in self?.updates.dictationDelivered() }
        dictation.onDictationFailed = { [weak self] in self?.updates.dictationFailed() }
        dictation.installUpdate = { [weak self] in self?.installUpdate() }
        updates.isDictationActive = { [weak dictation] in (dictation?.activity ?? .idle) != .idle }
        history.isInUse = { [weak dictation] id in dictation?.isInFlight(id) ?? false }
        // Each dictation is on disk while it's recorded and transcribed, until History has it (none in a preview).
        recorder.journal = history.journal
        let builder = menuBar.builder
        pillModel.contextMenuProvider = { builder.makeMenu(includeQuit: false) }
        inserter.eventTapActive = { [weak hotkeys] in hotkeys?.isTapActive ?? false }
        devices.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        // A key the user saved or removed replaces the one older builds kept in the Keychain: never asked for again.
        account.onKeyChanged = { [weak settings] in settings?.keychainKeyMigrated = true }
        // Key-down doesn't wait ~25 ms for TCC: the permissions center probes it off the main thread (again at
        // every capture start); only a state that isn't granted asks TCC here.
        recorder.isMicrophoneAllowed = { [weak permissions] in
            permissions?.microphone == .granted || AudioRecorder.isMicrophoneAuthorized
        }
        wireCalls()
    }

    /// A call's question is a toast (sticky: unanswered, the call waits in the Calls tab); deleting a call stops its
    /// transcription, or its recording.
    private func wireCalls() {
        callTranscriber.userName = { [settings] in settings.displayName }
        callTranscriber.vocabulary = { [settings] in settings.dictionary.words }
        calls.onRemove = { [weak self] ids in
            for id in ids { self?.callTranscriber.cancel(id) }
            self?.callMonitor.removed(ids)
        }
        callMonitor.onAsk = { [weak toasts] info in
            toasts?.post(.transcribeCall(info.id, service: info.title, never: CallExclusion.of(info)?.actionTitle))
        }
        callMonitor.onAnswered = { [weak toasts] id in toasts?.dismiss(dedupeKey: Notice.callQuestionKey(id)) }
        dictation.answerCall = { [weak callMonitor] id, answer in callMonitor?.answer(answer, callID: id) }
        // What the call engine notices, as brief notices above the pill; never over a dictation's pill.
        callMonitor.notices = CallNotices(toasts: toasts, settings: settings) { [weak dictation] in
            (dictation?.activity ?? .idle) != .idle
        }
    }

    /// Starts services in the SPEC §4.14 order.
    func start() {
        guard !isPreview, !isStarted else { return }
        isStarted = true
        do {
            try paths.ensureDirectories()
        } catch {
            Log.app.error("Couldn't create app folders: \(error.localizedDescription, privacy: .public)")
        }
        diagnostics.log.start(directory: paths.logs)
        // Before anything reads the key. Older builds kept it in the login keychain; reading it there may ask for the
        // keychain password, a last time.
        KeychainMigration.run(into: keyStore, from: .live, settings: settings)
        // After the migration, so the settings line knows whether a key is saved.
        diagnostics.start()
        history.load()
        calls.load()
        devices.start()
        permissions.refresh()
        models.start()
        let account = account
        Task { await account.validate() }
        let proxy = proxy
        if proxy.isConfigured { Task { await proxy.validate() } }
        sounds.preload()
        pill.start()
        dictation.start()
        permissions.onAccessibilityGranted = { [weak self] in self?.startHotkeys() }
        hotkeys.onTapAvailabilityChanged = { [weak self] available in
            DiagnosticLog.shared.event(.hotkeys, "tap.changed", ["available": available])
            if !available { self?.permissions.pollInBackground() }
            self?.dictation.shortcutAvailabilityChanged(available)
        }
        startHotkeys()
        secureInput.start()
        menuBar.start()
        observeDockIconSetting()
        windows.updateActivationPolicy()
        if !settings.onboardingCompleted {
            windows.showOnboarding()
        }
        observeAutoDelete()
        observeCallRecording()
        observeCallState()
        scheduleMaintenance()
        scheduleCompression()
        updates.start()
        activationObserver = MainNotificationObserver(center: .default, name: NSApplication.didBecomeActiveNotification) {
            [weak self] in self?.didBecomeActive()
        }
    }

    /// Coming back to transcribe-thing, often from System Settings or a browser: statuses that only change out there.
    private func didBecomeActive() {
        // Approved or removed in Login Items.
        launchAtLogin.refresh()
        // A key a request rejected or found out of credit may have been fixed on openrouter.ai.
        switch account.status {
        case .invalid, .noCredit: account.refreshIfStale(maxAge: 30)
        default: break
        }
        // A proxy key the proxy rejected may have been fixed on the proxy since.
        if case .keyRejected = proxy.status { proxy.refreshIfStale(maxAge: 30) }
    }

    /// Called at quit: persist what's pending and release the event tap.
    func stop() {
        diagnostics.stop()
        history.flush()
        inserter.flushPendingRestore()
        hotkeys.stop()
        maintenanceTask?.cancel()
        compressionTask?.cancel()
        updates.stop()
    }

    /// The pill's "Update": Software Update shows the download and the restart.
    func installUpdate() {
        windows.showHub(.softwareUpdate)
        updates.installUpdate()
    }

    /// The event tap needs Accessibility; until it's granted, PermissionsCenter polls and calls back here.
    /// A running monitor without a live tap retries right away (its own probe would take up to 3 s).
    private func startHotkeys() {
        guard !hotkeys.isTapActive else { return }
        // At launch no availability callback fires, so the result is passed on here.
        if hotkeys.start() {
            Log.app.info("Hotkeys active")
            DiagnosticLog.shared.event(.hotkeys, "tap.started", ["available": true])
            dictation.shortcutAvailabilityChanged(true)
        } else {
            DiagnosticLog.shared.event(.hotkeys, "tap.started", ["available": false])
            permissions.pollInBackground()
            dictation.shortcutAvailabilityChanged(false)
        }
    }

    private func observeDockIconSetting() {
        withObservationTracking {
            _ = settings.showDockIcon
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.windows.updateActivationPolicy()
                self?.observeDockIconSetting()
            }
        }
    }

    /// A shorter "Auto-delete history" deletes what it no longer keeps right away, not at the next maintenance
    /// pass.
    private func observeAutoDelete() {
        withObservationTracking {
            _ = settings.autoDeleteHistoryDays
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.history.deleteExpired()
                self?.calls.deleteExpired()
                self?.observeAutoDelete()
            }
        }
    }

    /// Calls are noticed while the setting isn't Off, from launch and from the moment it changes.
    private func observeCallRecording() {
        let mode = withObservationTracking {
            settings.callRecording
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCallRecording() }
        }
        if mode == .off { callMonitor.stop() } else { callMonitor.start() }
    }

    /// The menu bar's red dot while a call is recorded, asked about or kept.
    private func observeCallState() {
        let state = withObservationTracking {
            callMonitor.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCallState() }
        }
        menuBar.showCall(recording: CallsList.liveInfo(state) != nil)
    }

    /// transcribe-thing runs for weeks at a time: Auto-delete runs every hour, not only at launch (loading the
    /// history runs it too).
    private func scheduleMaintenance() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard !Task.isCancelled else { return }
                self?.history.deleteExpired()
                self?.calls.deleteExpired()
            }
        }
    }

    /// Once the launch has settled, the recordings older builds kept as WAV are compressed in the background.
    private func scheduleCompression() {
        compressionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let history = self?.history else { return }
            await history.compressLegacyRecordings()
        }
    }

    /// The device list changed (the catalog calls only after a scan that changed something, the launch scan
    /// included). A picked mic that is gone (AirPods put away, a USB mic unplugged) falls back to Automatic, so a
    /// choice always stays selected and the next dictation just works: Automatic follows macOS, which makes the
    /// AirPods the input again when they reconnect. When the gone mic is back, it's the pick again (unless the user
    /// picked another since), so a device that only dropped out for a moment doesn't lose its place. A capture
    /// already running is left alone (`deviceLost` handles it).
    private func devicesChanged() {
        if let lost = settings.microphoneUIDBeforeFallback, settings.microphoneUID == nil,
           InputDevicePolicy.isBack(lost, devices: devices.devices) {
            settings.microphoneUID = lost
            return
        }
        guard let pick = settings.microphoneUID,
              !InputDevicePolicy.keepsPick(pick, devices: devices.devices) else { return }
        settings.microphoneUID = nil
        settings.microphoneUIDBeforeFallback = pick
    }
}

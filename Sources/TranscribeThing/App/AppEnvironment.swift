import AppKit
import Observation

/// Composition root, built once by the AppDelegate (or per snapshot via `preview()`).
@MainActor
final class AppEnvironment {
    let paths: AppPaths
    let settings: AppSettings
    let keychain: KeychainStore
    let levelMeter: LevelMeter
    let devices: AudioDeviceCatalog
    let recorder: AudioRecorder
    let openRouterClient: OpenRouterClient
    let account: OpenRouterAccount
    let models: ModelStore
    let transcription: TranscriptionService
    let history: HistoryStore
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
    let windows: WindowCoordinator
    let menuBar: MenuBarController
    /// Preview environments never start services.
    let isPreview: Bool

    private var isStarted = false
    private var maintenanceTask: Task<Void, Never>?
    private var activationObserver: MainNotificationObserver?

    init(paths: AppPaths, settings: AppSettings, keychain: KeychainStore, levelMeter: LevelMeter,
         devices: AudioDeviceCatalog, recorder: AudioRecorder, openRouterClient: OpenRouterClient,
         account: OpenRouterAccount, models: ModelStore, transcription: TranscriptionService,
         history: HistoryStore, permissions: PermissionsCenter, hotkeys: HotkeyMonitor,
         inserter: TextInserter, secureInput: SecureInputMonitor, launchAtLogin: LaunchAtLogin,
         sounds: SoundPlayer, pillModel: PillModel, toasts: ToastCenter, pill: PillController,
         dictation: DictationController, windows: WindowCoordinator, menuBar: MenuBarController,
         isPreview: Bool) {
        self.paths = paths
        self.settings = settings
        self.keychain = keychain
        self.levelMeter = levelMeter
        self.devices = devices
        self.recorder = recorder
        self.openRouterClient = openRouterClient
        self.account = account
        self.models = models
        self.transcription = transcription
        self.history = history
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
        self.windows = windows
        self.menuBar = menuBar
        self.isPreview = isPreview
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
            keychain: KeychainStore(),
            levelMeter: LevelMeter(),
            devices: AudioDeviceCatalog(),
            makeAccount: { keychain, client in OpenRouterAccount(keychain: keychain, client: client) },
            models: ModelStore(paths: paths, settings: settings),
            history: HistoryStore(paths: paths, settings: settings),
            permissions: PermissionsCenter(),
            hotkeys: HotkeyMonitor(settings: settings),
            secureInput: SecureInputMonitor(),
            launchAtLogin: LaunchAtLogin(),
            isPreview: false
        )
    }

    /// In-memory everything with fixture data; nothing is started.
    static func preview() -> AppEnvironment {
        let settings = AppSettings.inMemory()
        settings.onboardingCompleted = true
        return assemble(
            paths: .temporary(),
            settings: settings,
            keychain: .inMemory(),
            levelMeter: .preview(level: 0.55),
            devices: .preview(),
            makeAccount: { _, _ in .preview(status: .valid(PreviewFixtures.keyInfo)) },
            models: .preview(states: [.parakeet: .ready, .whisper: .notInstalled]),
            history: .preview(entries: PreviewFixtures.history()),
            permissions: .preview(mic: .granted, ax: .granted),
            hotkeys: .preview(),
            secureInput: .preview(),
            launchAtLogin: .preview(),
            isPreview: true
        )
    }

    private static func assemble(
        paths: AppPaths, settings: AppSettings, keychain: KeychainStore, levelMeter: LevelMeter,
        devices: AudioDeviceCatalog,
        makeAccount: (KeychainStore, OpenRouterClient) -> OpenRouterAccount,
        models: ModelStore, history: HistoryStore, permissions: PermissionsCenter, hotkeys: HotkeyMonitor,
        secureInput: SecureInputMonitor, launchAtLogin: LaunchAtLogin, isPreview: Bool
    ) -> AppEnvironment {
        let recorder = AudioRecorder(levelMeter: levelMeter, devices: devices, settings: settings)
        let client = OpenRouterClient()
        let account = makeAccount(keychain, client)
        let transcription = TranscriptionService(models: models, account: account, client: client, settings: settings)
        let inserter = TextInserter(settings: settings)
        let sounds = SoundPlayer(settings: settings)
        let pillModel = PillModel(settings: settings, levelMeter: levelMeter)
        let toasts = ToastCenter()
        let pill = PillController(model: pillModel, toasts: toasts, settings: settings)
        let dictation = DictationController(
            settings: settings, recorder: recorder, transcription: transcription, models: models,
            account: account, history: history, inserter: inserter, hotkeys: hotkeys,
            permissions: permissions, sounds: sounds, pillModel: pillModel, toasts: toasts)
        return AppEnvironment(
            paths: paths, settings: settings, keychain: keychain, levelMeter: levelMeter, devices: devices,
            recorder: recorder, openRouterClient: client, account: account, models: models,
            transcription: transcription, history: history, permissions: permissions, hotkeys: hotkeys,
            inserter: inserter, secureInput: secureInput, launchAtLogin: launchAtLogin, sounds: sounds,
            pillModel: pillModel, toasts: toasts, pill: pill, dictation: dictation,
            windows: WindowCoordinator(settings: settings), menuBar: MenuBarController(),
            isPreview: isPreview)
    }

    /// Cross-object references that are safe in previews too (no side effects).
    private func wire() {
        dictation.devices = devices
        dictation.secureInput = secureInput
        dictation.openHub = { [weak self] section in self?.windows.showHub(section) }
        dictation.onActivityChanged = { [weak self] activity in self?.menuBar.show(activity) }
        // Before "Try it", onboarding has no text field: holding fn there is key practice, not dictation.
        // Dictating into another app meanwhile still pastes there.
        dictation.deliversQuietly = { [weak self] in
            guard let self, self.windows.isOnboardingFocused else { return false }
            return self.settings.onboardingStep < OnboardingStep.tryIt.rawValue
        }
        let builder = menuBar.builder
        pillModel.contextMenuProvider = { builder.makeMenu(includeQuit: false) }
        inserter.eventTapActive = { [weak hotkeys] in hotkeys?.isTapActive ?? false }
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
        history.load()
        devices.start()
        permissions.refresh()
        models.start()
        let account = account
        Task { await account.validate() }
        sounds.preload()
        pill.start()
        dictation.start()
        permissions.onAccessibilityGranted = { [weak self] in self?.startHotkeys() }
        hotkeys.onTapAvailabilityChanged = { [weak self] available in
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
        history.pruneOldRecordings()
        scheduleMaintenance()
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
    }

    /// Called at quit: persist what's pending and release the event tap.
    func stop() {
        history.flush()
        hotkeys.stop()
        maintenanceTask?.cancel()
    }

    /// The event tap needs Accessibility; until it's granted, PermissionsCenter polls and calls back here.
    /// A running monitor without a live tap retries right away (its own probe would take up to 3 s).
    private func startHotkeys() {
        guard !hotkeys.isTapActive else { return }
        // At launch no availability callback fires, so the result is passed on here.
        if hotkeys.start() {
            Log.app.info("Hotkeys active")
            dictation.shortcutAvailabilityChanged(true)
        } else {
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

    /// transcribe-thing runs for weeks at a time: prune retained audio a few times a day, not only at launch.
    private func scheduleMaintenance() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600))
                guard !Task.isCancelled else { return }
                self?.history.pruneOldRecordings()
            }
        }
    }
}

import AppKit

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
        let recorder = AudioRecorder(levelMeter: levelMeter, devices: devices)
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

    /// Starts services in the SPEC §4.14 order.
    func start() {
        guard !isPreview else { return }
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
        if !hotkeys.start() {
            permissions.startPolling()
        }
        secureInput.start()
        menuBar.start()
        if !settings.onboardingCompleted {
            windows.showOnboarding()
        }
        history.pruneOldRecordings()
    }
}

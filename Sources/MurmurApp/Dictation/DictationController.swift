import Foundation

// STUB (FOUNDATION): SHELL implements effect execution, the FIFO job queue and notice routing (SPEC §4.12).
@MainActor
final class DictationController {
    private let settings: AppSettings
    private let recorder: AudioRecorder
    private let transcription: TranscriptionService
    private let models: ModelStore
    private let account: OpenRouterAccount
    private let history: HistoryStore
    private let inserter: TextInserter
    private let hotkeys: HotkeyMonitor
    private let permissions: PermissionsCenter
    private let sounds: SoundPlayer
    private let pillModel: PillModel
    private let toasts: ToastCenter

    private(set) var machine = DictationMachine()

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
    }

    /// Wires hotkey, pill and toast callbacks.
    func start() {}

    func handle(_ event: HotkeyEvent) {}

    /// Menu bar "Start Hands-free Dictation".
    func toggleHandsFree() {}

    func pasteLast() {}

    func copyLast() {}

    func perform(_ action: NoticeAction, from notice: Notice) {}

    /// Hub history "Retry" with an engine.
    func retry(_ entry: TranscriptEntry, with engine: EngineID) {}
}

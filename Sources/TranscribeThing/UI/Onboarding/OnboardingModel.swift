import AppKit
import Observation
import SwiftUI

// MARK: - Steps

/// Raw values are what `settings.onboardingStep` stores. `tryIt` teaches the shortcuts and runs the practice chat;
/// they used to be two steps (see `AppSettings.onboardingStep(fromSixStepIndex:)` for saved progress).
enum OnboardingStep: Int, CaseIterable, Comparable, Identifiable, Sendable {
    case welcome, permissions, model, tryIt, done

    var id: Int { rawValue }

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .model: "Model"
        case .tryIt: "Try it"
        case .done: "Done"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    /// `settings.onboardingStep` may hold anything (older builds, hand edits): clamp into range.
    static func resuming(from stored: Int) -> OnboardingStep {
        OnboardingStep(rawValue: min(max(stored, 0), OnboardingStep.allCases.count - 1)) ?? .welcome
    }

    /// The model step gets the full window width; the rest pair copy with a live stage.
    var usesStage: Bool { self != .model }
}

// MARK: - Gating (pure, unit-tested)

enum OnboardingGate {
    struct Inputs: Equatable {
        var microphone: PermissionState
        var accessibility: PermissionState
        var engine: EngineID
        var localState: LocalModelState
        var keyStatus: KeyStatus
        var hasStoredKey: Bool
    }

    static func canContinue(_ step: OnboardingStep, _ inputs: Inputs) -> Bool {
        switch step {
        case .welcome, .tryIt, .done:
            true
        case .permissions:
            inputs.microphone == .granted && inputs.accessibility == .granted
        case .model:
            engineIsUsable(inputs.engine, localState: inputs.localState, keyStatus: inputs.keyStatus,
                           hasStoredKey: inputs.hasStoredKey)
        }
    }

    /// Accessibility can be skipped (with a warning) once the microphone is allowed; the mic is the one hard gate.
    static func canSkipAccessibility(_ inputs: Inputs) -> Bool {
        inputs.microphone == .granted && inputs.accessibility != .granted
    }

    /// Selected engine is ready, on its way (download keeps going, preparing), or has a working key.
    static func engineIsUsable(_ engine: EngineID, localState: LocalModelState, keyStatus: KeyStatus,
                               hasStoredKey: Bool) -> Bool {
        if engine.isLocal {
            switch localState {
            case .ready, .downloading, .preparing, .installed: return true
            case .notInstalled, .failed: return false
            }
        }
        switch keyStatus {
        case .valid:
            return true
        case .offline, .failed:
            // Can't verify right now, but a stored key most likely still works.
            return hasStoredKey
        case .missing, .checking, .invalid, .noCredit:
            return false
        }
    }

    static func primaryTitle(_ step: OnboardingStep, _ inputs: Inputs, practiceStarted: Bool) -> String {
        switch step {
        case .welcome:
            return "Get Started"
        case .tryIt:
            return practiceStarted ? "Continue" : "Skip Practice"
        case .done:
            return "Start Dictating"
        // While a model downloads, the note under the cards says the download keeps going.
        case .permissions, .model:
            return "Continue"
        }
    }

    /// Cheap local check before asking OpenRouter: keys look like `sk-or-v1-<64 hex>`.
    static func keyFormatProblem(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 6 else { return nil }
        if !key.hasPrefix("sk-or-") { return "OpenRouter keys start with sk-or-. Copy it again from openrouter.ai/keys." }
        if key.contains(where: \.isWhitespace) { return "The key has a space in it. Paste it again." }
        return nil
    }

    /// Long enough to be worth a network check; shorter drafts are still being typed.
    static func keyIsCheckable(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 24 && keyFormatProblem(key) == nil
    }

    /// The Switch model lesson is offered once a step can actually answer: Switch model has a model to step to, and
    /// the OpenRouter key works when a step goes through it (`parakeet`: where Parakeet runs).
    static func switchModelUsable(lineup: ModelLineup, parakeet: EngineID, keyStatus: KeyStatus,
                                  hasStoredKey: Bool) -> Bool {
        guard !lineup.steps.isEmpty else { return false }
        guard lineup.steps.contains(where: { $0.needsOpenRouter(parakeet: parakeet) }) else { return true }
        return engineIsUsable(.geminiFlash, localState: .notInstalled, keyStatus: keyStatus, hasStoredKey: hasStoredKey)
    }

    /// The model step's line under the tiles, with the user's own Switch model binding: what the shortcut steps to
    /// from Parakeet, or which main model dictations start on when it isn't Parakeet.
    static func lineupNote(binding: Shortcut?, lineup: ModelLineup, parakeet: EngineID) -> String {
        guard lineup.main == .parakeet else {
            return "Your dictations start on \(lineup.main.title(parakeet: parakeet)), your main model. "
                + "Change it anytime in Models."
        }
        switch SwitchModelLine.status(binding: binding, lineup: lineup) {
        case .ready(let binding):
            // "fn ⇥" stays on one line inside running copy.
            let key = binding.compactDescription.replacingOccurrences(of: " ", with: "\u{00A0}")
            let steps = lineup.steps
            let cleanup = "have the text cleaned up", gemini = "use Gemini for a long talk where every word counts"
            switch (steps.firstIndex(of: .cleanup), steps.firstIndex(of: .gemini)) {
            case let (c?, g?):
                let (first, then) = c < g ? (cleanup, gemini) : (gemini, cleanup)
                return "Press \(key) while dictating to \(first), or again to \(then). It uses the same OpenRouter key."
            case (_?, nil):
                return "Press \(key) while dictating to \(cleanup). It uses the same OpenRouter key."
            case (nil, _):
                return "For a long talk where every word counts, press \(key) while dictating to use Gemini. "
                    + "It uses the same OpenRouter key."
            }
        case .alone, .unbound:
            return "Gemini is there for long talks where every word counts. Set it up later in Settings."
        }
    }

    static func requiredDiskBytes(for engine: EngineID) -> Int64? {
        engine.approxDownloadBytes.map { Int64((Double($0) * 1.25).rounded(.up)) }
    }
}

/// What the practice step can offer right now (pure, unit-tested).
enum PracticeReadiness: Equatable {
    case ready
    /// Local model loading for the first time; recording works, the result just waits.
    case warmingUp(EngineID)
    case needsMicrophone
    case needsAccessibility
    case downloading(EngineID, Double)
    case notDownloaded(EngineID)
    case needsKey(EngineID)

    var allowsPractice: Bool {
        switch self {
        case .ready, .warmingUp: true
        default: false
        }
    }

    static func evaluate(microphone: PermissionState, accessibility: PermissionState, engine: EngineID,
                         localState: LocalModelState, keyStatus: KeyStatus, hasStoredKey: Bool) -> PracticeReadiness {
        if microphone != .granted { return .needsMicrophone }
        if accessibility != .granted { return .needsAccessibility }
        if engine.isLocal {
            switch localState {
            case .ready: return .ready
            case .installed, .preparing: return .warmingUp(engine)
            case .downloading(let p): return .downloading(engine, p.fraction)
            case .notInstalled, .failed: return .notDownloaded(engine)
            }
        }
        return OnboardingGate.engineIsUsable(engine, localState: localState, keyStatus: keyStatus,
                                             hasStoredKey: hasStoredKey) ? .ready : .needsKey(engine)
    }
}

// MARK: - Keyboard illustration keys

/// Keys drawn on the onboarding keyboard. Its own Hashable type: `RawKeyEvent.Key` is only Equatable.
enum IllustratedKey: Hashable, CaseIterable, Sendable {
    case escape, fn, control, option, command, shift, space

    init?(_ key: RawKeyEvent.Key) {
        switch key {
        case .fn: self = .fn
        case .space: self = .space
        case .escape: self = .escape
        case .command: self = .command
        case .option: self = .option
        case .control: self = .control
        case .shift: self = .shift
        case .other: return nil
        }
    }

    /// Keys a shortcut needs held down, when all of them are on the illustration.
    static func keys(for shortcut: Shortcut?) -> Set<IllustratedKey> {
        guard let shortcut, !shortcut.isEmpty else { return [] }
        var keys = Set<IllustratedKey>()
        for mk in shortcut.modifiers {
            switch mk.modifier {
            case .function: keys.insert(.fn)
            case .control: keys.insert(.control)
            case .option: keys.insert(.option)
            case .shift: keys.insert(.shift)
            case .command: keys.insert(.command)
            }
        }
        if let code = shortcut.keyCode {
            switch code {
            case KeyCode.space: keys.insert(.space)
            case KeyCode.escape: keys.insert(.escape)
            default: return []
            }
        }
        return keys
    }
}

// MARK: - Practice chat

struct ChatMessage: Identifiable, Equatable {
    enum Sender: Equatable { case alex, me, note }

    let id: UUID
    var sender: Sender
    var text: String

    init(id: UUID = UUID(), sender: Sender, text: String) {
        self.id = id
        self.sender = sender
        self.text = text
    }
}

enum PracticeLesson: Int, CaseIterable, Identifiable, Comparable {
    case pushToTalk, handsFree, cancel

    var id: Int { rawValue }

    static func < (lhs: PracticeLesson, rhs: PracticeLesson) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PracticeStat: Equatable {
    var words: Int
    var seconds: Double

    var wordsPerMinute: Int { seconds > 0 ? Int((Double(words) / seconds * 60).rounded()) : 0 }

    /// Only worth bragging about with a real sentence and a measurable duration.
    var isMeaningful: Bool { words >= 3 && seconds >= 1 }
}

enum PracticeHint: Equatable {
    case noSpeech
    case typedInstead
    /// Another push-to-talk message while the hands-free lesson is still open.
    case tryHandsFree
}

// MARK: - Dependencies

/// Everything onboarding touches, pulled out of the environment so snapshots and tests can swap single pieces.
@MainActor
struct OnboardingContext {
    var settings: AppSettings
    var permissions: PermissionsCenter
    var models: ModelStore
    var account: OpenRouterAccount
    var hotkeys: HotkeyMonitor
    var launchAtLogin: LaunchAtLogin
    var history: HistoryStore
    var pillModel: PillModel
    /// The real pill's phase as recordings count it (`DictationController.committedPillPhase`): the pill comes up
    /// at key-down, but a quick tap or an fn combo never commits to recording.
    var dictationPhase: () -> PillPhase
    var levelMeter: LevelMeter
    var devices: AudioDeviceCatalog
    var freeDiskBytes: () -> Int64
    var closeWindow: () -> Void
    var showHello: () -> Void
    /// Snapshots and tests: no polling, monitors, timers or system calls.
    var isPreview: Bool

    init(env: AppEnvironment) {
        settings = env.settings
        permissions = env.permissions
        models = env.models
        account = env.account
        hotkeys = env.hotkeys
        launchAtLogin = env.launchAtLogin
        history = env.history
        pillModel = env.pillModel
        let dictation = env.dictation
        dictationPhase = { [weak dictation] in dictation?.committedPillPhase ?? .rest }
        levelMeter = env.levelMeter
        devices = env.devices
        let paths = env.paths
        freeDiskBytes = { paths.freeDiskBytes() }
        let windows = env.windows
        closeWindow = { [weak windows] in windows?.closeOnboarding() }
        let pill = env.pill
        showHello = { [weak pill] in pill?.showHello() }
        isPreview = env.isPreview
    }
}

// MARK: - Model

/// Lets a `@Sendable` key callback reach the model without capturing `self` mutably.
private struct WeakModelRef: @unchecked Sendable {
    weak var model: OnboardingModel?
}

@MainActor @Observable
final class OnboardingModel {
    @ObservationIgnored let ctx: OnboardingContext

    private(set) var step: OnboardingStep
    private(set) var movingForward = true
    var isPointerInside = false
    /// Increments when the primary button should pulse (all permissions just turned green).
    private(set) var continuePulse = 0

    // Permissions
    private(set) var isRequestingMicrophone = false
    private(set) var showAccessibilityHelp = false
    private(set) var skipAccessibilityArmed = false
    /// Snapshot overrides for read-only PermissionsCenter state.
    var fnKeyUsageOverride: FnKeyUsage?
    var accessibilityStaleOverride: Bool?

    // Model
    private(set) var keyDraft = ""
    private(set) var keyFormatError: String?
    private(set) var isReplacingKey = false
    private(set) var freeDiskBytes: Int64 = .max
    /// Engines whose download started while this window was open: their Ready check draws on.
    private(set) var celebrateReady: Set<EngineID> = []

    // Try it: the keys
    private(set) var pressedKeys: Set<IllustratedKey> = []
    private(set) var heldPushToTalk = false
    private(set) var triedHandsFree = false
    private(set) var handsFreeLatched = false
    private(set) var sawPushToTalkKey = false
    private(set) var showKeyboardHint = false

    // Try it: the practice chat
    private(set) var messages: [ChatMessage] = [ChatMessage(sender: .alex, text: OnboardingModel.alexOpening)]
    private(set) var completedLessons: Set<PracticeLesson> = []
    private(set) var alexIsTyping = false
    private(set) var draft = ""
    private(set) var practiceStat: PracticeStat?
    private(set) var practiceHint: PracticeHint?
    private(set) var isSendingDictation = false
    private(set) var recordingInProgress = false

    // Done
    private(set) var openAtLogin: Bool
    private(set) var openAtLoginError: String?
    private(set) var confettiBurst = 0

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var isAttached = false
    @ObservationIgnored private var pttDownAt: Date?
    @ObservationIgnored private var lastPTTTapAt: Date?
    @ObservationIgnored private var stopArmed = false
    @ObservationIgnored private var recordingStartedAt: Date?
    @ObservationIgnored private var lastRecordingSpan: (start: Date, end: Date)?
    /// The recording under way went hands-free at some point (fn + space, a double press, or Undo resuming it).
    @ObservationIgnored private var recordingWentHandsFree = false
    @ObservationIgnored private var lastRecordingWasHandsFree = false
    @ObservationIgnored private var dictatedMessages = 0
    @ObservationIgnored private var historyBaseline: Set<UUID> = []
    @ObservationIgnored private var permissionsWereComplete = false

    static let alexOpening = "hey! quick one: what are you up to this afternoon?"
    static let alexAfterFirst = "sounds good. and what’s the plan for tomorrow?"
    static let alexAfterSecond = "perfect, thanks!"
    static let alexAfterThird = "ha, love it. talk soon!"
    /// True whatever Undo does next: at this point nothing has been typed.
    static let cancelNote = "Canceled. Nothing was typed."

    init(context: OnboardingContext) {
        ctx = context
        step = OnboardingStep.resuming(from: context.settings.onboardingStep)
        // First run defaults to opening at login (the recommended setup); a replay reflects the current state.
        openAtLogin = context.settings.onboardingCompleted ? context.launchAtLogin.isEnabled : true
        permissionsWereComplete = context.permissions.allRequiredGranted
        freeDiskBytes = context.freeDiskBytes()
        historyBaseline = Set(context.history.entries.prefix(50).map(\.id))
    }

    // MARK: Derived state

    var gateInputs: OnboardingGate.Inputs {
        let engine = ctx.settings.mainEngine
        return OnboardingGate.Inputs(
            microphone: ctx.permissions.microphone,
            accessibility: ctx.permissions.accessibility,
            engine: engine,
            localState: ctx.models.state(of: engine),
            keyStatus: ctx.account.status,
            hasStoredKey: ctx.account.maskedKey != nil)
    }

    var canContinue: Bool { OnboardingGate.canContinue(step, gateInputs) }
    var canSkipAccessibility: Bool { step == .permissions && OnboardingGate.canSkipAccessibility(gateInputs) }
    var practiceStarted: Bool { !completedLessons.isEmpty }
    var primaryTitle: String { OnboardingGate.primaryTitle(step, gateInputs, practiceStarted: practiceStarted) }
    /// Where Parakeet runs: the model step's selected tile.
    var selectedEngine: EngineID { ctx.settings.parakeetEngine }

    var fnKeyUsage: FnKeyUsage { fnKeyUsageOverride ?? ctx.permissions.fnKeyUsage }
    var accessibilityLooksStale: Bool { accessibilityStaleOverride ?? ctx.permissions.accessibilityLikelyStale }

    /// The fn card matters only when a binding actually uses fn.
    var showsFnKeyCard: Bool {
        guard fnKeyUsage != .doNothing else { return false }
        return [ShortcutAction.pushToTalk, .handsFree].contains { ctx.settings.shortcuts[$0]?.usesFunctionKey == true }
    }

    var pushToTalkKeys: Set<IllustratedKey> { IllustratedKey.keys(for: ctx.settings.shortcuts[.pushToTalk]) }
    var handsFreeKeys: Set<IllustratedKey> { IllustratedKey.keys(for: ctx.settings.shortcuts[.handsFree]) }
    var isHoldingPushToTalk: Bool { !pushToTalkKeys.isEmpty && pushToTalkKeys.isSubset(of: pressedKeys) }
    /// Keys the lessons use, tinted on the keyboard strip.
    var practiceKeys: Set<IllustratedKey> {
        pushToTalkKeys.union(handsFreeKeys).union(IllustratedKey.keys(for: .escape))
    }

    /// The model step's line about the other models: a key press away while dictating.
    var lineupNote: String {
        OnboardingGate.lineupNote(binding: ctx.settings.shortcuts[.switchModel], lineup: ctx.settings.lineup,
                                  parakeet: ctx.settings.parakeetEngine)
    }

    /// The optional "Switch model" row on the practice step: only when a model it steps to would answer.
    var showsSwitchModelLesson: Bool {
        let inputs = gateInputs
        return OnboardingGate.switchModelUsable(lineup: ctx.settings.lineup, parakeet: ctx.settings.parakeetEngine,
                                                keyStatus: inputs.keyStatus, hasStoredKey: inputs.hasStoredKey)
    }

    var pushToTalkLabel: String { ctx.settings.shortcuts[.pushToTalk]?.compactDescription ?? "fn" }

    /// The real pill's phase, counting only committed recordings: what the lessons and the stage follow.
    var dictationPhase: PillPhase { ctx.dictationPhase() }

    /// The practice stage mirrors the real pill while a dictation runs, else follows the keys.
    var livePhase: PillPhase {
        let real = dictationPhase
        if real.isActive { return real }
        if handsFreeLatched { return .locked }
        if isHoldingPushToTalk { return .listening }
        return .rest
    }

    var practiceReadiness: PracticeReadiness {
        let inputs = gateInputs
        return PracticeReadiness.evaluate(microphone: inputs.microphone, accessibility: inputs.accessibility,
                                          engine: inputs.engine, localState: inputs.localState,
                                          keyStatus: inputs.keyStatus, hasStoredKey: inputs.hasStoredKey)
    }

    /// First lesson not yet done, in order; nil once practice is complete.
    var currentLesson: PracticeLesson? {
        PracticeLesson.allCases.first { !completedLessons.contains($0) }
    }

    /// Return sends the chat message on the practice step instead of leaving it.
    var primaryUsesReturn: Bool { step != .tryIt || currentLesson == nil }

    /// Lessons tick from real dictations. While there's no dictating yet (the model still downloading, no key,
    /// a missing permission), the keys alone tick the first two, so the step still teaches something.
    var lessonsFollowKeys: Bool { !practiceReadiness.allowsPractice }

    // MARK: Lifecycle

    func attach() {
        guard !isAttached else { return }
        isAttached = true
        guard !ctx.isPreview else { return }
        ctx.permissions.refresh()
        installKeyHandlers()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        stepDidAppear()
    }

    func detach() {
        guard isAttached else { return }
        isAttached = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        guard !ctx.isPreview else { return }
        ctx.hotkeys.onRawKey = nil
        ctx.permissions.stopPolling()
    }

    private func appBecameActive() {
        ctx.permissions.refresh()
        if step == .model { freeDiskBytes = ctx.freeDiskBytes() }
    }

    // MARK: Navigation

    func goNext() {
        guard let next = step.next else { return }
        go(to: next)
    }

    func goBack() {
        guard let previous = step.previous else { return }
        go(to: previous)
    }

    func go(to target: OnboardingStep) {
        guard target != step else { return }
        stepWillDisappear()
        movingForward = target > step
        step = target
        ctx.settings.onboardingStep = target.rawValue
        stepDidAppear()
    }

    func primaryAction() {
        switch step {
        case .done:
            finish()
        case .tryIt:
            goNext()
        default:
            guard canContinue else { return }
            goNext()
        }
    }

    func skipAccessibility() {
        guard canSkipAccessibility else { return }
        if skipAccessibilityArmed {
            skipAccessibilityArmed = false
            goNext()
        } else {
            skipAccessibilityArmed = true
        }
    }

    func finish() {
        if openAtLogin != ctx.launchAtLogin.isEnabled { applyOpenAtLogin(openAtLogin) }
        ctx.settings.onboardingCompleted = true
        ctx.settings.onboardingStep = 0
        detach()
        guard !ctx.isPreview else { return }
        ctx.closeWindow()
        ctx.showHello()
    }

    private func stepDidAppear() {
        guard isAttached, !ctx.isPreview else { return }
        switch step {
        case .permissions:
            permissionsWereComplete = ctx.permissions.allRequiredGranted
            ctx.permissions.refresh()
            ctx.permissions.startPolling(interval: 0.5)
            if ctx.permissions.accessibility != .granted { scheduleAccessibilityHelp(after: 20) }
        case .model:
            freeDiskBytes = ctx.freeDiskBytes()
        case .tryIt:
            historyBaseline = Set(ctx.history.entries.prefix(50).map(\.id))
            schedule("keyboardHint", after: 25) { model in
                if !model.sawPushToTalkKey { model.showKeyboardHint = true }
            }
        case .done:
            confettiBurst += 1
        case .welcome:
            break
        }
    }

    private func stepWillDisappear() {
        tasks["autoAdvance"]?.cancel()
        skipAccessibilityArmed = false
        // Fast permission polling is for the permissions step only (background polling carries on).
        if step == .permissions, !ctx.isPreview { ctx.permissions.stopPolling() }
    }

    /// Another surface (the Hub's "Practice in onboarding") moved the resume point while this window is open.
    func externalStepChanged(_ stored: Int) {
        let target = OnboardingStep.resuming(from: stored)
        if target != step { go(to: target) }
    }

    // MARK: Permissions

    func requestMicrophone() {
        guard !isRequestingMicrophone else { return }
        if ctx.permissions.microphone == .denied {
            ctx.permissions.open(.microphone)
            return
        }
        isRequestingMicrophone = true
        let permissions = ctx.permissions
        Task { [weak self] in
            _ = await permissions.requestMicrophone()
            permissions.refresh()
            self?.isRequestingMicrophone = false
        }
    }

    func requestAccessibility() {
        ctx.permissions.requestAccessibility()
        ctx.permissions.startPolling(interval: 0.5)
        scheduleAccessibilityHelp(after: 20)
    }

    func openKeyboardSettings() {
        ctx.permissions.open(.keyboard)
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func scheduleAccessibilityHelp(after seconds: Double) {
        schedule("axHelp", after: seconds) { model in
            if model.ctx.permissions.accessibility != .granted { model.showAccessibilityHelp = true }
        }
    }

    /// Called by the view whenever the permission picture changes.
    func permissionsChanged() {
        let complete = ctx.permissions.allRequiredGranted
        defer { permissionsWereComplete = complete }
        if ctx.permissions.accessibility == .granted { showAccessibilityHelp = false }
        guard step == .permissions, complete, !permissionsWereComplete else { return }
        continuePulse += 1
        schedule("autoAdvance", after: 0.7) { model in
            guard model.step == .permissions, !model.isPointerInside, model.canContinue else { return }
            model.goNext()
        }
    }

    // MARK: Models

    /// Where Parakeet runs. Gemini isn't a place Parakeet runs: it's one of the models in Settings → Models.
    func select(_ engine: EngineID) {
        guard engine.isParakeet else { return }
        ctx.models.select(engine)
        // Preview stores keep their own settings; keep the shared selection authoritative either way.
        if ctx.settings.parakeetEngine != engine { ctx.settings.parakeetEngine = engine }
        if engine.isCloud, ctx.account.maskedKey == nil { isReplacingKey = true }
    }

    func requiredDiskBytes(for engine: EngineID) -> Int64? { OnboardingGate.requiredDiskBytes(for: engine) }

    func hasEnoughDisk(for engine: EngineID) -> Bool {
        guard let needed = requiredDiskBytes(for: engine) else { return true }
        return freeDiskBytes >= needed
    }

    func download(_ engine: EngineID) {
        select(engine)
        if !ctx.isPreview { freeDiskBytes = ctx.freeDiskBytes() }
        guard hasEnoughDisk(for: engine) else { return }
        celebrateReady.insert(engine)
        ctx.models.download(engine)
    }

    /// Replaces a model that downloaded but won't load: deletes its files and downloads it again.
    func reinstall(_ engine: EngineID) {
        select(engine)
        celebrateReady.insert(engine)
        let models = ctx.models
        Task { await models.reinstall(engine) }
    }

    func cancelDownload(_ engine: EngineID) {
        celebrateReady.remove(engine)
        ctx.models.cancelDownload(engine)
    }

    func openStorageSettings() {
        ctx.permissions.open(.storage)
    }

    func updateKeyDraft(_ text: String) {
        keyDraft = text
        keyFormatError = nil
        tasks["key"]?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = OnboardingGate.keyFormatProblem(trimmed) {
            schedule("key", after: 0.5) { model in model.keyFormatError = problem }
            return
        }
        guard OnboardingGate.keyIsCheckable(trimmed) else { return }
        schedule("key", after: 0.5) { model in await model.submitKey(trimmed) }
    }

    func submitKeyDraft() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tasks["key"]?.cancel()
        if let problem = OnboardingGate.keyFormatProblem(trimmed) {
            keyFormatError = problem
            return
        }
        schedule("key", after: 0) { model in await model.submitKey(trimmed) }
    }

    func pasteKey() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        keyDraft = text
        submitKeyDraft()
    }

    func replaceKey() {
        keyDraft = ""
        keyFormatError = nil
        isReplacingKey = true
    }

    func removeKey() {
        ctx.account.removeKey()
        keyDraft = ""
        isReplacingKey = true
    }

    private func submitKey(_ key: String) async {
        // The account finishes its check even when the next keystroke cancels this task; the field then
        // holds the newer draft, so leave it alone.
        await ctx.account.setKey(key)
        guard !Task.isCancelled else { return }
        if case .valid = ctx.account.status {
            keyDraft = ""
            isReplacingKey = false
        }
    }

    /// Shows the key field (instead of the stored masked key).
    var showsKeyField: Bool { isReplacingKey || ctx.account.maskedKey == nil }

    // MARK: Keys

    private func installKeyHandlers() {
        let ref = WeakModelRef(model: self)
        let handler: @Sendable (RawKeyEvent) -> Void = { event in
            OnboardingModel.onMain { ref.model?.handleRawKey(event) }
        }
        ctx.hotkeys.onRawKey = handler
        // Our own window sees fn even when the event tap isn't running yet (Accessibility skipped).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            if let raw = OnboardingModel.rawKeyEvent(from: event) {
                MainActor.assumeIsolated { self?.handleRawKey(raw) }
            }
            return event
        }
    }

    nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    nonisolated static func rawKeyEvent(from event: NSEvent) -> RawKeyEvent? {
        let key = RawKeyEvent.Key(keyCode: event.keyCode)
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags
            switch key {
            case .fn: return RawKeyEvent(key: key, isDown: flags.contains(.function))
            case .command: return RawKeyEvent(key: key, isDown: flags.contains(.command))
            case .option: return RawKeyEvent(key: key, isDown: flags.contains(.option))
            case .control: return RawKeyEvent(key: key, isDown: flags.contains(.control))
            case .shift: return RawKeyEvent(key: key, isDown: flags.contains(.shift))
            default: return nil
            }
        case .keyDown:
            guard !event.isARepeat, key == .space || key == .escape else { return nil }
            return RawKeyEvent(key: key, isDown: true)
        case .keyUp:
            guard key == .space || key == .escape else { return nil }
            return RawKeyEvent(key: key, isDown: false)
        default:
            return nil
        }
    }

    func handleRawKey(_ event: RawKeyEvent, now: Date = Date()) {
        guard let key = IllustratedKey(event.key) else { return }
        let wasHoldingPTT = isHoldingPushToTalk
        let wasHoldingHandsFree = !handsFreeKeys.isEmpty && handsFreeKeys.isSubset(of: pressedKeys)
        if event.isDown {
            guard !pressedKeys.contains(key) else { return }
            pressedKeys.insert(key)
        } else {
            guard pressedKeys.contains(key) else { return }
            pressedKeys.remove(key)
        }
        guard step == .tryIt else { return }
        let holdingPTT = isHoldingPushToTalk
        let holdingHandsFree = !handsFreeKeys.isEmpty && handsFreeKeys.isSubset(of: pressedKeys)

        if key == .escape, event.isDown,
           recordingInProgress || dictationPhase.isRecording || holdingPTT || handsFreeLatched {
            completeCancelLesson()
        }

        if holdingHandsFree && !wasHoldingHandsFree {
            // Only starts hands-free: pressed again it does nothing, and the push-to-talk key held for it (fn of
            // fn+Space) doesn't finish on release.
            handsFreeLatched = true
            markTriedHandsFree()
            stopArmed = false
            return
        }
        if holdingPTT && !wasHoldingPTT {
            sawPushToTalkKey = true
            showKeyboardHint = false
            pttDownAt = now
            if handsFreeLatched {
                stopArmed = true
            } else if ctx.settings.doublePressForHandsFree, let tap = lastPTTTapAt, now.timeIntervalSince(tap) <= 0.5 {
                handsFreeLatched = true
                markTriedHandsFree()
                lastPTTTapAt = nil
            } else {
                schedule("hold", after: 0.45) { model in
                    if model.isHoldingPushToTalk { model.markHeldPushToTalk() }
                }
            }
        } else if !holdingPTT && wasHoldingPTT {
            tasks["hold"]?.cancel()
            let held = pttDownAt.map { now.timeIntervalSince($0) } ?? 0
            if held >= 0.45 { markHeldPushToTalk() }
            if handsFreeLatched && stopArmed {
                handsFreeLatched = false
                stopArmed = false
            } else if held < 0.3 && !handsFreeLatched {
                lastPTTTapAt = now
            }
            pttDownAt = nil
        }
    }

    private func markHeldPushToTalk() {
        heldPushToTalk = true
        if lessonsFollowKeys { completedLessons.insert(.pushToTalk) }
    }

    private func markTriedHandsFree() {
        triedHandsFree = true
        if recordingInProgress { recordingWentHandsFree = true }
        if lessonsFollowKeys { completedLessons.insert(.handsFree) }
    }

    /// Called by the view when the real pill changes phase (`dictationPhase`: taps and fn combos don't count).
    func pillPhaseChanged(from old: PillPhase, to new: PillPhase, now: Date = Date()) {
        if new.isRecording && !old.isRecording {
            recordingInProgress = true
            recordingStartedAt = now
            recordingWentHandsFree = handsFreeLatched
        }
        if new == .locked, step == .tryIt {
            handsFreeLatched = true
            recordingWentHandsFree = true
            markTriedHandsFree()
        }
        if old.isRecording && !new.isRecording {
            recordingInProgress = false
            if let start = recordingStartedAt { lastRecordingSpan = (start, now) }
            recordingStartedAt = nil
            lastRecordingWasHandsFree = recordingWentHandsFree || old == .locked
            recordingWentHandsFree = false
            if old == .locked {
                handsFreeLatched = false
                stopArmed = false
                lastPTTTapAt = nil
            }
        }
        guard step == .tryIt else { return }
        if new == .listening {
            sawPushToTalkKey = true
            showKeyboardHint = false
            if !isHoldingPushToTalk {
                // Keys that only reach the event tap (another app in front): count the real pill as a hold.
                schedule("hold", after: 0.45) { model in
                    if model.dictationPhase == .listening { model.markHeldPushToTalk() }
                }
            }
        }
        if new == .error { practiceHint = .noSpeech }
        if new.isRecording, practiceHint != .tryHandsFree { practiceHint = nil }
    }

    // MARK: Practice

    func updateDraft(_ text: String, now: Date = Date()) {
        let old = draft
        draft = text
        let inserted = text.count - old.count
        guard step == .tryIt else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tasks["send"]?.cancel()
            isSendingDictation = false
            return
        }
        // A multi-character jump right after a recording is transcribe-thing's paste, not typing.
        if inserted >= 2 && hasRecentRecording(now: now) {
            isSendingDictation = true
            if ctx.isPreview {
                sendDraft(dictated: true, now: now)
            } else {
                schedule("send", after: 0.9) { model in model.sendDraft(dictated: true) }
            }
        }
    }

    private func hasRecentRecording(now: Date) -> Bool {
        if recordingInProgress || dictationPhase.isActive { return true }
        if let span = lastRecordingSpan, now.timeIntervalSince(span.end) < 120 { return true }
        return newSuccessEntry(within: 120, now: now) != nil
    }

    private func newSuccessEntry(within seconds: TimeInterval, now: Date) -> TranscriptEntry? {
        ctx.history.entries.prefix(5).first { entry in
            entry.status == .success && !historyBaseline.contains(entry.id)
                && now.timeIntervalSince(entry.createdAt) < seconds
        }
    }

    func submitDraft() {
        sendDraft(dictated: isSendingDictation)
    }

    func sendDraft(dictated: Bool, now: Date = Date()) {
        tasks["send"]?.cancel()
        isSendingDictation = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        messages.append(ChatMessage(sender: .me, text: text))
        guard dictated else {
            practiceHint = .typedInstead
            return
        }
        practiceHint = nil
        recordStat(for: text, now: now)
        if let entry = newSuccessEntry(within: 300, now: now) { historyBaseline.insert(entry.id) }
        // The lesson this dictation actually practiced, so "Go hands-free" never ticks for a held key.
        let lesson: PracticeLesson = lastRecordingWasHandsFree ? .handsFree : .pushToTalk
        let repeated = completedLessons.contains(lesson)
        completedLessons.insert(lesson)
        if repeated, lesson == .pushToTalk, !completedLessons.contains(.handsFree) { practiceHint = .tryHandsFree }
        dictatedMessages += 1
        let script = [Self.alexAfterFirst, Self.alexAfterSecond, Self.alexAfterThird]
        if dictatedMessages <= script.count { alexReplies(script[dictatedMessages - 1]) }
    }

    private func recordStat(for text: String, now: Date) {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        var seconds: Double?
        if let entry = newSuccessEntry(within: 300, now: now), entry.audioDuration > 0 {
            seconds = entry.audioDuration
        } else if let span = lastRecordingSpan {
            seconds = span.end.timeIntervalSince(span.start)
        }
        guard let seconds else { return }
        let stat = PracticeStat(words: words, seconds: seconds)
        if stat.isMeaningful { practiceStat = stat }
    }

    private func completeCancelLesson() {
        guard !completedLessons.contains(.cancel) else { return }
        completedLessons.insert(.cancel)
        if messages.last?.sender != .note {
            messages.append(ChatMessage(sender: .note, text: Self.cancelNote))
        }
    }

    /// History is the fallback signal for a cancel (the event tap may swallow Esc before we see it).
    func historyChanged(now: Date = Date()) {
        guard step == .tryIt else { return }
        let cancelled = ctx.history.entries.prefix(5).contains { entry in
            entry.status == .cancelled && !historyBaseline.contains(entry.id)
                && now.timeIntervalSince(entry.createdAt) < 30
        }
        if cancelled {
            historyBaseline.formUnion(ctx.history.entries.prefix(5).map(\.id))
            completeCancelLesson()
        }
    }

    private func alexReplies(_ text: String) {
        if ctx.isPreview {
            messages.append(ChatMessage(sender: .alex, text: text))
            return
        }
        schedule("alex", after: 0.6) { model in
            model.alexIsTyping = true
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            model.alexIsTyping = false
            model.messages.append(ChatMessage(sender: .alex, text: text))
        }
    }

    func setMicrophone(_ uid: String?) {
        ctx.settings.microphoneUID = uid
    }

    // MARK: Done

    func setOpenAtLogin(_ on: Bool) {
        openAtLogin = on
        applyOpenAtLogin(on)
    }

    private func applyOpenAtLogin(_ on: Bool) {
        do {
            try ctx.launchAtLogin.set(on)
            openAtLoginError = nil
        } catch {
            openAtLoginError = error.localizedDescription
            openAtLogin = ctx.launchAtLogin.isEnabled
        }
    }

    // MARK: Snapshot and test hooks

    /// Puts the model into a given sub-state without timers (snapshots only).
    func stage(step: OnboardingStep) {
        self.step = step
    }

    func stagePressed(_ keys: Set<IllustratedKey>, heldPTT: Bool = false, triedHandsFree: Bool = false,
                      latched: Bool = false) {
        pressedKeys = keys
        heldPushToTalk = heldPTT
        self.triedHandsFree = triedHandsFree
        handsFreeLatched = latched
        sawPushToTalkKey = heldPTT
    }

    func stagePractice(messages: [ChatMessage], completed: Set<PracticeLesson>, stat: PracticeStat?,
                       hint: PracticeHint? = nil, alexTyping: Bool = false, draft: String = "") {
        self.messages = messages
        completedLessons = completed
        practiceStat = stat
        practiceHint = hint
        alexIsTyping = alexTyping
        self.draft = draft
    }

    func stageKeyboardHint(_ visible: Bool) {
        showKeyboardHint = visible
    }

    func stageKey(draft: String, formatError: String? = nil, replacing: Bool) {
        keyDraft = draft
        keyFormatError = formatError
        isReplacingKey = replacing
    }

    func stageDisk(free: Int64) {
        freeDiskBytes = free
    }

    func stageAccessibilityHelp(_ visible: Bool) {
        showAccessibilityHelp = visible
    }

    func stageCelebrate(_ engine: EngineID) {
        celebrateReady.insert(engine)
    }

    // MARK: Timers

    /// Timers never run in preview contexts: snapshots and tests drive state explicitly.
    private func schedule(_ name: String, after seconds: Double, _ work: @escaping @MainActor (OnboardingModel) async -> Void) {
        tasks[name]?.cancel()
        guard !ctx.isPreview else { return }
        tasks[name] = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled, let self else { return }
            await work(self)
        }
    }
}

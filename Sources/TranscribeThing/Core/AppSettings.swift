import Foundation
import Observation

enum PillMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case always, whileDictating, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .whileDictating: "While dictating"
        case .never: "Never"
        }
    }

    var subtitle: String {
        switch self {
        case .always: "A slim bar waits at the bottom of the screen."
        case .whileDictating: "Appears when you start talking."
        case .never: "Only notices appear."
        }
    }
}

/// User preferences. Every property writes through to its store the moment it is set.
@MainActor @Observable
final class AppSettings {
    static let switchHintLimit = 3

    var onboardingCompleted: Bool = false { didSet { store.set(onboardingCompleted, .onboardingCompleted) } }
    /// Resume point for onboarding: an `OnboardingStep` raw value (five steps).
    var onboardingStep: Int = 0 { didSet { store.set(onboardingStep, .onboardingResumeStep) } }
    /// Where Parakeet v3 runs, on this Mac or through OpenRouter: for Parakeet alone and for clean-up
    /// (`ModelChoice`). Anything but Parakeet leaves the default. Stored under `SettingsKey.selectedEngine`.
    var parakeetEngine: EngineID = .default {
        didSet {
            if !parakeetEngine.isParakeet { parakeetEngine = .default }
            store.set(parakeetEngine.rawValue, .selectedEngine)
        }
    }
    /// The three models as Models lists them: their order, the main model every dictation starts on, and which
    /// others the Switch model shortcut steps to.
    var lineup: ModelLineup = .default {
        didSet {
            store.setJSON(lineup, .lineup)
            // A hands-free model that is now the main one, or that Switch model no longer reaches, is gone: turned
            // back on later, it stays off for hands-free until picked again.
            if let choice = handsFreeModel, !lineup.steps.contains(choice) { handsFreeModel = nil }
        }
    }
    /// Each model's color (Models): the pill wears the dictation's model's, and its tile, the sidebar chip and
    /// History's marks show it.
    var modelColors: ModelColors = .default { didSet { store.setJSON(modelColors, .modelColors) } }
    /// How many times the pill has shown the Switch model hint (it shows at most `switchHintLimit` times).
    var switchHintShownCount: Int = 0 { didSet { store.set(switchHintShownCount, .switchHintShownCount) } }
    var pillMode: PillMode = .whileDictating { didSet { store.set(pillMode.rawValue, .pillMode) } }
    var soundsEnabled: Bool = true { didSet { store.set(soundsEnabled, .soundsEnabled) } }
    /// The only mic dictation opens while it is connected. nil = Automatic: the system default input (Bluetooth
    /// included) at the moment a dictation starts. A picked mic that goes away falls back to Automatic
    /// (`InputDevicePolicy.keepsPick`), and is picked again when it's back (`microphoneUIDBeforeFallback`).
    var microphoneUID: String? = nil {
        didSet {
            store.set(microphoneUID, .microphoneUID)
            microphoneUIDBeforeFallback = nil
        }
    }
    /// The mic that was picked when it went away and Automatic took over (`AppEnvironment`): picked again once it can
    /// record, unless the user has picked a mic (Automatic included) since, which forgets it. Not stored: a relaunch
    /// keeps Automatic.
    @ObservationIgnored var microphoneUIDBeforeFallback: String?
    var showDockIcon: Bool = false { didSet { store.set(showDockIcon, .showDockIcon) } }
    /// Off by default. Stored only once the user flips it (Shortcuts), so an install that never did gets the
    /// default of the build it runs.
    var doublePressForHandsFree: Bool = false { didSet { store.set(doublePressForHandsFree, .doublePressForHandsFree) } }
    /// The model a hands-free dictation switches to as it starts (Models), as if Switch model had stepped to it: a long
    /// dictation is usually one for Gemini. nil: the main model, as when holding the key.
    var handsFreeModel: ModelChoice? = nil { didSet { store.set(handsFreeModel?.rawValue, .handsFreeModel) } }
    /// `handsFreeModel` while Switch model reaches it and it isn't the main model; nil otherwise. A hands-free
    /// dictation is on a model of the cycle, like any other: fn ⇥ steps on from it, the pill's menu checks it, and a
    /// local Parakeet in the cycle is loaded at launch.
    var handsFreeChoice: ModelChoice? {
        handsFreeModel.flatMap { lineup.steps.contains($0) ? $0 : nil }
    }
    /// What the app pastes ends in one space, so the next dictation doesn't run into it. History and Copy keep the
    /// text as it was.
    var addsSpaceAfterText: Bool = false { didSet { store.set(addsSpaceAfterText, .addSpaceAfterText) } }
    /// What the app pastes loses a single final period (`PastedText`). History and Copy keep the text as it was.
    var removesFinalPeriod: Bool = false { didSet { store.set(removesFinalPeriod, .removeFinalPeriod) } }
    /// Days a transcript and its recording stay in History; 0 = Never deleted (`HistoryStore.deleteExpired`).
    var autoDeleteHistoryDays: Int = 0 { didSet { store.set(autoDeleteHistoryDays, .autoDeleteHistoryDays) } }
    var shortcuts: ShortcutBindings = .defaults { didSet { store.setJSON(shortcuts, .shortcuts) } }
    var hasShownWelcomeHello: Bool = false { didSet { store.set(hasShownWelcomeHello, .hasShownWelcomeHello) } }
    /// Checks GitHub in the background and announces new versions. Off: no reminders and no badges, though the
    /// Software Update page still checks when opened.
    var checkForUpdatesAutomatically: Bool = true {
        didSet { store.set(checkForUpdatesAutomatically, .checkForUpdatesAutomatically) }
    }
    /// The newest version the pill has announced ("x.y.z"): each version is announced once, whatever the answer.
    var announcedUpdateVersion: String? = nil { didSet { store.set(announcedUpdateVersion, .announcedUpdateVersion) } }
    /// The version that ran last time, so the first launch after an update can say so. nil on a fresh install.
    var lastLaunchedVersion: String? = nil { didSet { store.set(lastLaunchedVersion, .lastLaunchedVersion) } }
    /// The OpenRouter key older builds kept in the login keychain is settled: moved to its key file, never there, or
    /// a key was saved or removed since (`KeychainMigration`). From then on the Keychain is never asked again.
    var keychainKeyMigrated: Bool = false { didSet { store.set(keychainKeyMigrated, .keychainKeyMigrated) } }

    @ObservationIgnored private let store: SettingsStore
    /// Read once at most, by the migration of the removed built-in-over-Bluetooth switch.
    @ObservationIgnored private let microphoneProbe: () -> MicrophoneMigrationProbe

    /// `microphoneProbe` is asked only when an older build's "Use the built-in mic even when AirPods are
    /// connected" may have to become an explicit mic choice.
    init(defaults: UserDefaults = .standard,
         microphoneProbe: @escaping () -> MicrophoneMigrationProbe = { .current() }) {
        store = SettingsStore(defaults: defaults)
        self.microphoneProbe = microphoneProbe
        load()
    }

    private init(store: SettingsStore) {
        self.store = store
        microphoneProbe = { MicrophoneMigrationProbe() }
        load()
    }

    /// Nothing touches disk: for previews, snapshots and tests.
    static func inMemory() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: nil))
    }

    // MARK: Models

    /// The engine every dictation starts on: the main model's.
    var mainEngine: EngineID { lineup.main.engine(parakeet: parakeetEngine) }

    /// Some model Switch model can reach needs Parakeet on this Mac, so it's worth loading.
    var usesLocalParakeet: Bool {
        lineup.cycle.contains { $0.usesLocalParakeet(parakeet: parakeetEngine) }
    }

    /// The lineup that stands for what an older build stored, or nil when it stored nothing the lineup replaces (the
    /// engine is Parakeet or absent, and neither switch flag is there). Clean-up and Gemini take part unless their
    /// old flags said no; a Gemini selection from builds before 0.2.0 (Gemini 3.1 Pro too) is the main model again.
    nonisolated static func migratedLineup(storedEngine: EngineID?, switchCleanup: Bool?,
                                           switchEngines: [String]?) -> ModelLineup? {
        let geminiWasMain = storedEngine?.cloudAPI == .chatCompletions
        guard geminiWasMain || switchCleanup != nil || switchEngines != nil else { return nil }
        var lineup = ModelLineup.default
        lineup.setSwitchable(.cleanup, switchCleanup ?? true)
        lineup.setSwitchable(.gemini, switchEngines.map { $0.contains(EngineID.geminiFlash.rawValue) } ?? true)
        if geminiWasMain { lineup.main = .gemini }
        return lineup
    }

    /// Onboarding had six steps (welcome, permissions, model, shortcuts, try it, done) until shortcuts and try it
    /// became one: someone who quit on either of them comes back to the merged step.
    nonisolated static func onboardingStep(fromSixStepIndex index: Int) -> Int {
        switch index {
        case ..<0: 0
        case 0...3: index
        default: index - 1
        }
    }

    /// Initial values come from the store. `init` calls this as a method, so each assignment's `didSet` fires and
    /// writes the value back: one read leniently (the lineup, the model colors) is stored as this build reads it.
    private func load() {
        if let v = store.bool(.onboardingCompleted) { onboardingCompleted = v }
        if let v = store.int(.onboardingResumeStep) {
            onboardingStep = max(0, v)
        } else if let legacy = store.int(.onboardingStep) {
            // Saved by a six-step build: move it over once, under the new key.
            onboardingStep = Self.onboardingStep(fromSixStepIndex: legacy)
            store.set(onboardingStep, .onboardingResumeStep)
            store.remove(.onboardingStep)
        }
        // An engine this build doesn't offer (one since removed) leaves the default.
        let storedEngine = store.string(.selectedEngine).flatMap(EngineID.init(rawValue:))
        if let storedEngine, storedEngine.isParakeet { parakeetEngine = storedEngine }
        if let v: ModelLineup = store.json(.lineup) {
            lineup = v
        } else if let migrated = Self.migratedLineup(storedEngine: storedEngine,
                                                     switchCleanup: store.bool(.switchCleanup),
                                                     switchEngines: store.json(.switchEngines)) {
            // Once: the old keys go below, and the lineup stands for them from now on.
            lineup = migrated
            store.setJSON(migrated, .lineup)
        }
        // A Gemini selection from builds before 0.2.0 is the lineup's main model now; the key holds Parakeet's place.
        if let storedEngine, !storedEngine.isParakeet { store.set(EngineID.default.rawValue, .selectedEngine) }
        store.remove(.switchCleanup)
        store.remove(.switchEngines)
        if let v: ModelColors = store.json(.modelColors) { modelColors = v }
        if let v = store.int(.switchHintShownCount) { switchHintShownCount = max(0, v) }
        if let v = store.string(.pillMode).flatMap(PillMode.init(rawValue:)) { pillMode = v }
        // Older builds could hide the pill for an hour; that deadline has no meaning now.
        store.remove(.pillHiddenUntil)
        // General had a color for the capsule itself; color means the model now (Models), and the pill is graphite
        // again.
        store.remove(.pillColor)
        if let v = store.bool(.soundsEnabled) { soundsEnabled = v }
        // Older builds had a volume slider; sounds now play at their files' own level. A slider left at zero
        // meant no sounds, so it turns "Play sounds" off once, and the old key goes.
        if let volume = store.double(.soundVolume) {
            if volume <= 0, soundsEnabled {
                soundsEnabled = false
                store.set(false, .soundsEnabled)
            }
            store.remove(.soundVolume)
        }
        microphoneUID = store.string(.microphoneUID)
        migrateBuiltInOverBluetoothOnce()
        if let v = store.bool(.showDockIcon) { showDockIcon = v }
        // The prompts are fixed in code now (`EngineID.geminiSystemPrompt`, `CleanupModel.systemPrompt`) and change
        // only with the app: one stored by an older build, edited or not, goes.
        store.remove(.geminiSystemPrompt)
        store.remove(.cleanupSystemPrompt)
        store.remove(.cleanupEnabled)
        // Every model thinks at its own fixed level now, and GPT-6 Luna is the only clean-up model: the stored
        // levels and choice have no meaning any more.
        for key in [SettingsKey.reasoningEfforts, .cleanupModel, .cleanupReasoningEfforts, .cleanupReasoningEffort] {
            store.remove(key)
        }
        // Recordings have no length limit, every paste puts the clipboard back, and a recording's audio lives as long
        // as its History entry (`autoDeleteHistoryDays`): these settings have no meaning any more.
        for key in [SettingsKey.maxRecordingMinutes, .restoreClipboard, .keepFailedRecordingsDays,
                    .keepSuccessfulRecordingsDays] {
            store.remove(key)
        }
        if let v = store.bool(.doublePressForHandsFree) { doublePressForHandsFree = v }
        handsFreeModel = store.string(.handsFreeModel).flatMap(ModelChoice.init(rawValue:))
        if let v = store.bool(.addSpaceAfterText) { addsSpaceAfterText = v }
        if let v = store.bool(.removeFinalPeriod) { removesFinalPeriod = v }
        if let v = store.int(.autoDeleteHistoryDays), v >= 0 { autoDeleteHistoryDays = v }
        if let v: ShortcutBindings = store.json(.shortcuts) { shortcuts = v }
        if let v = store.bool(.hasShownWelcomeHello) { hasShownWelcomeHello = v }
        if let v = store.bool(.checkForUpdatesAutomatically) { checkForUpdatesAutomatically = v }
        announcedUpdateVersion = store.string(.announcedUpdateVersion)
        lastLaunchedVersion = store.string(.lastLaunchedVersion)
        if let v = store.bool(.keychainKeyMigrated) { keychainKeyMigrated = v }
    }
}

// MARK: - Migrations

extension AppSettings {
    /// Older builds had "Use the built-in mic even when AirPods are connected", on by default: with the mic on
    /// Automatic and a Bluetooth default, dictation used the built-in mic, and otherwise the switch did nothing.
    /// The picked mic is now the only choice, so the built-in mic becomes the pick only where the switch was on
    /// (explicitly, or by default on an install past onboarding), the mic was Automatic, the built-in mic can
    /// record, and the switch was doing something right now: the default input is Bluetooth. A switch the user
    /// turned on explicitly also pins the built-in mic while it is the default anyway (nothing changes today, and
    /// AirPods later still don't take over). A USB or other wired default, or a closed lid, stays Automatic.
    /// Once: the old key goes and a marker stays.
    nonisolated static func migratedMicrophoneUID(current: String?, storedPreferBuiltIn: Bool?,
                                                  onboardingCompleted: Bool,
                                                  probe: () -> MicrophoneMigrationProbe) -> String? {
        guard current == nil, storedPreferBuiltIn ?? onboardingCompleted else { return current }
        let inputs = probe()
        guard let builtIn = inputs.availableBuiltInUID else { return current }
        switch inputs.defaultInput {
        case .bluetooth: return builtIn
        case .builtInMicrophone where storedPreferBuiltIn == true: return builtIn
        default: return current
        }
    }

    fileprivate func migrateBuiltInOverBluetoothOnce() {
        guard store.bool(.microphoneChoiceMigrated) != true else { return }
        let uid = Self.migratedMicrophoneUID(current: microphoneUID,
                                             storedPreferBuiltIn: store.bool(.preferBuiltInMicOverBluetooth),
                                             onboardingCompleted: onboardingCompleted,
                                             probe: microphoneProbe)
        if uid != microphoneUID {
            microphoneUID = uid
            store.set(uid, .microphoneUID)
        }
        store.remove(.preferBuiltInMicOverBluetooth)
        store.set(true, .microphoneChoiceMigrated)
    }
}

/// The inputs at the moment the removed switch is migrated: what that switch was deciding then.
struct MicrophoneMigrationProbe: Sendable, Equatable {
    enum DefaultInput: Sendable, Equatable { case bluetooth, builtInMicrophone, other }
    /// The macOS default input's kind; nil when there is none.
    var defaultInput: DefaultInput?
    /// The Mac's own mic, only when it can record now (not with the lid closed).
    var availableBuiltInUID: String?

    static func current() -> Self {
        let records = CoreAudioHAL.inputRecords()
        let builtIn = CoreAudioHAL.builtInMicrophoneUID()
        let defaultID = CoreAudioHAL.defaultInputDeviceID()
        let defaultDevice = records.first { $0.audioID == defaultID }?.device
        return Self(defaultInput: defaultDevice.map { device in
                        device.isBluetooth ? .bluetooth : device.id == builtIn ? .builtInMicrophone : .other
                    },
                    availableBuiltInUID: records.first { $0.device.id == builtIn && $0.device.isAvailable }?.device.id)
    }
}

// MARK: - Storage

enum SettingsKey: String, CaseIterable {
    /// `selectedEngine` holds `parakeetEngine`; named when it was the main model.
    /// `onboardingStep` holds a six-step index from older builds, read once and moved to `onboardingResumeStep`.
    /// `soundVolume` is the removed volume slider's, read once (zero turns sounds off) and removed.
    /// `pillHiddenUntil` is the removed "Hide Pill for 1 Hour" deadline, removed at load.
    /// `pillColor` is the removed capsule color (General › Pill & Sounds), removed at load: color means the model now
    /// (`modelColors`).
    /// `preferBuiltInMicOverBluetooth` is the removed built-in-over-AirPods switch, turned into a mic choice once
    /// (`microphoneChoiceMigrated` records that) and removed.
    case onboardingCompleted, onboardingStep, onboardingResumeStep, selectedEngine, pillMode, pillColor, pillHiddenUntil
    case soundsEnabled, soundVolume, microphoneUID, preferBuiltInMicOverBluetooth, showDockIcon
    /// `maxRecordingMinutes` (the removed "Maximum recording length"), `restoreClipboard` (the removed "Restore the
    /// clipboard after pasting"), `keepFailedRecordingsDays` and `keepSuccessfulRecordingsDays` (how long audio was
    /// kept, now as long as its entry) are removed at load.
    case maxRecordingMinutes, doublePressForHandsFree
    case restoreClipboard, keepFailedRecordingsDays, keepSuccessfulRecordingsDays, shortcuts, hasShownWelcomeHello
    case checkForUpdatesAutomatically, announcedUpdateVersion, lastLaunchedVersion
    /// `switchEngines` (the extra models Switch model stepped to) and `switchCleanup` (whether it stepped to clean-up)
    /// are folded into `lineup` once and removed at load.
    case switchEngines, switchCleanup, switchHintShownCount, microphoneChoiceMigrated
    /// `cleanupEnabled` is the removed "Clean up Parakeet transcripts" switch (every dictation), removed at load:
    /// clean-up is one of the models in `lineup` now.
    /// `reasoningEfforts` (each Gemini model's Thinking level), `cleanupModel` (the clean-up model choice),
    /// `cleanupReasoningEfforts` (each clean-up model's level) and `cleanupReasoningEffort` (Flash Lite's level from
    /// before that choice) are removed at load: every model thinks at a fixed level, and GPT-6 Luna is the only
    /// clean-up model.
    case reasoningEfforts, cleanupEnabled, cleanupReasoningEffort
    case cleanupModel, cleanupReasoningEfforts
    /// `geminiSystemPrompt` and `cleanupSystemPrompt` are the prompts Models used to edit, removed at load: both are
    /// fixed in code now.
    case geminiSystemPrompt, cleanupSystemPrompt
    case addSpaceAfterText, removeFinalPeriod, autoDeleteHistoryDays, lineup, modelColors, keychainKeyMigrated
    case handsFreeModel

    var defaultsKey: String { "tt.\(rawValue)" }
}

/// UserDefaults when given one, otherwise a dictionary. A named suite would still write a plist
/// into ~/Library/Preferences, which previews and tests must not do.
@MainActor
private final class SettingsStore {
    private let defaults: UserDefaults?
    private var memory: [String: Any] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    private func object(_ key: SettingsKey) -> Any? {
        if let defaults { return defaults.object(forKey: key.defaultsKey) }
        return memory[key.defaultsKey]
    }

    private func write(_ value: Any?, _ key: SettingsKey) {
        if let defaults {
            if let value { defaults.set(value, forKey: key.defaultsKey) } else { defaults.removeObject(forKey: key.defaultsKey) }
        } else {
            memory[key.defaultsKey] = value
        }
    }

    func set(_ value: Bool, _ key: SettingsKey) { write(value, key) }
    func set(_ value: Int, _ key: SettingsKey) { write(value, key) }
    func set(_ value: Double, _ key: SettingsKey) { write(value, key) }
    func set(_ value: String?, _ key: SettingsKey) { write(value, key) }
    func remove(_ key: SettingsKey) { write(nil, key) }

    func setJSON<T: Encodable>(_ value: T, _ key: SettingsKey) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        write(data, key)
    }

    func bool(_ key: SettingsKey) -> Bool? { object(key) as? Bool }
    func int(_ key: SettingsKey) -> Int? { (object(key) as? NSNumber)?.intValue }
    func double(_ key: SettingsKey) -> Double? { (object(key) as? NSNumber)?.doubleValue }
    func string(_ key: SettingsKey) -> String? { object(key) as? String }

    func json<T: Decodable>(_ key: SettingsKey) -> T? {
        guard let data = object(key) as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

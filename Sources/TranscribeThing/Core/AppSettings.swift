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
    static let maxRecordingChoices = [5, 10, 20, 30]
    static let switchHintLimit = 3

    var onboardingCompleted: Bool = false { didSet { store.set(onboardingCompleted, .onboardingCompleted) } }
    /// Resume point for onboarding: an `OnboardingStep` raw value (five steps).
    var onboardingStep: Int = 0 { didSet { store.set(onboardingStep, .onboardingResumeStep) } }
    /// The main model, the one every dictation starts with: Parakeet on this Mac or through OpenRouter. An extra
    /// model assigned here (Gemini is picked per dictation, see `switchEngines`) leaves the default selected.
    var selectedEngine: EngineID = .default {
        didSet {
            guard !selectedEngine.isSwitchModel else {
                selectedEngine = .default
                return
            }
            store.set(selectedEngine.rawValue, .selectedEngine)
        }
    }
    /// The extra models the Switch model shortcut steps through, in `EngineID.switchCandidates` order. Empty turns
    /// the shortcut off.
    var switchEngines: [EngineID] = EngineID.switchCandidates {
        didSet {
            let normalized = Self.normalizedSwitchEngines(switchEngines)
            guard normalized == switchEngines else {
                switchEngines = normalized
                return
            }
            store.setJSON(switchEngines.map(\.rawValue), .switchEngines)
        }
    }
    /// How many times the pill has shown the Switch model hint (it shows at most `switchHintLimit` times).
    var switchHintShownCount: Int = 0 { didSet { store.set(switchHintShownCount, .switchHintShownCount) } }
    var pillMode: PillMode = .whileDictating { didSet { store.set(pillMode.rawValue, .pillMode) } }
    var soundsEnabled: Bool = true { didSet { store.set(soundsEnabled, .soundsEnabled) } }
    /// The only mic dictation opens while it is connected. nil = Automatic: the system default input (Bluetooth
    /// included) at the moment a dictation starts.
    var microphoneUID: String? = nil { didSet { store.set(microphoneUID, .microphoneUID) } }
    var showDockIcon: Bool = false { didSet { store.set(showDockIcon, .showDockIcon) } }
    /// Empty by default: Gemini then receives only the audio.
    var geminiSystemPrompt: String = "" { didSet { store.set(geminiSystemPrompt, .geminiSystemPrompt) } }
    /// One of `maxRecordingChoices`.
    var maxRecordingMinutes: Int = 20 { didSet { store.set(maxRecordingMinutes, .maxRecordingMinutes) } }
    var doublePressForHandsFree: Bool = true { didSet { store.set(doublePressForHandsFree, .doublePressForHandsFree) } }
    var restoreClipboard: Bool = true { didSet { store.set(restoreClipboard, .restoreClipboard) } }
    /// Audio is kept only for failed or canceled dictations.
    var keepFailedRecordingsDays: Int = 14 { didSet { store.set(keepFailedRecordingsDays, .keepFailedRecordingsDays) } }
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

    @ObservationIgnored private let store: SettingsStore
    /// Read once at most, by the migration of the removed built-in-over-Bluetooth switch.
    @ObservationIgnored private let builtInMicrophoneUID: () -> String?

    /// `builtInMicrophoneUID` is asked only when an older build's "Use the built-in mic even when AirPods are
    /// connected" has to become an explicit mic choice.
    init(defaults: UserDefaults = .standard,
         builtInMicrophoneUID: @escaping () -> String? = { CoreAudioHAL.builtInMicrophoneUID() }) {
        store = SettingsStore(defaults: defaults)
        self.builtInMicrophoneUID = builtInMicrophoneUID
        load()
    }

    private init(store: SettingsStore) {
        self.store = store
        builtInMicrophoneUID = { nil }
        load()
    }

    /// Nothing touches disk: for previews, snapshots and tests.
    static func inMemory() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: nil))
    }

    var maxRecordingDuration: TimeInterval { TimeInterval(maxRecordingMinutes) * 60 }

    /// The limit a new recording gets with the main model.
    var effectiveMaxRecordingDuration: TimeInterval { maxRecordingDuration(for: selectedEngine) }

    /// The limit of a recording transcribed by `engine`: Gemini takes about 7.4 minutes of audio per request, so
    /// with Gemini a recording stops (and is transcribed) at 7 minutes even when the setting allows more. Parakeet
    /// keeps the setting.
    func maxRecordingDuration(for engine: EngineID) -> TimeInterval {
        guard engine.cloudAPI == .chatCompletions else { return maxRecordingDuration }
        return min(maxRecordingDuration, OpenRouterClient.maxRecordingDuration)
    }

    /// Extra models only, each once, in `EngineID.switchCandidates` order.
    nonisolated static func normalizedSwitchEngines(_ engines: [EngineID]) -> [EngineID] {
        EngineID.switchCandidates.filter(engines.contains)
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

    /// Initial values come from the store; property observers don't fire inside `init`.
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
        // An engine this build doesn't offer (one since removed) leaves the default selected.
        if let v = store.string(.selectedEngine).flatMap(EngineID.init(rawValue:)) {
            if v.isSwitchModel {
                // Gemini used to be selectable as the main model; it is picked per dictation now. Once.
                store.set(EngineID.default.rawValue, .selectedEngine)
            } else {
                selectedEngine = v
            }
        }
        if let v: [String] = store.json(.switchEngines) {
            switchEngines = Self.normalizedSwitchEngines(v.compactMap(EngineID.init(rawValue:)))
        }
        if let v = store.int(.switchHintShownCount) { switchHintShownCount = max(0, v) }
        if let v = store.string(.pillMode).flatMap(PillMode.init(rawValue:)) { pillMode = v }
        // Older builds could hide the pill for an hour; that deadline has no meaning now.
        store.remove(.pillHiddenUntil)
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
        if let v = store.string(.geminiSystemPrompt) { geminiSystemPrompt = v }
        if let v = store.int(.maxRecordingMinutes), v > 0 { maxRecordingMinutes = v }
        if let v = store.bool(.doublePressForHandsFree) { doublePressForHandsFree = v }
        if let v = store.bool(.restoreClipboard) { restoreClipboard = v }
        if let v = store.int(.keepFailedRecordingsDays), v >= 0 { keepFailedRecordingsDays = v }
        if let v: ShortcutBindings = store.json(.shortcuts) { shortcuts = v }
        if let v = store.bool(.hasShownWelcomeHello) { hasShownWelcomeHello = v }
        if let v = store.bool(.checkForUpdatesAutomatically) { checkForUpdatesAutomatically = v }
        announcedUpdateVersion = store.string(.announcedUpdateVersion)
        lastLaunchedVersion = store.string(.lastLaunchedVersion)
    }
}

// MARK: - Migrations

extension AppSettings {
    /// Older builds had "Use the built-in mic even when AirPods are connected", on by default: with the mic on
    /// Automatic and a Bluetooth default, dictation used the built-in mic. The picked mic is now the only choice,
    /// so where that switch was on (explicitly, or by default on an install past onboarding) and the mic was
    /// Automatic, the built-in mic becomes the pick. Once: the old key goes and a marker stays.
    nonisolated static func migratedMicrophoneUID(current: String?, storedPreferBuiltIn: Bool?,
                                                  onboardingCompleted: Bool,
                                                  builtInMicrophoneUID: () -> String?) -> String? {
        guard current == nil, storedPreferBuiltIn ?? onboardingCompleted else { return current }
        return builtInMicrophoneUID()
    }

    fileprivate func migrateBuiltInOverBluetoothOnce() {
        guard store.bool(.microphoneChoiceMigrated) != true else { return }
        let uid = Self.migratedMicrophoneUID(current: microphoneUID,
                                             storedPreferBuiltIn: store.bool(.preferBuiltInMicOverBluetooth),
                                             onboardingCompleted: onboardingCompleted,
                                             builtInMicrophoneUID: builtInMicrophoneUID)
        if uid != microphoneUID {
            microphoneUID = uid
            store.set(uid, .microphoneUID)
        }
        store.remove(.preferBuiltInMicOverBluetooth)
        store.set(true, .microphoneChoiceMigrated)
    }
}

// MARK: - Storage

enum SettingsKey: String, CaseIterable {
    /// `onboardingStep` holds a six-step index from older builds, read once and moved to `onboardingResumeStep`.
    /// `soundVolume` is the removed volume slider's, read once (zero turns sounds off) and removed.
    /// `pillHiddenUntil` is the removed "Hide Pill for 1 Hour" deadline, removed at load.
    /// `preferBuiltInMicOverBluetooth` is the removed built-in-over-AirPods switch, turned into a mic choice once
    /// (`microphoneChoiceMigrated` records that) and removed.
    case onboardingCompleted, onboardingStep, onboardingResumeStep, selectedEngine, pillMode, pillHiddenUntil
    case soundsEnabled, soundVolume, microphoneUID, preferBuiltInMicOverBluetooth, showDockIcon
    case geminiSystemPrompt, maxRecordingMinutes, doublePressForHandsFree
    case restoreClipboard, keepFailedRecordingsDays, shortcuts, hasShownWelcomeHello
    case checkForUpdatesAutomatically, announcedUpdateVersion, lastLaunchedVersion
    case switchEngines, switchHintShownCount, microphoneChoiceMigrated

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

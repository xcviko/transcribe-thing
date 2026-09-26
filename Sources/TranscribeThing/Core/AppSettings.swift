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

    var onboardingCompleted: Bool = false { didSet { store.set(onboardingCompleted, .onboardingCompleted) } }
    /// Resume point for onboarding.
    var onboardingStep: Int = 0 { didSet { store.set(onboardingStep, .onboardingStep) } }
    var selectedEngine: EngineID = .default { didSet { store.set(selectedEngine.rawValue, .selectedEngine) } }
    var pillMode: PillMode = .whileDictating { didSet { store.set(pillMode.rawValue, .pillMode) } }
    var pillHiddenUntil: Date? = nil { didSet { store.set(pillHiddenUntil, .pillHiddenUntil) } }
    var soundsEnabled: Bool = true { didSet { store.set(soundsEnabled, .soundsEnabled) } }
    /// 0...1
    var soundVolume: Double = 0.6 { didSet { store.set(min(max(soundVolume, 0), 1), .soundVolume) } }
    /// nil = follow the system default input.
    var microphoneUID: String? = nil { didSet { store.set(microphoneUID, .microphoneUID) } }
    var preferBuiltInMicOverBluetooth: Bool = true { didSet { store.set(preferBuiltInMicOverBluetooth, .preferBuiltInMicOverBluetooth) } }
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

    @ObservationIgnored private let store: SettingsStore

    init(defaults: UserDefaults = .standard) {
        store = SettingsStore(defaults: defaults)
        load()
    }

    private init(store: SettingsStore) {
        self.store = store
        load()
    }

    /// Nothing touches disk: for previews, snapshots and tests.
    static func inMemory() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: nil))
    }

    var maxRecordingDuration: TimeInterval { TimeInterval(maxRecordingMinutes) * 60 }

    /// The limit a new recording gets: Gemini takes about 7.4 minutes of audio per request, so with Gemini
    /// selected a recording stops (and is transcribed) at 7 minutes even when the setting allows more. Cloud
    /// Parakeet keeps the setting.
    var effectiveMaxRecordingDuration: TimeInterval {
        guard selectedEngine.cloudAPI == .chatCompletions else { return maxRecordingDuration }
        return min(maxRecordingDuration, OpenRouterClient.maxRecordingDuration)
    }

    /// Pill hidden by "Hide for 1 hour" right now.
    func isPillTemporarilyHidden(now: Date = Date()) -> Bool {
        guard let until = pillHiddenUntil else { return false }
        return until > now
    }

    func hidePill(for interval: TimeInterval = 3600, now: Date = Date()) {
        pillHiddenUntil = now.addingTimeInterval(interval)
    }

    /// Initial values come from the store; property observers don't fire inside `init`.
    private func load() {
        if let v = store.bool(.onboardingCompleted) { onboardingCompleted = v }
        if let v = store.int(.onboardingStep) { onboardingStep = max(0, v) }
        // An engine this build doesn't offer (one since removed) leaves the default selected.
        if let v = store.string(.selectedEngine).flatMap(EngineID.init(rawValue:)) { selectedEngine = v }
        if let v = store.string(.pillMode).flatMap(PillMode.init(rawValue:)) { pillMode = v }
        pillHiddenUntil = store.date(.pillHiddenUntil)
        if let v = store.bool(.soundsEnabled) { soundsEnabled = v }
        if let v = store.double(.soundVolume) { soundVolume = min(max(v, 0), 1) }
        microphoneUID = store.string(.microphoneUID)
        if let v = store.bool(.preferBuiltInMicOverBluetooth) { preferBuiltInMicOverBluetooth = v }
        if let v = store.bool(.showDockIcon) { showDockIcon = v }
        if let v = store.string(.geminiSystemPrompt) { geminiSystemPrompt = v }
        if let v = store.int(.maxRecordingMinutes), v > 0 { maxRecordingMinutes = v }
        if let v = store.bool(.doublePressForHandsFree) { doublePressForHandsFree = v }
        if let v = store.bool(.restoreClipboard) { restoreClipboard = v }
        if let v = store.int(.keepFailedRecordingsDays), v >= 0 { keepFailedRecordingsDays = v }
        if let v: ShortcutBindings = store.json(.shortcuts) { shortcuts = v }
        if let v = store.bool(.hasShownWelcomeHello) { hasShownWelcomeHello = v }
    }
}

// MARK: - Storage

enum SettingsKey: String, CaseIterable {
    case onboardingCompleted, onboardingStep, selectedEngine, pillMode, pillHiddenUntil
    case soundsEnabled, soundVolume, microphoneUID, preferBuiltInMicOverBluetooth, showDockIcon
    case geminiSystemPrompt, maxRecordingMinutes, doublePressForHandsFree
    case restoreClipboard, keepFailedRecordingsDays, shortcuts, hasShownWelcomeHello

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
    func set(_ value: Date?, _ key: SettingsKey) { write(value, key) }

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
    func date(_ key: SettingsKey) -> Date? { object(key) as? Date }

    func json<T: Decodable>(_ key: SettingsKey) -> T? {
        guard let data = object(key) as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

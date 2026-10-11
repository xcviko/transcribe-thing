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
    /// Where Parakeet v3 runs, on this Mac or through OpenRouter (`ModelChoice.parakeet`). Anything but Parakeet
    /// leaves the default. Stored under `SettingsKey.selectedEngine`.
    var parakeetEngine: EngineID = .default {
        didSet {
            if !parakeetEngine.isParakeet { parakeetEngine = .default }
            store.set(parakeetEngine.rawValue, .selectedEngine)
        }
    }
    /// The models as Models lists them: their order, the main model every dictation starts on, and which
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
    /// What floats above the pill to say what's going on: the model's name after a switch, the Switch model hint, a
    /// word about a key that did nothing. Off, the pill's color tells the model, and the keys work all the same.
    var showsPillHints: Bool = true { didSet { store.set(showsPillHints, .showsPillHints) } }
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
    /// The model a hands-free dictation switches to as it starts (Models), as if Switch model had stepped to it: a long
    /// dictation is usually one for Gemini. nil: the main model, as when holding the key.
    var handsFreeModel: ModelChoice? = nil { didSet { store.set(handsFreeModel?.rawValue, .handsFreeModel) } }
    /// `handsFreeModel` while Switch model reaches it and it isn't the main model; nil otherwise. A hands-free
    /// dictation is on a model of the cycle, like any other: fn ⇥ steps on from it, the pill's menu checks it, and a
    /// local Parakeet in the cycle is loaded at launch.
    var handsFreeChoice: ModelChoice? {
        handsFreeModel.flatMap { lineup.steps.contains($0) ? $0 : nil }
    }
    /// The models whose text the app pastes with one space after it, so the next dictation doesn't run into it
    /// (General → Pasting). History and Copy keep the text as it was.
    var modelsAddingSpace: Set<ModelChoice> = [] {
        didSet { store.setJSON(ModelChoice.stored(modelsAddingSpace), .modelsAddingSpace) }
    }
    /// The models whose text the app pastes without a single final period (`PastedText`). History and Copy keep the
    /// text as it was.
    var modelsRemovingFinalPeriod: Set<ModelChoice> = [] {
        didSet { store.setJSON(ModelChoice.stored(modelsRemovingFinalPeriod), .modelsRemovingFinalPeriod) }
    }
    /// The dictations, held or hands-free, whose text gets that space. Both by default.
    var modesAddingSpace: Set<DictationMachine.Mode> = Set(DictationMachine.Mode.allCases) {
        didSet { store.setJSON(DictationMachine.Mode.stored(modesAddingSpace), .modesAddingSpace) }
    }
    /// The dictations, held or hands-free, whose text loses its final period. Both by default.
    var modesRemovingFinalPeriod: Set<DictationMachine.Mode> = Set(DictationMachine.Mode.allCases) {
        didSet { store.setJSON(DictationMachine.Mode.stored(modesRemovingFinalPeriod), .modesRemovingFinalPeriod) }
    }

    /// General → Pasting's space, for text `model` wrote in a dictation of `mode`: both have to be picked.
    func addsSpace(by model: ModelChoice, in mode: DictationMachine.Mode) -> Bool {
        modelsAddingSpace.contains(model) && modesAddingSpace.contains(mode)
    }

    /// General → Pasting's final period, for text `model` wrote in a dictation of `mode`: both have to be picked.
    func removesFinalPeriod(by model: ModelChoice, in mode: DictationMachine.Mode) -> Bool {
        modelsRemovingFinalPeriod.contains(model) && modesRemovingFinalPeriod.contains(mode)
    }
    /// The two languages Translate (fn T) goes between (General → Translate). Two different languages: picking one the
    /// other already has swaps them.
    var translationPair: TranslationPair = .default {
        didSet { store.setJSON(translationPair, .translationPair) }
    }
    /// Words, names and terms Gemini 3.8 Flash gets as a hint, with their spelling (Hub → Dictionary, fn D).
    var dictionary = UserDictionary() {
        didSet {
            store.setJSON(dictionary, .dictionary)
            if dictionary.grouping != oldValue.grouping { store.setJSON(dictionary.grouping, .dictionaryGroups) }
        }
    }
    /// Whether calls (any app, or browser tab, using the mic and playing sound together) are noticed and recorded,
    /// asking first (the default) or not (`CallMonitor`). The menu bar's Start Call Recording works whatever this says.
    var callRecording: CallRecordingMode = .ask { didSet { store.set(callRecording.rawValue, .callRecording) } }
    /// Apps and sites whose calls are never noticed ("Never for …" on the question, General → Calls), oldest first.
    var callExclusions: [CallExclusion] = [] { didSet { store.setJSON(callExclusions, .callExclusions) } }
    /// Brief, silent notices above the pill about the call being recorded: noticed, muted or unmuted, mute not
    /// followed, ended (`CallNotices`).
    var showsCallNotices: Bool = true { didSet { store.set(showsCallNotices, .showsCallNotices) } }
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
    /// The version just updated to, until its "Updated to …" has shown after a dictation (`UpdateCenter`). Kept across
    /// launches, so quitting before dictating doesn't lose it.
    var updatedVersionToAnnounce: String? = nil {
        didSet { store.set(updatedVersionToAnnounce, .updatedVersionToAnnounce) }
    }
    /// The OpenRouter key older builds kept in the login keychain is settled: moved to its key file, never there, or
    /// a key was saved or removed since (`KeychainMigration`). From then on the Keychain is never asked again.
    var keychainKeyMigrated: Bool = false { didSet { store.set(keychainKeyMigrated, .keychainKeyMigrated) } }
    /// The user's OpenAI-compatible endpoint (Models → API keys): its base URL as `VertexProxy.normalizedBaseURL`
    /// gives it, nil when none is set. A host-only value (what builds before the endpoint was generic saved for the
    /// Vertex proxy) still reads as `<host>/api/v1`. The name is from then, kept so a saved URL needs no migration.
    /// Its key is in its own key file (`AppPaths.vertexProxyKeyFile`), never here.
    var vertexProxyURL: String? = nil { didSet { store.set(vertexProxyURL, .vertexProxyURL) } }
    /// "Use for Gemini": with an endpoint set up, every Gemini request goes to it instead of OpenRouter. Off keeps
    /// the endpoint's URL and key, and Gemini goes through OpenRouter again.
    var vertexProxyEnabled: Bool = true { didSet { store.set(vertexProxyEnabled, .vertexProxyEnabled) } }

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

    // MARK: Calls

    /// Adds `exclusion` (once): that app's or site's calls are never noticed again.
    func excludeFromCalls(_ exclusion: CallExclusion) {
        guard !callExclusions.contains(where: { $0.id == exclusion.id }) else { return }
        callExclusions.append(exclusion)
    }

    /// Takes `exclusion` off the list: its calls are noticed again.
    func removeCallExclusion(_ exclusion: CallExclusion) {
        callExclusions.removeAll { $0.id == exclusion.id }
    }

    // MARK: Models

    /// The engine every dictation starts on: the main model's.
    var mainEngine: EngineID { lineup.main.engine(parakeet: parakeetEngine) }

    /// Some model Switch model can reach needs Parakeet on this Mac, so it's worth loading.
    var usesLocalParakeet: Bool {
        lineup.cycle.contains { $0.usesLocalParakeet(parakeet: parakeetEngine) }
    }

    /// The lineup that stands for what an older build stored, or nil when it stored nothing the lineup replaces (the
    /// engine is Parakeet or absent, and neither switch flag is there). Gemini takes part unless its old flag said no
    /// (the clean-up flag has nothing left to say: clean-up is gone); a Gemini selection from builds before 0.2.0
    /// (Gemini 3.1 Pro too) is the main model again.
    nonisolated static func migratedLineup(storedEngine: EngineID?, switchCleanup: Bool?,
                                           switchEngines: [String]?) -> ModelLineup? {
        let geminiWasMain = storedEngine?.cloudAPI == .chatCompletions
        guard geminiWasMain || switchCleanup != nil || switchEngines != nil else { return nil }
        var lineup = ModelLineup.default
        lineup.setSwitchable(.gemini, switchEngines.map { $0.contains(EngineID.geminiFlash.rawValue) } ?? true)
        if geminiWasMain { lineup.main = .gemini }
        return lineup
    }

    /// The stored hands-free model, read leniently. The removed clean-up was Parakeet's text tidied, so it becomes
    /// Parakeet while Switch model reaches Parakeet (`ModelLineup` turns Parakeet on where clean-up was), and
    /// otherwise no model of its own: the main model, which is then Parakeet or one Parakeet was switched off for.
    nonisolated static func handsFreeModel(stored raw: String?, lineup: ModelLineup) -> ModelChoice? {
        guard raw == ModelChoice.retiredCleanup else { return raw.flatMap(ModelChoice.init(rawValue:)) }
        return lineup.steps.contains(.parakeet) ? .parakeet : nil
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
        if let v = store.bool(.showsPillHints) { showsPillHints = v }
        // Asking twice was a switch for a day (General → Experimental); every dictation does it now.
        store.remove(.sendsTwice)
        store.remove(.measuresSendingTwice)
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
        // Gemini's prompt is fixed in code now (`EngineID.geminiSystemPrompt`) and changes only with the app, and
        // clean-up is gone: a prompt stored by an older build, edited or not, goes.
        store.remove(.geminiSystemPrompt)
        store.remove(.cleanupSystemPrompt)
        store.remove(.cleanupEnabled)
        // Polish Selection asks both its models at once now (to pick the better answer): the stored choice goes.
        store.remove(.polishSelectionModel)
        // Every model thinks at its own fixed level now, and clean-up is gone: the stored levels and clean-up model
        // choice have no meaning any more.
        for key in [SettingsKey.reasoningEfforts, .cleanupModel, .cleanupReasoningEfforts, .cleanupReasoningEffort] {
            store.remove(key)
        }
        // Recordings have no length limit, every paste puts the clipboard back, and a recording's audio lives as long
        // as its History entry (`autoDeleteHistoryDays`): these settings have no meaning any more.
        for key in [SettingsKey.maxRecordingMinutes, .restoreClipboard, .keepFailedRecordingsDays,
                    .keepSuccessfulRecordingsDays] {
            store.remove(key)
        }
        // A double press of push-to-talk no longer starts hands-free, and Return no longer finishes it (fn and the
        // pill's check button do): both switches have no meaning any more.
        store.remove(.doublePressForHandsFree)
        store.remove(.returnFinishesHandsFree)
        handsFreeModel = Self.handsFreeModel(stored: store.string(.handsFreeModel), lineup: lineup)
        // Pasting's two switches held for every model; each is picked per model now. One an older build turned on
        // holds for all of them, once: the old keys go. The removed clean-up drops out of the sets (`ModelChoice.read`).
        if let v: [String] = store.json(.modelsAddingSpace) {
            modelsAddingSpace = ModelChoice.read(v)
        } else if store.bool(.addSpaceAfterText) == true {
            modelsAddingSpace = Set(ModelChoice.allCases)
        }
        if let v: [String] = store.json(.modelsRemovingFinalPeriod) {
            modelsRemovingFinalPeriod = ModelChoice.read(v)
        } else if store.bool(.removeFinalPeriod) == true {
            modelsRemovingFinalPeriod = Set(ModelChoice.allCases)
        }
        store.remove(.addSpaceAfterText)
        store.remove(.removeFinalPeriod)
        if let v: [String] = store.json(.modesAddingSpace) { modesAddingSpace = DictationMachine.Mode.read(v) }
        if let v: [String] = store.json(.modesRemovingFinalPeriod) {
            modesRemovingFinalPeriod = DictationMachine.Mode.read(v)
        }
        // A language this build doesn't know (from a newer one) leaves the default pair.
        if let v: TranslationPair = store.json(.translationPair), v.first != v.second { translationPair = v }
        if let v: UserDictionary = store.json(.dictionary) {
            var loaded = v
            if let grouping: UserDictionary.Grouping = store.json(.dictionaryGroups) { loaded.grouping = grouping }
            dictionary = loaded
        }
        if let v = store.int(.autoDeleteHistoryDays), v >= 0 { autoDeleteHistoryDays = v }
        if let v = store.string(.callRecording).flatMap(CallRecordingMode.init(rawValue:)) { callRecording = v }
        if let v: [CallExclusion] = store.json(.callExclusions) { callExclusions = v }
        if let v = store.bool(.showsCallNotices) { showsCallNotices = v }
        if let v = store.string(.vertexProxyURL), !v.isEmpty { vertexProxyURL = v }
        if let v = store.bool(.vertexProxyEnabled) { vertexProxyEnabled = v }
        if let v: ShortcutBindings = store.json(.shortcuts) { shortcuts = v }
        // Polish moved from fn ↩ to fn P (when ↩ finished a hands-free dictation): a build that had it on fn ↩ by default
        // moves it, once, unless fn P is taken. Bound to fn ↩ again after that, it stays.
        if store.bool(.polishMovedToFnP) != true {
            if shortcuts[.polish] == .fnReturn, shortcuts.conflict(for: .fnP, excluding: .polish) == nil {
                shortcuts[.polish] = .fnP
            }
            store.set(true, .polishMovedToFnP)
        }
        if let v = store.bool(.hasShownWelcomeHello) { hasShownWelcomeHello = v }
        if let v = store.bool(.checkForUpdatesAutomatically) { checkForUpdatesAutomatically = v }
        announcedUpdateVersion = store.string(.announcedUpdateVersion)
        lastLaunchedVersion = store.string(.lastLaunchedVersion)
        updatedVersionToAnnounce = store.string(.updatedVersionToAnnounce)
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
    /// kept, now as long as its entry) are removed at load. So is `doublePressForHandsFree` (the removed
    /// "Double-press to go hands-free").
    case maxRecordingMinutes, doublePressForHandsFree
    case restoreClipboard, keepFailedRecordingsDays, keepSuccessfulRecordingsDays, shortcuts, hasShownWelcomeHello
    case checkForUpdatesAutomatically, announcedUpdateVersion, lastLaunchedVersion, updatedVersionToAnnounce
    /// `switchEngines` (the extra models Switch model stepped to) and `switchCleanup` (whether it stepped to the
    /// removed clean-up) are folded into `lineup` once and removed at load.
    case switchEngines, switchCleanup, switchHintShownCount, microphoneChoiceMigrated
    /// `cleanupEnabled` is the removed "Clean up Parakeet transcripts" switch (every dictation), removed at load:
    /// clean-up became a model in `lineup`, and is gone now.
    /// `reasoningEfforts` (each Gemini model's Thinking level), `cleanupModel` (the clean-up model choice),
    /// `cleanupReasoningEfforts` (each clean-up model's level) and `cleanupReasoningEffort` (Flash Lite's level from
    /// before that choice) are removed at load: every model thinks at a fixed level, and clean-up is gone.
    case reasoningEfforts, cleanupEnabled, cleanupReasoningEffort
    case cleanupModel, cleanupReasoningEfforts
    /// `geminiSystemPrompt` and `cleanupSystemPrompt` are the prompts Models used to edit, removed at load: Gemini's
    /// is fixed in code now, and clean-up is gone.
    case geminiSystemPrompt, cleanupSystemPrompt
    /// `addSpaceAfterText` and `removeFinalPeriod` are Pasting's switches from when they held for every model, read
    /// once into `modelsAddingSpace` and `modelsRemovingFinalPeriod` and removed at load.
    case addSpaceAfterText, removeFinalPeriod, autoDeleteHistoryDays, lineup, modelColors, keychainKeyMigrated
    case handsFreeModel, modelsAddingSpace, modelsRemovingFinalPeriod, dictionary
    case modesAddingSpace, modesRemovingFinalPeriod
    /// The Dictionary page's groups, apart from the words (`UserDictionary.Grouping`).
    case dictionaryGroups
    /// The removed "Return finishes a hands-free dictation", removed at load. Stored under its first name, from when
    /// Return also sent what it finished.
    case returnFinishesHandsFree = "returnSendsHandsFree"
    /// Polish's default left fn ↩ for fn P: set once its old default has been moved (`load`).
    case polishMovedToFnP, showsPillHints
    /// The day-old switches of asking twice (`CloudHedge`), removed at load: every dictation asks twice now.
    case sendsTwice, measuresSendingTwice
    case polishSelectionModel, translationPair
    /// How calls are recorded (`CallRecordingMode`), and the apps and sites never recorded.
    case callRecording, callExclusions, showsCallNotices
    /// The OpenAI-compatible endpoint's base URL and whether Gemini goes through it.
    case vertexProxyURL, vertexProxyEnabled

    var defaultsKey: String { "tt.\(rawValue)" }
}

extension DictationMachine.Mode {
    /// A set of modes as stored (General → Pasting's): raw values in declaration order, so the value is stable.
    static func stored(_ modes: Set<Self>) -> [String] {
        allCases.filter(modes.contains).map(\.rawValue)
    }

    /// A stored set, read leniently: a mode this build doesn't know is dropped.
    static func read(_ raw: [String]) -> Set<Self> {
        Set(raw.compactMap(Self.init(rawValue:)))
    }
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

import Foundation

/// What a dictation goes to. Models lists all three in the user's order (`ModelLineup`): one is the main model every
/// dictation starts on, and Switch model steps through the others that are switched on. Raw values are persisted (the
/// lineup): never rename them. Declaration order is the default order.
enum ModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Parakeet v3 alone, where `AppSettings.parakeetEngine` runs it.
    case parakeet
    /// The same Parakeet v3, then `CleanupModel.default` tidies its text before it's pasted. A pass over Parakeet's
    /// words, not a model that hears the audio.
    case cleanup
    /// Gemini 3.8 Flash (`EngineID.geminiFlash`), which hears the audio itself.
    case gemini

    var id: String { rawValue }

    /// The choice a job or a kept recording was made with (Undo, the processing pill): any chat-completions engine
    /// (the retired Gemini 3.1 Pro too) is Gemini, and Parakeet anywhere is Parakeet, cleaned up or not.
    init(engine: EngineID, cleansUp: Bool) {
        if engine.cloudAPI == .chatCompletions {
            self = .gemini
        } else {
            self = cleansUp ? .cleanup : .parakeet
        }
    }

    /// The engine that hears the audio: Parakeet where `parakeet` runs it, or Gemini 3.8 Flash.
    func engine(parakeet: EngineID) -> EngineID {
        switch self {
        case .parakeet, .cleanup: parakeet
        case .gemini: .geminiFlash
        }
    }

    var cleansUp: Bool { self == .cleanup }

    /// It goes through the OpenRouter key: clean-up and Gemini always, Parakeet when it runs there.
    func needsOpenRouter(parakeet: EngineID) -> Bool {
        switch self {
        case .parakeet: parakeet.isCloud
        case .cleanup, .gemini: true
        }
    }

    /// It needs Parakeet on this Mac (downloaded, loaded).
    func usesLocalParakeet(parakeet: EngineID) -> Bool {
        switch self {
        case .parakeet, .cleanup: parakeet.isLocal
        case .gemini: false
        }
    }
}

extension ModelChoice {
    /// The model's own name, wherever it runs: "Parakeet v3", "Parakeet v3 + GPT-6 Luna", "Gemini 3.8 Flash". The
    /// Models rows, which say where Parakeet runs in a section of their own.
    var modelName: String {
        switch self {
        case .parakeet: EngineID.parakeet.modelName
        case .cleanup: "\(EngineID.parakeet.modelName) + \(CleanupModel.default.modelName)"
        case .gemini: EngineID.geminiFlash.modelName
        }
    }

    /// The full name, with Parakeet's "· Cloud" when it runs through OpenRouter: the menu bar, the pill's menu and
    /// accessibility, onboarding's Done step.
    func title(parakeet: EngineID) -> String {
        switch self {
        case .parakeet: parakeet.displayName
        case .cleanup, .gemini: modelName
        }
    }

    /// One word for chains and sentences: "Parakeet → Clean-up → Gemini", "Clean-up and Gemini need…".
    var shortName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .cleanup: "Clean-up"
        case .gemini: "Gemini"
        }
    }

    /// The sidebar chip's name: "Parakeet v3 · Cloud", "Parakeet + Luna", "Gemini Flash".
    func compactName(parakeet: EngineID) -> String {
        switch self {
        case .parakeet: parakeet.shortName
        case .cleanup: "Parakeet + Luna"
        case .gemini: EngineID.geminiFlash.shortName
        }
    }

    /// The pill chip's name after its symbol: "Parakeet", "Gemini 3.8 Flash"; for clean-up the model after the wand,
    /// "GPT-6 Luna", which the chip heads with Parakeet's name dimmed.
    var chipName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .cleanup: CleanupModel.default.modelName
        case .gemini: EngineID.geminiFlash.modelName
        }
    }

    /// Parakeet's bolt (a cloud bolt through OpenRouter), clean-up's wand, Gemini's sparkles.
    func symbolName(parakeet: EngineID) -> String {
        switch self {
        case .parakeet: parakeet.symbolName
        case .cleanup: "wand.and.stars"
        case .gemini: "sparkles"
        }
    }

    /// Short names in a sentence, and whether it takes a plural verb: "Gemini", "Clean-up and Gemini", "Parakeet,
    /// Clean-up and Gemini".
    static func sentenceList(_ choices: [ModelChoice]) -> (names: String, isPlural: Bool) {
        let names = choices.map(\.shortName)
        guard let last = names.last else { return ("", false) }
        guard names.count > 1 else { return (last, false) }
        return (names.dropLast().joined(separator: ", ") + " and " + last, true)
    }
}

/// The three models as Models lists them: the user's order, the main model every dictation starts on, and which
/// others Switch model steps to. One JSON value under `SettingsKey.lineup`.
struct ModelLineup: Equatable, Sendable {
    /// Every `ModelChoice` exactly once, in the user's order.
    private(set) var order: [ModelChoice]
    /// The model every dictation starts on, always part of the cycle. The one it replaces is switched on: it was in
    /// the cycle, so changing the main model never leaves a model out (whatever its flag said before it was main).
    var main: ModelChoice {
        didSet { if main != oldValue { switchable.insert(oldValue) } }
    }
    /// The models Switch model steps to besides the main model. The main model's own flag doesn't count while it's
    /// main, and is switched on when it stops being main (`main`).
    private(set) var switchable: Set<ModelChoice>

    /// What every install starts with, and what builds before the lineup did: Parakeet, then clean-up, then Gemini.
    static let `default` = ModelLineup(order: [.parakeet, .cleanup, .gemini], main: .parakeet,
                                       switchable: [.cleanup, .gemini])

    /// `order` loses duplicates and gets every missing choice appended, in `allCases` order.
    init(order: [ModelChoice], main: ModelChoice, switchable: Set<ModelChoice>) {
        var complete: [ModelChoice] = []
        for choice in order + ModelChoice.allCases where !complete.contains(choice) {
            complete.append(choice)
        }
        self.order = complete
        self.main = main
        self.switchable = switchable
    }

    /// Switch model reaches it: the main model always, any other while it's switched on.
    func isSwitchable(_ choice: ModelChoice) -> Bool {
        choice == main || switchable.contains(choice)
    }

    /// What Switch model steps through: `order` from the main model on, wrapping around, without the models switched
    /// off. The main model comes first.
    var cycle: [ModelChoice] {
        let start = order.firstIndex(of: main) ?? 0
        return (order[start...] + order[..<start]).filter(isSwitchable)
    }

    /// The models Switch model steps to after the main model, in order.
    var steps: [ModelChoice] { Array(cycle.dropFirst()) }

    mutating func setSwitchable(_ choice: ModelChoice, _ on: Bool) {
        if on { switchable.insert(choice) } else { switchable.remove(choice) }
    }

    /// Moves `choice` to `index` of the new order (clamped): drag to reorder, Move Up and Move Down.
    mutating func move(_ choice: ModelChoice, to index: Int) {
        guard let from = order.firstIndex(of: choice) else { return }
        order.remove(at: from)
        order.insert(choice, at: min(max(0, index), order.count))
    }
}

extension ModelLineup: Codable {
    private enum CodingKeys: String, CodingKey {
        case main, order, switchable
    }

    /// Lenient, as a stored value outlives builds: unknown values and duplicates are dropped, a missing choice is
    /// appended and switched off, and an unknown main model is Parakeet.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
        let switchable = (try? container.decodeIfPresent([String].self, forKey: .switchable)) ?? []
        let main = (try? container.decodeIfPresent(String.self, forKey: .main)) ?? nil
        self.init(order: order.compactMap(ModelChoice.init(rawValue:)),
                  main: main.flatMap(ModelChoice.init(rawValue:)) ?? .parakeet,
                  switchable: Set(switchable.compactMap(ModelChoice.init(rawValue:))))
    }

    /// `switchable` in `order` order, so the stored JSON is stable.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(main, forKey: .main)
        try container.encode(order, forKey: .order)
        try container.encode(order.filter(switchable.contains), forKey: .switchable)
    }
}

/// A model's color, picked on its row in Models (`AppSettings.modelColors`): the pill's ring and marks while it
/// dictates (`PillPalette.accent(for:)`), and its tile and History's marks in the Hub. Graphite is the plain pill. Raw
/// values are persisted: never rename them. Declaration order is the picker's: graphite, then round the hue wheel.
enum ModelColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case graphite, orange, green, teal, blue, violet, purple, pink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .orange: "Orange"
        case .green: "Green"
        case .teal: "Teal"
        case .blue: "Blue"
        case .violet: "Violet"
        case .purple: "Purple"
        case .pink: "Pink"
        }
    }
}

extension ModelChoice {
    /// Its color until one is picked, as before colors could be: Parakeet the plain pill, clean-up orange (its wand),
    /// Gemini violet.
    var defaultColor: ModelColor {
        switch self {
        case .parakeet: .graphite
        case .cleanup: .orange
        case .gemini: .violet
        }
    }
}

/// Each model's color; two models may share one. One JSON object under `SettingsKey.modelColors`, keyed by
/// `ModelChoice` raw value: {"cleanup":"orange","gemini":"violet","parakeet":"graphite"}.
struct ModelColors: Equatable, Sendable {
    private var colors: [ModelChoice: ModelColor]

    /// Every model in its `defaultColor`.
    static let `default` = ModelColors()

    init() {
        colors = Dictionary(uniqueKeysWithValues: ModelChoice.allCases.map { ($0, $0.defaultColor) })
    }

    subscript(_ choice: ModelChoice) -> ModelColor {
        get { colors[choice] ?? choice.defaultColor }
        set { colors[choice] = newValue }
    }
}

extension ModelColors: Codable {
    private struct ChoiceKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ choice: ModelChoice) { stringValue = choice.rawValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Lenient, as a stored value outlives builds: a color this build doesn't offer (a newer build's), or a value of
    /// the wrong kind, leaves that model's default; an unknown model is ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ChoiceKey.self)
        self.init()
        for choice in ModelChoice.allCases {
            let raw = (try? container.decodeIfPresent(String.self, forKey: ChoiceKey(choice))) ?? nil
            if let color = raw.flatMap(ModelColor.init(rawValue:)) { self[choice] = color }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ChoiceKey.self)
        for choice in ModelChoice.allCases {
            try container.encode(self[choice].rawValue, forKey: ChoiceKey(choice))
        }
    }
}

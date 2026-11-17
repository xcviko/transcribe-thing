import Foundation

/// What a dictation goes to. Models lists them in the user's order (`ModelLineup`): one is the main model every
/// dictation starts on, and Switch model steps to the others switched on. Raw values are persisted (the lineup): never
/// rename them. Declaration order is the default order.
///
/// Clean-up ("cleanup", Parakeet's text tidied by GPT-6 Luna) was a model until it was removed: a stored value that
/// names it is read as Parakeet where it was the main or hands-free model, and dropped elsewhere (`retiredCleanup`).
/// Gemini 4 Argon ("argon") was a model until it was removed too: a stored value that names it is read as Gemini 3.8
/// Flash where it was the main, hands-free or a Switch model step, and dropped elsewhere (`retiredArgon`).
/// Parakeet ran through OpenRouter too until that was removed (`EngineID.parakeetCloud`): Parakeet is on this Mac now.
/// Gemini 4 Carbon ("carbon") came after Argon was removed: a choice of its own, never what "argon" reads as.
/// GigaAM ("gigaam") came after Carbon: a second model on this Mac, in three versions, last in the default order.
/// Gemini 4 Hydrogen ("hydrogen") came after GigaAM: Google's newer Flash-class model, between Flash and Carbon in the
/// default order. A lineup stored before it gets it at the end (`ModelLineup.init(order:main:switchable:)`).
enum ModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Parakeet v3 on this Mac.
    case parakeet
    /// Gemini 3.8 Flash (`EngineID.geminiFlash`), which hears the audio itself. Named when it was the only Gemini.
    case gemini
    /// Gemini 4 Hydrogen (`EngineID.geminiHydrogen`): newer than Flash, faster on long dictations, and about twice its
    /// price per token.
    case hydrogen
    /// Gemini 4 Carbon (`EngineID.geminiCarbon`): newer than Flash, slower, and about 2.7 times its cost.
    case carbon
    /// GigaAM on this Mac (`EngineID.gigaam`): Sber's model, in the version picked in Models
    /// (`AppSettings.gigaamVariant`).
    case gigaam

    var id: String { rawValue }

    /// The raw value of the removed clean-up model, as older builds stored it.
    static let retiredCleanup = "cleanup"
    /// The raw value of the removed Gemini 4 Argon, as older builds stored it: read as Gemini 3.8 Flash where it was
    /// picked (`init(stored:)`).
    static let retiredArgon = "argon"

    /// A choice older builds stored, read leniently: the removed Gemini 4 Argon is Gemini 3.8 Flash, the Gemini that
    /// stays; nil for anything else this build doesn't know (the removed clean-up too).
    init?(stored raw: String) {
        self.init(rawValue: raw == Self.retiredArgon ? Self.gemini.rawValue : raw)
    }

    /// The choice a job or a kept recording was made with (Undo, the processing pill, History's colors): Gemini 4
    /// Hydrogen is Hydrogen, Gemini 4 Carbon is Carbon, any other Gemini (Flash, and the retired Argon and 3.1 Pro) is
    /// Gemini, GigaAM is GigaAM, and Parakeet anywhere (the retired cloud one too) is Parakeet.
    init(engine: EngineID) {
        switch engine {
        case .gigaam: self = .gigaam
        case .geminiHydrogen: self = .hydrogen
        case .geminiCarbon: self = .carbon
        case .geminiFlash, .geminiArgon, .geminiPro: self = .gemini
        case .parakeet, .parakeetCloud: self = .parakeet
        }
    }

    /// The engine that hears the audio.
    var engine: EngineID {
        switch self {
        case .parakeet: .parakeet
        case .gemini: .geminiFlash
        case .hydrogen: .geminiHydrogen
        case .carbon: .geminiCarbon
        case .gigaam: .gigaam
        }
    }

    /// A Gemini model: it goes through the OpenRouter key (or the user's endpoint), and Polish and Translate work on
    /// it while dictating.
    var isGemini: Bool { engine.isGemini }

    /// It runs on this Mac (Parakeet, GigaAM): its engine has to be downloaded and loaded.
    var isLocal: Bool { engine.isLocal }
}

extension ModelChoice {
    /// The model's own name: "Parakeet v3", "Gemini 3.8 Flash", "Gemini 4 Hydrogen", "Gemini 4 Carbon", "GigaAM".
    /// Where there's room, GigaAM goes by its picked version (`AppSettings.modelName(of:)`): Models' rows, menus, the
    /// pill's chip and menu.
    var modelName: String { engine.modelName }

    /// The full name. The same as `modelName` now that Parakeet runs only on this Mac.
    var title: String { modelName }

    /// One word for chains, sentences and narrow columns: "Parakeet → Flash → Carbon", "Flash and Carbon need…".
    var shortName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .gemini: "Flash"
        case .hydrogen: "Hydrogen"
        case .carbon: "Carbon"
        case .gigaam: "GigaAM"
        }
    }

    /// The sidebar chip's name: "Parakeet v3", "Gemini 3.8 Flash", "Gemini 4 Hydrogen", "Gemini 4 Carbon", "GigaAM".
    var compactName: String { engine.shortName }

    /// The pill chip's name after its symbol: "Parakeet", "Gemini 3.8 Flash", "Gemini 4 Hydrogen", "Gemini 4 Carbon",
    /// "GigaAM".
    var chipName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .gigaam: "GigaAM"
        case .gemini, .hydrogen, .carbon: engine.modelName
        }
    }

    /// Parakeet's bolt, Flash's sparkles, Hydrogen's drop, Carbon's atom, GigaAM's speech bubble.
    var symbolName: String {
        switch self {
        case .parakeet: EngineID.parakeet.symbolName
        case .gemini: "sparkles"
        case .hydrogen: EngineID.geminiHydrogen.symbolName
        case .carbon: EngineID.geminiCarbon.symbolName
        case .gigaam: EngineID.gigaam.symbolName
        }
    }

    /// Short names in a sentence, and whether it takes a plural verb: "Flash", "Parakeet and Flash".
    static func sentenceList(_ choices: [ModelChoice]) -> (names: String, isPlural: Bool) {
        let names = choices.map(\.shortName)
        guard let last = names.last else { return ("", false) }
        guard names.count > 1 else { return (last, false) }
        return (names.dropLast().joined(separator: ", ") + " and " + last, true)
    }

    /// A set of models as stored (General → Pasting's): raw values in declaration order, so the value is stable.
    static func stored(_ choices: Set<ModelChoice>) -> [String] {
        allCases.filter(choices.contains).map(\.rawValue)
    }

    /// A stored set, read leniently: a model this build doesn't know (the removed clean-up and Gemini 4 Argon too) is
    /// dropped. Gemini 3.8 Flash keeps its own checks, not Argon's.
    static func read(_ raw: [String]) -> Set<ModelChoice> {
        Set(raw.compactMap(ModelChoice.init(rawValue:)))
    }
}

/// The models as Models lists them: the user's order, the main model every dictation starts on, and which others
/// Switch model steps to. One JSON value under `SettingsKey.lineup`.
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

    /// What every install starts with: Parakeet, then Gemini 3.8 Flash in the cycle, and Gemini 4 Hydrogen, Gemini 4
    /// Carbon and GigaAM after them, switched off (Hydrogen costs about twice Flash's per token, Carbon about 2.7
    /// times; GigaAM is a download of its own).
    static let `default` = ModelLineup(order: [.parakeet, .gemini, .hydrogen, .carbon, .gigaam], main: .parakeet,
                                       switchable: [.gemini])

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
    /// appended and switched off (Gemini 4 Hydrogen, Gemini 4 Carbon and GigaAM, in a lineup stored before they came,
    /// in that order: a lineup stored with Carbon and GigaAM gets Hydrogen last), and an unknown main model is
    /// Parakeet. The removed clean-up was Parakeet's text tidied, so Parakeet
    /// stands in for it: as the main model, and switched on where clean-up was; it leaves the order.
    /// The removed Gemini 4 Argon was a Gemini, so Gemini 3.8 Flash stands in for it the same way
    /// (`ModelChoice.init(stored:)`), keeping its own place in the order.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
        let switchable = (try? container.decodeIfPresent([String].self, forKey: .switchable)) ?? []
        let main = (try? container.decodeIfPresent(String.self, forKey: .main)) ?? nil
        var switchOn = Set(switchable.compactMap(ModelChoice.init(stored:)))
        if switchable.contains(ModelChoice.retiredCleanup) { switchOn.insert(.parakeet) }
        self.init(order: order.compactMap(ModelChoice.init(rawValue:)),
                  main: main.flatMap(ModelChoice.init(stored:)) ?? .parakeet,
                  switchable: switchOn)
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
    /// Its color until one is picked: Parakeet the plain pill and Gemini violet, as before colors could be, Carbon
    /// blue, as Argon was, GigaAM green, as Sber's own, and Hydrogen pink, as hydrogen glows.
    var defaultColor: ModelColor {
        switch self {
        case .parakeet: .graphite
        case .gemini: .violet
        case .hydrogen: .pink
        case .carbon: .blue
        case .gigaam: .green
        }
    }
}

/// Each model's color; two models may share one. One JSON object under `SettingsKey.modelColors`, keyed by
/// `ModelChoice` raw value: {"gemini":"violet","parakeet":"graphite"}. A removed model's color (clean-up's, Gemini 4
/// Argon's) is ignored.
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
    /// the wrong kind, leaves that model's default; an unknown model is ignored. The load stores what it read
    /// (`AppSettings.load`), so a newer build's color is that default from then on, as a newer lineup's model is gone.
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

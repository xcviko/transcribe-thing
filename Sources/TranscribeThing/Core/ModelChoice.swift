import Foundation

/// What a dictation goes to. Models lists them in the user's order (`ModelLineup`): one is the main model every
/// dictation starts on, and Switch model steps to the others switched on. Raw values are persisted (the lineup): never
/// rename them. Declaration order is the default order.
///
/// Clean-up ("cleanup", Parakeet's text tidied by GPT-6 Luna) was a model until it was removed: a stored value that
/// names it is read as Parakeet was, where it was the main or hands-free model, and dropped elsewhere
/// (`retiredCleanup`).
/// Gemini 4 Argon ("argon") was a model until it was removed too: a stored value that names it is read as Gemini 3.8
/// Flash where it was the main, hands-free or a Switch model step, and dropped elsewhere (`retiredArgon`).
/// Parakeet ran through OpenRouter too until that was removed (`EngineID.parakeetCloud`), then on this Mac alone.
/// Gemini 4 Carbon ("carbon") came after Argon was removed: a choice of its own, never what "argon" reads as.
/// GigaAM ("gigaam") came after Carbon: a second model on this Mac, in three versions, last in the default order.
/// Gemini 4 Hydrogen ("hydrogen") came after GigaAM: Google's newer Flash-class model, between Flash and Carbon in the
/// default order. A lineup stored before it gets it at the end (`ModelLineup.init(order:main:switchable:)`).
/// Gemini 4 Neon ("neon") came after Hydrogen: the middle of the Gemini 4 family, between Hydrogen and Carbon in the
/// default order, and at the end of a lineup stored before it.
/// Parakeet ("parakeet") was a model until it was removed after Neon came: a stored value that names it is read as
/// GigaAM, the model on this Mac that stays, wherever it was picked (`retiredParakeet`). GigaAM, first in the default
/// order since, is GigaAM v3 alone.
enum ModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    /// GigaAM v3 on this Mac (`EngineID.gigaam`): Sber's model, Russian only, plain text without punctuation.
    case gigaam
    /// Gemini 3.8 Flash (`EngineID.geminiFlash`), which hears the audio itself. Named when it was the only Gemini.
    case gemini
    /// Gemini 4 Hydrogen (`EngineID.geminiHydrogen`): newer than Flash, faster on long dictations, and about twice its
    /// price per token.
    case hydrogen
    /// Gemini 4 Neon (`EngineID.geminiNeon`): the middle of the Gemini 4 family, between Hydrogen and Carbon, and about
    /// 3.6 times Flash's price per token.
    case neon
    /// Gemini 4 Carbon (`EngineID.geminiCarbon`): newer than Flash, slower, and about 2.7 times its cost.
    case carbon

    var id: String { rawValue }

    /// The raw value of the removed clean-up model, as older builds stored it.
    static let retiredCleanup = "cleanup"
    /// The raw value of the removed Gemini 4 Argon, as older builds stored it: read as Gemini 3.8 Flash where it was
    /// picked (`init(stored:)`).
    static let retiredArgon = "argon"
    /// The raw value of the removed Parakeet v3, as older builds stored it: read as GigaAM where it was picked
    /// (`init(stored:)`).
    static let retiredParakeet = "parakeet"

    /// A choice older builds stored, read leniently: the removed Gemini 4 Argon is Gemini 3.8 Flash, the Gemini that
    /// stays, and the removed Parakeet is GigaAM, the model on this Mac that stays; nil for anything else this build
    /// doesn't know (the removed clean-up too).
    init?(stored raw: String) {
        switch raw {
        case Self.retiredArgon: self = .gemini
        case Self.retiredParakeet: self = .gigaam
        default: self.init(rawValue: raw)
        }
    }

    /// The choice a job or a kept recording was made with (Undo, Continue, the processing pill): Gemini 4 Hydrogen is
    /// Hydrogen, Gemini 4 Neon is Neon, Gemini 4 Carbon is Carbon, any other Gemini (Flash, and the retired Argon and
    /// 3.1 Pro) is Gemini, and GigaAM is GigaAM, as is the retired Parakeet (on this Mac or through OpenRouter), which
    /// it took the place of. History draws Parakeet's own transcripts in Parakeet's color (`ModelColors.color(of:)`).
    init(engine: EngineID) {
        switch engine {
        case .gigaam, .parakeet, .parakeetCloud: self = .gigaam
        case .geminiHydrogen: self = .hydrogen
        case .geminiNeon: self = .neon
        case .geminiCarbon: self = .carbon
        case .geminiFlash, .geminiArgon, .geminiPro: self = .gemini
        }
    }

    /// The engine that hears the audio.
    var engine: EngineID {
        switch self {
        case .gigaam: .gigaam
        case .gemini: .geminiFlash
        case .hydrogen: .geminiHydrogen
        case .neon: .geminiNeon
        case .carbon: .geminiCarbon
        }
    }

    /// A Gemini model: it goes through the OpenRouter key (or the user's endpoint), and Polish and Translate work on
    /// it while dictating.
    var isGemini: Bool { engine.isGemini }

    /// It runs on this Mac (GigaAM): its engine has to be downloaded and loaded.
    var isLocal: Bool { engine.isLocal }
}

extension EngineID {
    /// The engine that runs in its place: itself while it's offered, the model that took a retired one's place
    /// otherwise: GigaAM v3 for either Parakeet, Gemini 3.8 Flash for Gemini 4 Argon and Gemini 3.1 Pro. What a
    /// History row's Continue, and the Retry With menu it names, run a retired model's dictation on.
    var replacement: EngineID { ModelChoice(engine: self).engine }
}

extension ModelChoice {
    /// The model's own name: "GigaAM v3", "Gemini 3.8 Flash", "Gemini 4 Hydrogen", "Gemini 4 Neon", "Gemini 4
    /// Carbon". Models' rows, menus, the pill's menu and accessibility, onboarding's Done step.
    var modelName: String { engine.modelName }

    /// The full name. The same as `modelName`.
    var title: String { modelName }

    /// One word for chains, sentences and narrow columns: "GigaAM → Flash → Carbon", "Flash and Carbon need…".
    var shortName: String {
        switch self {
        case .gemini: "Flash"
        case .hydrogen: "Hydrogen"
        case .neon: "Neon"
        case .carbon: "Carbon"
        case .gigaam: "GigaAM"
        }
    }

    /// The sidebar chip's name: "GigaAM v3", "Gemini 3.8 Flash", "Gemini 4 Hydrogen", "Gemini 4 Neon", "Gemini 4
    /// Carbon".
    var compactName: String { engine.shortName }

    /// The pill chip's name after its symbol: the model's own, "GigaAM v3", "Gemini 3.8 Flash".
    var chipName: String { engine.modelName }

    /// GigaAM's speech bubble, Flash's sparkles, Hydrogen's drop, Neon's lamp, Carbon's atom.
    var symbolName: String {
        switch self {
        case .gemini: "sparkles"
        case .hydrogen: EngineID.geminiHydrogen.symbolName
        case .neon: EngineID.geminiNeon.symbolName
        case .carbon: EngineID.geminiCarbon.symbolName
        case .gigaam: EngineID.gigaam.symbolName
        }
    }

    /// Short names in a sentence, and whether it takes a plural verb: "Flash", "GigaAM and Flash".
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

    /// A stored set, read leniently: a model this build doesn't know (the removed clean-up, Gemini 4 Argon and Parakeet
    /// too) is dropped. Gemini 3.8 Flash keeps its own checks, not Argon's, and GigaAM its own, not Parakeet's.
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

    /// What every install starts with: GigaAM v3 on this Mac, then Gemini 3.8 Flash in the cycle, and Gemini 4
    /// Hydrogen, Neon and Carbon after them, switched off (per token Hydrogen costs about twice Flash's, Neon about 3.6
    /// times, Carbon about 2.7 times). The shape Parakeet's was, GigaAM in its place.
    static let `default` = ModelLineup(order: [.gigaam, .gemini, .hydrogen, .neon, .carbon], main: .gigaam,
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
    /// appended and switched off (Gemini 4 Hydrogen, Neon, Carbon and GigaAM, in a lineup stored before they came,
    /// in `allCases` order: a lineup stored with Carbon and GigaAM gets Hydrogen and Neon last, one with Hydrogen too
    /// gets Neon last), and an unknown main model is GigaAM.
    /// The removed Parakeet was the other model on this Mac, so GigaAM stands in for it (`ModelChoice.init(stored:)`):
    /// as the main model, switched on where Parakeet was, and in Parakeet's place in the order unless GigaAM came
    /// first, so Switch model steps on from it as it did from Parakeet.
    /// The removed clean-up was Parakeet's text tidied, so it reads as Parakeet does: GigaAM, as the main model and
    /// switched on where clean-up was; it leaves the order.
    /// The removed Gemini 4 Argon was a Gemini, so Gemini 3.8 Flash stands in for it the same way, keeping its own
    /// place in the order.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
        let switchable = (try? container.decodeIfPresent([String].self, forKey: .switchable)) ?? []
        let main = (try? container.decodeIfPresent(String.self, forKey: .main)) ?? nil
        var switchOn = Set(switchable.compactMap(ModelChoice.init(stored:)))
        if switchable.contains(ModelChoice.retiredCleanup) { switchOn.insert(.gigaam) }
        self.init(order: order.compactMap { $0 == ModelChoice.retiredParakeet ? .gigaam : ModelChoice(rawValue: $0) },
                  main: main.flatMap(ModelChoice.init(stored:)) ?? .gigaam,
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
    /// Its color until one is picked: Gemini violet, as before colors could be, Carbon blue, as Argon was, GigaAM
    /// green, as Sber's own, Hydrogen pink, as hydrogen glows, and Neon orange, as neon does. (The retired Parakeet was
    /// the plain pill, graphite: `ModelColors.parakeet`.)
    var defaultColor: ModelColor {
        switch self {
        case .gemini: .violet
        case .hydrogen: .pink
        case .neon: .orange
        case .carbon: .blue
        case .gigaam: .green
        }
    }
}

/// Each model's color; two models may share one. One JSON object under `SettingsKey.modelColors`, keyed by
/// `ModelChoice` raw value: {"gemini":"violet","gigaam":"green"}. A removed model's color (clean-up's, Gemini 4
/// Argon's) is ignored, but for the retired Parakeet's, under "parakeet": History still draws Parakeet's transcripts
/// in it (`color(of:)`), and it's stored back as it was read.
struct ModelColors: Equatable, Sendable {
    private var colors: [ModelChoice: ModelColor]
    /// The retired Parakeet's color, as it was last picked: graphite, the plain pill, until one was. Nothing picks it
    /// any more.
    private(set) var parakeet: ModelColor = .graphite

    /// Every model in its `defaultColor`.
    static let `default` = ModelColors()

    init() {
        colors = Dictionary(uniqueKeysWithValues: ModelChoice.allCases.map { ($0, $0.defaultColor) })
    }

    subscript(_ choice: ModelChoice) -> ModelColor {
        get { colors[choice] ?? choice.defaultColor }
        set { colors[choice] = newValue }
    }

    /// The color History draws what `engine` wrote in: Parakeet's own for either Parakeet, as before it was retired;
    /// else its model's (`ModelChoice.init(engine:)`: Flash's for the retired Geminis).
    func color(of engine: EngineID) -> ModelColor {
        switch engine {
        case .parakeet, .parakeetCloud: parakeet
        default: self[ModelChoice(engine: engine)]
        }
    }
}

extension ModelColors: Codable {
    private struct ChoiceKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ choice: ModelChoice) { self.init(raw: choice.rawValue) }
        init(raw: String) { stringValue = raw }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Lenient, as a stored value outlives builds: a color this build doesn't offer (a newer build's), or a value of
    /// the wrong kind, leaves that model's default; an unknown model is ignored, the retired Parakeet aside. The load
    /// stores what it read (`AppSettings.load`), so a newer build's color is that default from then on, as a newer
    /// lineup's model is gone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ChoiceKey.self)
        self.init()
        func color(_ key: ChoiceKey) -> ModelColor? {
            ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap(ModelColor.init(rawValue:))
        }
        for choice in ModelChoice.allCases {
            if let color = color(ChoiceKey(choice)) { self[choice] = color }
        }
        if let color = color(ChoiceKey(raw: ModelChoice.retiredParakeet)) { parakeet = color }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ChoiceKey.self)
        for choice in ModelChoice.allCases {
            try container.encode(self[choice].rawValue, forKey: ChoiceKey(choice))
        }
        try container.encode(parakeet.rawValue, forKey: ChoiceKey(raw: ModelChoice.retiredParakeet))
    }
}

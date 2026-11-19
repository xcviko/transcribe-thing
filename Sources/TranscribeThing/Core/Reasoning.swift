import Foundation

/// How long a model thinks before it answers: OpenRouter's `reasoning.effort`. Gemini gets it as `thinkingLevel`
/// one to one (minimal → minimal … high → high). Raw values go on the wire and are persisted (a history version
/// records the level it was asked for). Each Gemini model thinks at the level picked for it in Models
/// (`ReasoningEfforts`, one of `EngineID.reasoningEfforts`); `off`
/// ("none") is for a model that can skip thinking (GPT-6 Luna, whose clean-ups History still keeps). Declaration order
/// is from least to most thinking.
enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    /// Sent as "none". Not named `none`, which would read as `Optional.none` wherever a level is optional.
    case off = "none"
    case minimal, low, medium, high

    var title: String {
        switch self {
        case .off: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

extension EngineID {
    /// The levels the model can be asked to think at (the Reasoning menu on its row in Models): Low, Medium and High
    /// for Gemini. No Gemini model is offered Minimal (the user's endpoint sends it as Low, Gemini 4 Hydrogen refuses
    /// it: "Thinking level is unsupported", and whether Gemini 4 Neon takes it isn't known) nor None (Gemini 3.8 Flash
    /// can't turn thinking off). Empty for models that don't reason, and for a retired one, which never runs.
    var reasoningEfforts: [ReasoningEffort] {
        switch self {
        case .geminiFlash, .geminiHydrogen, .geminiNeon, .geminiCarbon: [.low, .medium, .high]
        case .parakeet, .gigaam, .parakeetCloud, .geminiArgon, .geminiPro: []
        }
    }

    /// The level the model thinks at until another is picked, each model its own: medium for Gemini 3.8 Flash (at high
    /// it thought for about 18k tokens, 76 s, on a 1:48 recording), low for Gemini 4 Carbon, which is slower and
    /// dearer to begin with, and medium for Gemini 4 Hydrogen: at low it answered about twice as fast but left about
    /// 2.8 times as many filler words and repeats, which the prompt has it clean while it thinks (measured on the
    /// user's dictations). Low for Gemini 4 Neon: the dearest of the four per token, and not yet tried on dictations.
    /// nil for models that don't reason.
    var defaultReasoningEffort: ReasoningEffort? {
        switch self {
        case .geminiFlash, .geminiHydrogen: .medium
        case .geminiNeon, .geminiCarbon: .low
        case .parakeet, .gigaam, .parakeetCloud, .geminiArgon, .geminiPro: nil
        }
    }
}

/// The level each Gemini model thinks at, picked in Models (`AppSettings.reasoningEfforts`). Every request to the
/// model goes at its level: dictation, Polish, Translate, file imports, History's versions. One JSON object
/// under `SettingsKey.geminiReasoningEfforts`, keyed by `EngineID` raw value:
/// {"geminiCarbon":"low","geminiFlash":"medium","geminiHydrogen":"medium","geminiNeon":"low"}.
struct ReasoningEfforts: Equatable, Sendable {
    private var levels: [EngineID: ReasoningEffort] = [:]

    /// Every model at its `defaultReasoningEffort`.
    static let `default` = ReasoningEfforts()

    /// `engine`'s level: the one picked, else its default. nil for a model that doesn't reason. Setting a level the
    /// model doesn't offer (`EngineID.reasoningEfforts`) does nothing.
    subscript(_ engine: EngineID) -> ReasoningEffort? {
        get { levels[engine] ?? engine.defaultReasoningEffort }
        set {
            guard let newValue, engine.reasoningEfforts.contains(newValue) else { return }
            levels[engine] = newValue
        }
    }

    /// The same levels for every model this build runs, picked or default alike: a stored value that spells out a
    /// default (the load stores every model's level) equals one that leaves it out.
    static func == (lhs: Self, rhs: Self) -> Bool {
        EngineID.offered.allSatisfy { lhs[$0] == rhs[$0] }
    }
}

extension ReasoningEfforts: Codable {
    /// Lenient, as a stored value outlives builds: a level the model doesn't offer (Minimal, a newer build's) or a
    /// value of the wrong kind leaves that model's default; an unknown or retired model is ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([String: String].self)) ?? [:]
        self.init()
        for engine in EngineID.offered {
            self[engine] = raw[engine.rawValue].flatMap(ReasoningEffort.init(rawValue:))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var raw: [String: String] = [:]
        for engine in EngineID.offered {
            if let level = self[engine] { raw[engine.rawValue] = level.rawValue }
        }
        try container.encode(raw)
    }
}

/// The models that cleaned up Parakeet transcripts, text to text, while clean-up was one of the models: Gemini 3.5
/// Flash Lite, then GPT-6 Luna (with Gemini 3 Flash for a day). Clean-up is gone and nothing makes new clean-ups; the
/// models stay so History reads, names and shows the clean-ups already in it (`TranscriptVersionKind.cleanup`). Raw
/// values are persisted (history version kinds): never rename them.
enum CleanupModel: String, CaseIterable, Codable, Sendable {
    case geminiFlashLite
    case gpt6Luna
    case gemini3Flash

    /// "Gemini 3.5 Flash Lite", "GPT-6 Luna".
    var modelName: String {
        switch self {
        case .geminiFlashLite: "Gemini 3.5 Flash Lite"
        case .gpt6Luna: "GPT-6 Luna"
        case .gemini3Flash: "Gemini 3 Flash"
        }
    }

    /// For sentences: "Parakeet v3 + Clean-up by Flash Lite".
    var shortName: String {
        switch self {
        case .geminiFlashLite: "Flash Lite"
        case .gpt6Luna: "GPT-6 Luna"
        case .gemini3Flash: "Gemini 3 Flash"
        }
    }
}

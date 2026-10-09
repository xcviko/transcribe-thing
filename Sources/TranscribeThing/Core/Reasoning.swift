import Foundation

/// How long a model thinks before it answers: OpenRouter's `reasoning.effort`. Gemini gets it as `thinkingLevel`
/// one to one (minimal → minimal … high → high). Raw values go on the wire and are persisted (a history version
/// records the level it was asked for). Each model thinks at one fixed level (`EngineID.reasoningEffort`); `off`
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
    /// The level the model thinks at, fixed: Gemini 3.8 Flash at medium (it can't turn thinking off; at high it
    /// thought for about 18k tokens, 76 s, on a 1:48 recording). nil for models that don't reason, and for a retired
    /// one, which never runs.
    var reasoningEffort: ReasoningEffort? {
        switch self {
        case .geminiFlash: .medium
        case .parakeet, .parakeetCloud, .geminiPro: nil
        }
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

import Foundation

/// What a dictation goes to: an engine, or the main model with its transcript tidied by the clean-up model.
/// The Switch model shortcut steps through them for one dictation at a time: the main model, then clean-up, then
/// each extra model (`AppSettings.switchChoices`), then the main model again.
enum ModelChoice: Hashable, Sendable, Identifiable {
    /// The main model transcribes, then `CleanupModel.default` tidies the text before it's pasted. A pass over the
    /// main model's words, not a model that hears the audio.
    case cleanup
    case engine(EngineID)

    var id: String {
        switch self {
        case .cleanup: "cleanup"
        case .engine(let engine): engine.rawValue
        }
    }

    /// The extra model that transcribes in the main model's place; nil for clean-up, which the main model transcribes.
    var switchEngine: EngineID? {
        if case .engine(let engine) = self, engine.isSwitchModel { engine } else { nil }
    }

    var cleansUp: Bool { self == .cleanup }
}

extension ModelChoice {
    /// The full model name, "Gemini 3.8 Flash" or "Parakeet v3", or clean-up as the pass it is:
    /// "Parakeet v3 + GPT-6 Luna".
    func title(main: EngineID) -> String {
        switch self {
        case .cleanup: "\(main.modelName) + \(CleanupModel.default.modelName)"
        case .engine(let engine): engine.modelName
        }
    }

    var symbolName: String {
        switch self {
        case .cleanup: "wand.and.stars"
        case .engine(let engine): engine.isSwitchModel ? "sparkles" : engine.symbolName
        }
    }
}

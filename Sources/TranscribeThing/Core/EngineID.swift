import Foundation

/// The transcription engines transcribe-thing knows. Raw values are persisted (settings, history), never rename
/// them. Declaration order is display order: the local model, then cloud speech-to-text, then Gemini.
enum EngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `geminiPro` is retired (`isRetired`).
    case parakeet, parakeetCloud, geminiFlash, geminiPro

    var id: String { rawValue }

    static let `default`: EngineID = .parakeet

    /// A model this build no longer offers or runs: Gemini 3.1 Pro. Its case stays so History keeps reading, naming
    /// and drawing the transcripts it wrote.
    var isRetired: Bool { self == .geminiPro }

    /// Every engine this build offers and runs, in display order. Every list of models to pick, switch to, fall
    /// back to or transcribe with comes from here, never from `allCases`.
    static var offered: [EngineID] { allCases.filter { !$0.isRetired } }

    static var localEngines: [EngineID] { offered.filter(\.isLocal) }
    static var cloudEngines: [EngineID] { offered.filter { !$0.isLocal } }
    /// Parakeet served through OpenRouter's speech-to-text endpoint.
    static var cloudTranscriptionEngines: [EngineID] { offered.filter { $0.cloudAPI == .transcriptions } }
    /// Gemini through chat completions.
    static var cloudChatEngines: [EngineID] { offered.filter { $0.cloudAPI == .chatCompletions } }
    /// What Settings can select as the main model, the one every dictation starts with.
    static var mainCandidates: [EngineID] { offered.filter { !$0.isSwitchModel } }
    /// The extra models, in the order the Switch model shortcut steps through them: picked per dictation from the
    /// pill, never selected in Settings.
    static var switchCandidates: [EngineID] { offered.filter(\.isSwitchModel) }

    /// Which OpenRouter endpoint a cloud engine uses. Routing code switches on this, never on specific cases.
    enum CloudAPI: Sendable, Equatable {
        /// `POST /chat/completions` with the audio as an `input_audio` part (Gemini). One request per recording.
        case chatCompletions
        /// `POST /audio/transcriptions` (Parakeet). One request per recording, however long.
        case transcriptions
    }

    var isLocal: Bool {
        switch self {
        case .parakeet: true
        case .parakeetCloud, .geminiFlash, .geminiPro: false
        }
    }

    var isCloud: Bool { !isLocal }

    /// An extra model: used for one dictation at a time (Switch model), never as the main model.
    var isSwitchModel: Bool {
        switch self {
        case .parakeet, .parakeetCloud: false
        case .geminiFlash, .geminiPro: true
        }
    }

    /// nil for local engines.
    var cloudAPI: CloudAPI? {
        switch self {
        case .parakeet: nil
        case .parakeetCloud: .transcriptions
        case .geminiFlash, .geminiPro: .chatCompletions
        }
    }

    /// The same model running on the other side: Parakeet v3 on this Mac and through OpenRouter.
    var localCounterpart: EngineID? {
        switch self {
        case .parakeetCloud: .parakeet
        case .parakeet, .geminiFlash, .geminiPro: nil
        }
    }

    var cloudCounterpart: EngineID? {
        switch self {
        case .parakeet: .parakeetCloud
        case .parakeetCloud, .geminiFlash, .geminiPro: nil
        }
    }

    /// The model's own name, with no local/cloud qualifier. For layouts that already say where it runs (a
    /// "Cloud" section, a badge); everywhere else use `displayName` or `shortName`.
    var modelName: String {
        switch self {
        case .parakeet, .parakeetCloud: "Parakeet v3"
        case .geminiFlash: "Gemini 3.8 Flash"
        case .geminiPro: "Gemini 3.1 Pro"
        }
    }

    /// Unique per engine: the cloud variant of the local model carries "· Cloud".
    var displayName: String {
        switch self {
        case .parakeet, .geminiFlash, .geminiPro: modelName
        case .parakeetCloud: "Parakeet v3 · Cloud"
        }
    }

    /// The one short form, wherever `displayName` doesn't fit (sidebar chip, notices, notes). Unique per engine.
    var shortName: String {
        switch self {
        case .parakeet: "Parakeet v3"
        case .parakeetCloud: "Parakeet v3 · Cloud"
        case .geminiFlash: "Gemini Flash"
        case .geminiPro: "Gemini Pro"
        }
    }

    /// The pill's model chip: an extra model by its full name, the main model as just "Parakeet" (the chip only
    /// flashes it for a moment after switching back, and heads clean-up's "Parakeet → GPT-6 Luna").
    var chipName: String {
        isSwitchModel ? modelName : "Parakeet"
    }

    var providerLine: String {
        switch self {
        case .parakeet: "NVIDIA · on your Mac"
        case .parakeetCloud: "NVIDIA · via OpenRouter · Together"
        case .geminiFlash, .geminiPro: "Google · via OpenRouter"
        }
    }

    var factLine: String {
        switch self {
        case .parakeet: "Fastest · 25 European languages"
        case .parakeetCloud: "25 European languages · ≈ $0.09 per hour of audio"
        case .geminiFlash: "Fast and very accurate · pay per use"
        case .geminiPro: "Most accurate · slower · higher cost"
        }
    }

    /// The OpenRouter provider that serves this model: "Together", "Google AI Studio"; nil for the local model.
    /// Gemini requests pin it; transcription requests can't pin one, and Together is the only one serving
    /// Parakeet today. History records who actually answered.
    var provider: String? {
        switch self {
        case .parakeet: nil
        case .parakeetCloud: "Together"
        case .geminiFlash, .geminiPro: "Google AI Studio"
        }
    }

    /// Badges every local model carries; narrow layouts drop them first.
    static let privacyBadges: Set<String> = ["Private", "Offline"]

    var badges: [String] {
        switch self {
        case .parakeet: ["Recommended", "Private", "Offline"]
        case .parakeetCloud, .geminiFlash, .geminiPro: ["Cloud"]
        }
    }

    var symbolName: String {
        switch self {
        case .parakeet: "bolt.fill"
        case .parakeetCloud: "cloud.bolt.fill"
        case .geminiFlash: "sparkle"
        case .geminiPro: "sparkles"
        }
    }

    /// Short mark used on history rows. The cloud variant shares the local letter; `EngineGlyph` adds a cloud
    /// and the cloud tint to tell them apart.
    var glyph: String {
        switch self {
        case .parakeet, .parakeetCloud: "P"
        case .geminiFlash: "F"
        case .geminiPro: "Pro"
        }
    }

    var approxDownloadBytes: Int64? {
        switch self {
        case .parakeet: 632_321_326
        case .parakeetCloud, .geminiFlash, .geminiPro: nil
        }
    }

    var openRouterModelID: String? {
        switch self {
        case .parakeet: nil
        case .parakeetCloud: "nvidia/parakeet-tdt-0.6b-v3"
        case .geminiFlash: "google/gemini-3.8-flash"
        case .geminiPro: "google/gemini-3.1-pro-preview"
        }
    }

    /// Per request (`URLRequest.timeoutInterval`); `URLSession.openRouterCloud` caps the whole attempt at 330 s.
    /// A request carries the whole recording, and a non-streaming answer sends no bytes until it's ready.
    var cloudTimeout: TimeInterval {
        switch self {
        case .parakeet: 0
        case .parakeetCloud: 180
        case .geminiFlash: 120
        case .geminiPro: 180
        }
    }
}

import Foundation

/// The transcription engines transcribe-thing offers. Raw values are persisted (settings, history), never rename
/// them. Declaration order is display order: local models, then cloud speech-to-text, then Gemini.
enum EngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeet, whisper, parakeetCloud, whisperCloud, geminiFlash, geminiPro

    var id: String { rawValue }

    static let `default`: EngineID = .parakeet

    static var localEngines: [EngineID] { allCases.filter(\.isLocal) }
    static var cloudEngines: [EngineID] { allCases.filter { !$0.isLocal } }
    /// Parakeet and Whisper served through OpenRouter's speech-to-text endpoint.
    static var cloudTranscriptionEngines: [EngineID] { allCases.filter { $0.cloudAPI == .transcriptions } }
    /// Gemini through chat completions.
    static var cloudChatEngines: [EngineID] { allCases.filter { $0.cloudAPI == .chatCompletions } }

    /// Which OpenRouter endpoint a cloud engine uses. Routing code switches on this, never on specific cases.
    enum CloudAPI: Sendable, Equatable {
        /// `POST /chat/completions` with the audio as an `input_audio` part (Gemini). One request per recording.
        case chatCompletions
        /// `POST /audio/transcriptions` (Parakeet, Whisper). Long recordings go up in chunks.
        case transcriptions
    }

    var isLocal: Bool {
        switch self {
        case .parakeet, .whisper: true
        case .parakeetCloud, .whisperCloud, .geminiFlash, .geminiPro: false
        }
    }

    var isCloud: Bool { !isLocal }

    /// nil for local engines.
    var cloudAPI: CloudAPI? {
        switch self {
        case .parakeet, .whisper: nil
        case .parakeetCloud, .whisperCloud: .transcriptions
        case .geminiFlash, .geminiPro: .chatCompletions
        }
    }

    /// The same model running on the other side: Parakeet v3 on this Mac and through OpenRouter, likewise Whisper.
    var localCounterpart: EngineID? {
        switch self {
        case .parakeetCloud: .parakeet
        case .whisperCloud: .whisper
        case .parakeet, .whisper, .geminiFlash, .geminiPro: nil
        }
    }

    var cloudCounterpart: EngineID? {
        switch self {
        case .parakeet: .parakeetCloud
        case .whisper: .whisperCloud
        case .parakeetCloud, .whisperCloud, .geminiFlash, .geminiPro: nil
        }
    }

    /// The model's own name, with no local/cloud qualifier. For layouts that already say where it runs (a
    /// "Cloud" section, a badge); everywhere else use `displayName` or `shortName`.
    var modelName: String {
        switch self {
        case .parakeet, .parakeetCloud: "Parakeet v3"
        case .whisper, .whisperCloud: "Whisper Large V3 Turbo"
        case .geminiFlash: "Gemini 3.8 Flash"
        case .geminiPro: "Gemini 3.1 Pro"
        }
    }

    /// Unique per engine: the cloud variants of the local models carry "· Cloud".
    var displayName: String {
        switch self {
        case .parakeet, .whisper, .geminiFlash, .geminiPro: modelName
        case .parakeetCloud: "Parakeet v3 · Cloud"
        case .whisperCloud: "Whisper Large V3 Turbo · Cloud"
        }
    }

    /// The one short form, wherever `displayName` doesn't fit (sidebar chip, notices, notes). Unique per engine.
    var shortName: String {
        switch self {
        case .parakeet: "Parakeet v3"
        case .whisper: "Whisper Turbo"
        case .parakeetCloud: "Parakeet v3 · Cloud"
        case .whisperCloud: "Whisper Turbo · Cloud"
        case .geminiFlash: "Gemini Flash"
        case .geminiPro: "Gemini Pro"
        }
    }

    var providerLine: String {
        switch self {
        case .parakeet: "NVIDIA · on your Mac"
        case .whisper: "OpenAI · on your Mac"
        case .parakeetCloud: "NVIDIA · via OpenRouter · Together"
        case .whisperCloud: "OpenAI · via OpenRouter · Groq (preferred)"
        case .geminiFlash, .geminiPro: "Google · via OpenRouter"
        }
    }

    var factLine: String {
        switch self {
        case .parakeet: "Fastest · 25 European languages"
        case .whisper: "99 languages · great accuracy"
        case .parakeetCloud: "25 European languages · ≈ $0.09 per hour of audio"
        case .whisperCloud: "99 languages · ≈ $0.04 per hour of audio"
        case .geminiFlash: "Fast and very accurate · pay per use"
        case .geminiPro: "Most accurate · slower · higher cost"
        }
    }

    /// OpenRouter provider names that serve this model today, the preferred one first. Transcription requests
    /// can't pin a provider (OpenRouter ignores `order`/`only` there), so for Whisper this is a preference to
    /// show, not something the request enforces; history records who actually answered.
    var knownProviders: [String] {
        switch self {
        case .parakeet, .whisper: []
        case .parakeetCloud: ["Together"]
        case .whisperCloud: ["Groq", "DeepInfra"]
        case .geminiFlash, .geminiPro: ["Google AI Studio"]
        }
    }

    /// "Together", "Groq", "Google AI Studio"; nil for local engines.
    var preferredProvider: String? { knownProviders.first }

    /// Set when OpenRouter may pick a provider other than `preferredProvider` for a request.
    var providerRoutingNote: String? {
        guard cloudAPI == .transcriptions, knownProviders.count > 1 else { return nil }
        let names = knownProviders.joined(separator: " or ")
        return "OpenRouter picks \(names) for each request. History shows which one answered."
    }

    /// Badges every local model carries; narrow layouts drop them from all rows at once.
    static let privacyBadges: Set<String> = ["Private", "Offline"]

    var badges: [String] {
        switch self {
        case .parakeet: ["Recommended", "Private", "Offline"]
        case .whisper: ["Private", "Offline"]
        case .parakeetCloud, .whisperCloud, .geminiFlash, .geminiPro: ["Cloud"]
        }
    }

    var symbolName: String {
        switch self {
        case .parakeet: "bolt.fill"
        case .whisper: "globe"
        case .parakeetCloud: "cloud.bolt.fill"
        case .whisperCloud: "network"
        case .geminiFlash: "sparkle"
        case .geminiPro: "sparkles"
        }
    }

    /// Short mark used on history rows. The cloud variants share the local letter; `EngineGlyph` adds a cloud
    /// and the cloud tint to tell them apart.
    var glyph: String {
        switch self {
        case .parakeet, .parakeetCloud: "P"
        case .whisper, .whisperCloud: "W"
        case .geminiFlash: "F"
        case .geminiPro: "Pro"
        }
    }

    var approxDownloadBytes: Int64? {
        switch self {
        case .parakeet: 632_321_326
        case .whisper: 629_700_000
        case .parakeetCloud, .whisperCloud, .geminiFlash, .geminiPro: nil
        }
    }

    var openRouterModelID: String? {
        switch self {
        case .parakeet, .whisper: nil
        case .parakeetCloud: "nvidia/parakeet-tdt-0.6b-v3"
        case .whisperCloud: "openai/whisper-large-v3-turbo"
        case .geminiFlash: "google/gemini-3.8-flash"
        case .geminiPro: "google/gemini-3.1-pro-preview"
        }
    }

    /// Whisper takes a language hint (`AppSettings.whisperLanguage`); Parakeet and Gemini detect it themselves.
    var acceptsLanguageHint: Bool {
        switch self {
        case .whisper, .whisperCloud: true
        case .parakeet, .parakeetCloud, .geminiFlash, .geminiPro: false
        }
    }

    /// Per request. Transcription requests carry at most one chunk (`CloudChunker.maxChunkSeconds`), and
    /// OpenRouter's upstream providers give up after 60 s.
    var cloudTimeout: TimeInterval {
        switch self {
        case .parakeet, .whisper: 0
        case .parakeetCloud, .whisperCloud: 65
        case .geminiFlash: 120
        case .geminiPro: 180
        }
    }
}

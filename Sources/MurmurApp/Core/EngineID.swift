import Foundation

/// The four transcription engines Murmur offers. Raw values are persisted (settings, history), never rename them.
enum EngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeet, whisper, geminiFlash, geminiPro

    var id: String { rawValue }

    static let `default`: EngineID = .parakeet

    static var localEngines: [EngineID] { allCases.filter(\.isLocal) }
    static var cloudEngines: [EngineID] { allCases.filter { !$0.isLocal } }

    var isLocal: Bool {
        switch self {
        case .parakeet, .whisper: true
        case .geminiFlash, .geminiPro: false
        }
    }

    var isCloud: Bool { !isLocal }

    var displayName: String {
        switch self {
        case .parakeet: "Parakeet v3"
        case .whisper: "Whisper Large V3 Turbo"
        case .geminiFlash: "Gemini 3.8 Flash"
        case .geminiPro: "Gemini 3.1 Pro"
        }
    }

    /// The one short form, wherever `displayName` doesn't fit (sidebar chip, notices, notes).
    var shortName: String {
        switch self {
        case .parakeet: "Parakeet v3"
        case .whisper: "Whisper Turbo"
        case .geminiFlash: "Gemini Flash"
        case .geminiPro: "Gemini Pro"
        }
    }

    var providerLine: String {
        switch self {
        case .parakeet: "NVIDIA · on your Mac"
        case .whisper: "OpenAI · on your Mac"
        case .geminiFlash, .geminiPro: "Google · via OpenRouter"
        }
    }

    var factLine: String {
        switch self {
        case .parakeet: "Fastest · 25 European languages"
        case .whisper: "99 languages · great accuracy"
        case .geminiFlash: "Fast and very accurate · pay per use"
        case .geminiPro: "Most accurate · slower · higher cost"
        }
    }

    /// Badges every local model carries; narrow layouts drop them from all rows at once.
    static let privacyBadges: Set<String> = ["Private", "Offline"]

    var badges: [String] {
        switch self {
        case .parakeet: ["Recommended", "Private", "Offline"]
        case .whisper: ["Private", "Offline"]
        case .geminiFlash, .geminiPro: ["Cloud"]
        }
    }

    var symbolName: String {
        switch self {
        case .parakeet: "bolt.fill"
        case .whisper: "globe"
        case .geminiFlash: "sparkle"
        case .geminiPro: "sparkles"
        }
    }

    /// Short mark used on history rows.
    var glyph: String {
        switch self {
        case .parakeet: "P"
        case .whisper: "W"
        case .geminiFlash: "F"
        case .geminiPro: "Pro"
        }
    }

    var approxDownloadBytes: Int64? {
        switch self {
        case .parakeet: 632_321_326
        case .whisper: 629_700_000
        case .geminiFlash, .geminiPro: nil
        }
    }

    var openRouterModelID: String? {
        switch self {
        case .parakeet, .whisper: nil
        case .geminiFlash: "google/gemini-3.8-flash"
        case .geminiPro: "google/gemini-3.1-pro-preview"
        }
    }

    var cloudTimeout: TimeInterval {
        switch self {
        case .parakeet, .whisper: 0
        case .geminiFlash: 120
        case .geminiPro: 180
        }
    }
}

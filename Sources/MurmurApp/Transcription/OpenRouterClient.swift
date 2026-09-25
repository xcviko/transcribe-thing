import Foundation

// STUB (FOUNDATION): ENGINES replaces this with the real client.
extension URLSession {
    /// Shared session for OpenRouter calls: no cookies or disk cache, fail fast when offline.
    static let murmurCloud: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 330
        return URLSession(configuration: config)
    }()
}

struct CloudResult: Sendable {
    var text: String
    var provider: String?
    var costUSD: Double?
    var reasoningTokens: Int?
}

final class OpenRouterClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .murmurCloud) {
        self.session = session
    }

    /// Throws `MurmurError`.
    func transcribe(wav: Data, model: String, systemPrompt: String?, apiKey: String,
                    timeout: TimeInterval) async throws -> CloudResult {
        throw MurmurError.openRouterServer("Not available yet.")
    }

    /// Throws `MurmurError`.
    func keyInfo(apiKey: String) async throws -> KeyInfo {
        throw MurmurError.openRouterServer("Not available yet.")
    }
}

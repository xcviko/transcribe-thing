import Foundation

// STUB (FOUNDATION): ENGINES replaces this with engine routing.
struct TranscriptResult: Sendable, Equatable {
    var text: String
    var engine: EngineID
    var processingTime: TimeInterval
    var costUSD: Double?
}

@MainActor
final class TranscriptionService {
    private let models: ModelStore
    private let account: OpenRouterAccount
    private let client: OpenRouterClient
    private let settings: AppSettings

    init(models: ModelStore, account: OpenRouterAccount, client: OpenRouterClient, settings: AppSettings) {
        self.models = models
        self.account = account
        self.client = client
        self.settings = settings
    }

    /// Throws `MurmurError` only.
    func transcribe(_ recording: Recording, engine: EngineID) async throws -> TranscriptResult {
        throw MurmurError.engineFailed(engine, "Not available yet.")
    }
}

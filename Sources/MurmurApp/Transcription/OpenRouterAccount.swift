import Foundation
import Observation

// STUB (FOUNDATION): ENGINES replaces this with Keychain-backed validation.
struct KeyInfo: Equatable, Sendable, Codable {
    var label: String?
    var limit: Double?
    var limitRemaining: Double?
    var usage: Double
    var isFreeTier: Bool
    var expiresAt: Date?

    init(label: String? = nil, limit: Double? = nil, limitRemaining: Double? = nil,
         usage: Double = 0, isFreeTier: Bool = false, expiresAt: Date? = nil) {
        self.label = label
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.usage = usage
        self.isFreeTier = isFreeTier
        self.expiresAt = expiresAt
    }
}

enum KeyStatus: Equatable, Sendable {
    case missing, checking
    case valid(KeyInfo)
    case invalid(String)
    case noCredit(KeyInfo?)
    case offline
    case failed(String)
}

@MainActor @Observable
final class OpenRouterAccount {
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let client: OpenRouterClient

    private(set) var status: KeyStatus = .missing
    /// "sk-or-v1-••••3f9a"
    var maskedKey: String?

    init(keychain: KeychainStore, client: OpenRouterClient) {
        self.keychain = keychain
        self.client = client
    }

    static func preview(status: KeyStatus) -> OpenRouterAccount {
        let account = OpenRouterAccount(keychain: .inMemory(), client: OpenRouterClient())
        account.status = status
        if status != .missing { account.maskedKey = "sk-or-v1-••••3f9a" }
        return account
    }

    /// Trims, stores in the Keychain, validates.
    func setKey(_ raw: String) async {}

    func removeKey() {
        status = .missing
        maskedKey = nil
    }

    func validate() async {}

    func apiKey() -> String? { nil }
}

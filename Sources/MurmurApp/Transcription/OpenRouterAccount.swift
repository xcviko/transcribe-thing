import Foundation
import Observation

struct KeyInfo: Equatable, Sendable, Codable {
    var label: String?
    /// Spending cap of this key in USD; nil = no cap.
    var limit: Double?
    var limitRemaining: Double?
    /// USD spent with this key, all time.
    var usage: Double
    /// The account never bought credits.
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

/// The user's OpenRouter key: stored in the Keychain, validated against `GET /api/v1/key`.
@MainActor @Observable
final class OpenRouterAccount {
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let client: OpenRouterClient
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var cachedKey: String?
    @ObservationIgnored private var hasReadKeychain = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var recheckTask: Task<Void, Never>?

    private(set) var status: KeyStatus = .missing
    /// "sk-or-v1-••••3f9a"
    var maskedKey: String?
    /// Details from the last successful check (kept while offline or re-checking).
    private(set) var lastKeyInfo: KeyInfo?

    static let offlineRecheckDelay: Duration = .seconds(60)

    init(keychain: KeychainStore, client: OpenRouterClient) {
        self.keychain = keychain
        self.client = client
        self.debounce = .milliseconds(350)
    }

    init(keychain: KeychainStore, client: OpenRouterClient, debounce: Duration) {
        self.keychain = keychain
        self.client = client
        self.debounce = debounce
    }

    static func preview(status: KeyStatus) -> OpenRouterAccount {
        let account = OpenRouterAccount(keychain: .inMemory(), client: OpenRouterClient())
        account.status = status
        if status != .missing { account.maskedKey = "sk-or-v1-••••3f9a" }
        if case .valid(let info) = status { account.lastKeyInfo = info }
        return account
    }

    /// The stored key, read from the Keychain once and cached.
    func apiKey() -> String? {
        if !hasReadKeychain {
            hasReadKeychain = true
            cachedKey = keychain.read(KeychainStore.openRouterAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let cachedKey, cachedKey.isEmpty { self.cachedKey = nil }
            maskedKey = cachedKey.map(Self.mask)
        }
        return cachedKey
    }

    /// Trims, stores in the Keychain, validates. An empty string removes the key.
    func setKey(_ raw: String) async {
        let key = Self.sanitize(raw)
        guard !key.isEmpty else {
            removeKey()
            return
        }
        do {
            try keychain.write(key, account: KeychainStore.openRouterAccount)
        } catch {
            Log.app.error("Couldn't save the OpenRouter key: \(String(describing: error), privacy: .public)")
            generation += 1
            status = .failed("Couldn’t save the key to your Keychain.")
            return
        }
        hasReadKeychain = true
        cachedKey = key
        maskedKey = Self.mask(key)
        lastKeyInfo = nil
        await validate()
    }

    func removeKey() {
        generation += 1
        recheckTask?.cancel()
        keychain.delete(KeychainStore.openRouterAccount)
        hasReadKeychain = true
        cachedKey = nil
        maskedKey = nil
        lastKeyInfo = nil
        status = .missing
    }

    /// Checks the key. Calls in quick succession collapse into one request, and a result that arrives after a
    /// newer check started (or after the key changed) is dropped.
    func validate() async {
        generation += 1
        let current = generation
        recheckTask?.cancel()
        guard let key = apiKey() else {
            status = .missing
            return
        }
        status = .checking
        if debounce > .zero {
            do { try await Task.sleep(for: debounce) } catch { return }
            guard current == generation else { return }
        }
        let outcome: Result<KeyInfo, Error>
        do {
            outcome = .success(try await client.keyInfo(apiKey: key))
        } catch {
            outcome = .failure(error)
        }
        guard current == generation else { return }
        switch outcome {
        case .success(let info):
            lastKeyInfo = info
            status = Self.status(for: info)
        case .failure(let error):
            status = Self.status(for: error, lastInfo: lastKeyInfo)
            if status == .offline { scheduleRecheck() }
        }
    }

    /// Lets a failed transcription correct the displayed status (a key revoked or out of credit since the last check).
    func noteCloudFailure(_ error: MurmurError) {
        switch error {
        case .openRouterInvalidKey(let message):
            generation += 1
            status = .invalid(message)
        case .openRouterNoCredits:
            generation += 1
            status = .noCredit(lastKeyInfo)
        default:
            break
        }
    }

    // MARK: Pure helpers

    nonisolated static func status(for info: KeyInfo) -> KeyStatus {
        if let remaining = info.limitRemaining, remaining <= 0 { return .noCredit(info) }
        return .valid(info)
    }

    nonisolated static func status(for error: Error, lastInfo: KeyInfo?) -> KeyStatus {
        guard let error = error as? MurmurError else {
            return .failed(error.localizedDescription)
        }
        switch error {
        case .openRouterInvalidKey(let message): return .invalid(message.isEmpty ? "OpenRouter rejected this key." : message)
        case .openRouterMissingKey: return .missing
        case .openRouterNoCredits: return .noCredit(lastInfo)
        case .offline: return .offline
        case .timeout: return .failed("OpenRouter didn’t answer in time.")
        default: return .failed(error.detail ?? error.localizedDescription)
        }
    }

    /// Strips whitespace, newlines and a pasted "Bearer " prefix.
    nonisolated static func sanitize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return key.filter { !$0.isWhitespace }
    }

    /// "sk-or-v1-••••3f9a"
    nonisolated static func mask(_ key: String) -> String {
        let prefix = key.hasPrefix("sk-or-v1-") ? "sk-or-v1-" : (key.hasPrefix("sk-or-") ? "sk-or-" : "")
        let tail = key.count > prefix.count + 4 ? String(key.suffix(4)) : ""
        return "\(prefix)••••\(tail)"
    }

    private func scheduleRecheck() {
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: Self.offlineRecheckDelay)
            guard !Task.isCancelled, let self, self.status == .offline else { return }
            // validate() cancels any pending recheck; this task must not cancel itself.
            self.recheckTask = nil
            await self.validate()
        }
    }
}

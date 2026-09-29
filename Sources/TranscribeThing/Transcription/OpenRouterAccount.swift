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

extension KeyStatus {
    /// Out of credit because this key's own spending limit is used up (the account may still have credit).
    var isKeyLimitReached: Bool {
        guard case .noCredit(let info?) = self, info.limit != nil, let remaining = info.limitRemaining else { return false }
        return remaining <= 0
    }
}

/// The user's OpenRouter key: stored in the Keychain, validated against `GET /api/v1/key`.
@MainActor @Observable
final class OpenRouterAccount {
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let client: OpenRouterClient
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var cachedKey: String?
    @ObservationIgnored private var hasReadKeychain = false
    /// The last Keychain read failed (a denied or cancelled access prompt). Only `validate()` reads again, so
    /// dictations don't raise the prompt over and over.
    @ObservationIgnored private var keychainReadFailed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var isPreview = false
    /// When the last key check finished. Statuses set by a failed transcription don't count as a check.
    @ObservationIgnored private(set) var lastCheckedAt: Date?
    /// When `refreshIfStale` last started a check (it runs quietly, so the status doesn't show it).
    @ObservationIgnored private var lastRefreshAt: Date?

    private(set) var status: KeyStatus = .missing
    /// "sk-or-v1-••••3f9a"
    var maskedKey: String?
    /// Details from the last successful check (kept while offline or re-checking).
    private(set) var lastKeyInfo: KeyInfo?

    static let offlineRecheckDelay: Duration = .seconds(60)
    static let keychainReadFailedMessage = "\(Brand.name) couldn’t read your key from the Keychain."

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

    /// A fixed `status` that never checks itself. `keychain` holds the key requests read (none by default).
    static func preview(status: KeyStatus, keychain: KeychainStore = .inMemory()) -> OpenRouterAccount {
        let account = OpenRouterAccount(keychain: keychain, client: OpenRouterClient())
        account.isPreview = true
        account.status = status
        if status != .missing { account.maskedKey = "sk-or-v1-••••3f9a" }
        if case .valid(let info) = status { account.lastKeyInfo = info }
        return account
    }

    /// The stored key, read from the Keychain once and cached.
    func apiKey() -> String? {
        if !hasReadKeychain, !keychainReadFailed { readKeychain() }
        return cachedKey
    }

    /// A key may be stored, but the Keychain wouldn't hand it over. "Check again" (`validate()`) asks again.
    var isKeyUnreadable: Bool { keychainReadFailed }

    private func readKeychain() {
        do {
            let value = try keychain.lookup(KeychainStore.openRouterAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            hasReadKeychain = true
            keychainReadFailed = false
            cachedKey = value?.isEmpty == false ? value : nil
            maskedKey = cachedKey.map(Self.mask)
        } catch {
            // Not "no key": leave the cache unread so an explicit check can try again.
            keychainReadFailed = true
        }
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
        keychainReadFailed = false
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
        keychainReadFailed = false
        cachedKey = nil
        maskedKey = nil
        lastKeyInfo = nil
        status = .missing
    }

    /// Checks the key. Calls in quick succession collapse into one request, and a result that arrives after a
    /// newer check started (or after the key changed) is dropped. `quietly` keeps the current status on screen
    /// until the answer arrives (background refreshes), instead of showing "Checking key…".
    func validate(quietly: Bool = false) async {
        generation += 1
        let current = generation
        recheckTask?.cancel()
        if !hasReadKeychain {
            // An explicit check asks the Keychain again after a failed read.
            keychainReadFailed = false
            readKeychain()
        }
        if keychainReadFailed {
            status = .failed(Self.keychainReadFailedMessage)
            return
        }
        guard let key = cachedKey else {
            status = .missing
            return
        }
        if !quietly { status = .checking }
        // The check runs in a task of its own: a caller that gets cancelled (a UI debounce restarted by the
        // next keystroke, a closing window) must not leave the status stuck on .checking.
        await Task { await self.check(key, generation: current) }.value
    }

    private func check(_ key: String, generation current: Int) async {
        if debounce > .zero {
            try? await Task.sleep(for: debounce)
            guard current == generation else { return }
        }
        let outcome: Result<KeyInfo, Error>
        do {
            outcome = .success(try await client.keyInfo(apiKey: key))
        } catch {
            outcome = .failure(error)
        }
        guard current == generation else { return }
        lastCheckedAt = Date()
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
    func noteCloudFailure(_ error: AppError) {
        switch error {
        case .openRouterInvalidKey(let message):
            generation += 1
            status = .invalid(message)
        case .openRouterNoCredits:
            generation += 1
            status = .noCredit(lastKeyInfo)
        case .openRouterKeyLimit:
            // The key's own limit: fetch its limit and usage so the status says what ran out.
            Task { await self.validate(quietly: true) }
        default:
            break
        }
    }

    /// A transcription went through: a key an earlier request marked rejected or out of credit works again
    /// (re-enabled, topped up, a monthly limit reset), so check it and let the status catch up.
    func noteCloudSuccess() {
        switch status {
        case .invalid, .noCredit: Task { await self.validate(quietly: true) }
        default: break
        }
    }

    /// Checks the key again when the last check is older than `maxAge` (a page showing the status appeared, a
    /// dictation was refused on a key a request rejected). Never during a check, without a key, or after the
    /// Keychain refused: only "Check again" asks the Keychain again.
    func refreshIfStale(maxAge: TimeInterval, now: Date = Date()) {
        guard !isPreview, !keychainReadFailed else { return }
        switch status {
        case .checking, .missing: return
        case .valid, .invalid, .noCredit, .offline, .failed: break
        }
        let last = [lastCheckedAt, lastRefreshAt].compactMap { $0 }.max()
        if let last, now.timeIntervalSince(last) < maxAge { return }
        lastRefreshAt = now
        Task { await self.validate(quietly: true) }
    }

    // MARK: Pure helpers

    nonisolated static func status(for info: KeyInfo) -> KeyStatus {
        // `limit_remaining` is null for a key without a limit, so this is always the key's own limit.
        if let remaining = info.limitRemaining, remaining <= 0 { return .noCredit(info) }
        return .valid(info)
    }

    nonisolated static func status(for error: Error, lastInfo: KeyInfo?) -> KeyStatus {
        if error is CancellationError { return .failed("The check didn’t finish.") }
        guard let error = error as? AppError else {
            return .failed(error.localizedDescription)
        }
        switch error {
        case .openRouterInvalidKey(let message): return .invalid(message.isEmpty ? "OpenRouter rejected this key." : message)
        case .openRouterMissingKey: return .missing
        case .openRouterNoCredits, .openRouterKeyLimit: return .noCredit(lastInfo)
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

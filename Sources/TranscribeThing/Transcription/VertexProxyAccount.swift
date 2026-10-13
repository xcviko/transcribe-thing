import Foundation
import Observation

/// What the OpenAI-compatible endpoint's section of Models says about it.
enum VertexProxyStatus: Equatable, Sendable {
    /// No base URL or no key yet.
    case notSet
    case checking
    /// The endpoint took the key (`GET <base>/models`), or a request just went through.
    case works
    case keyRejected(String)
    /// A request found the endpoint's spend limit reached.
    case spendLimit(String)
    /// The URL doesn't answer.
    case unreachable
    case failed(String)
}

/// The user's own OpenAI-compatible endpoint (named for the Vertex proxy it started as): its base URL
/// (`AppSettings.vertexProxyURL`), its key (in its own key file, like the OpenRouter key: `KeyFileStore`), whether
/// it's the provider picked for cloud requests (`AppSettings.cloudProvider`), and whether it works. The key is never
/// logged or shown past its mask.
///
/// While it's the provider (`routesGemini`), every Gemini request goes to the endpoint, and none to OpenRouter, set up
/// or not: a failure there is the endpoint's (`VertexProxyFailure.notSetUp` without a URL or a key), never retried on
/// OpenRouter (that would spend OpenRouter credit). OpenRouter picked, nothing goes to the endpoint.
@MainActor @Observable
final class VertexProxyAccount {
    @ObservationIgnored private let keyStore: KeyFileStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let makeClient: @Sendable (URL) -> OpenRouterClient
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var cachedKey: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var clientCache: (base: URL, client: OpenRouterClient)?
    @ObservationIgnored private var isPreview = false
    /// When the last check finished. Statuses set by a request don't count as a check.
    @ObservationIgnored private(set) var lastCheckedAt: Date?
    @ObservationIgnored private var lastRefreshAt: Date?

    private(set) var status: VertexProxyStatus = .notSet
    /// "sk-••••3f9a"
    private(set) var maskedKey: String?
    /// A key file is there, but it couldn't be read: the endpoint still counts as set up, so Gemini fails as the
    /// endpoint's instead of quietly going to OpenRouter.
    private(set) var isKeyUnreadable = false

    nonisolated static let keyUnreadableMessage = "\(Brand.name) couldn’t read the key saved on this Mac. Paste it again."

    /// `makeClient` gets the API base (`baseURL`, the URL that ends in /v1).
    init(keyStore: KeyFileStore, settings: AppSettings,
         makeClient: @escaping @Sendable (URL) -> OpenRouterClient = { OpenRouterClient.vertexProxy(apiBase: $0) },
         debounce: Duration = .milliseconds(350)) {
        self.keyStore = keyStore
        self.settings = settings
        self.makeClient = makeClient
        self.debounce = debounce
        readKey()
        // A build from before the choice of provider: the endpoint where it was set up and on, once.
        settings.resolveCloudProvider(endpointConfigured: isConfigured)
        // Set up: usable until the first check (at launch) says otherwise.
        if isKeyUnreadable {
            status = .failed(Self.keyUnreadableMessage)
        } else if isConfigured {
            status = .checking
        }
    }

    /// A fixed `status` that never checks itself, with a base URL and a key when it isn't `.notSet`. `enabled`: the
    /// endpoint is the provider; by default when it's set up.
    static func preview(status: VertexProxyStatus, settings: AppSettings? = nil,
                        url: String = "https://llm.example.com/v1",
                        enabled: Bool? = nil) -> VertexProxyAccount {
        let settings = settings ?? .inMemory()
        let keyStore = KeyFileStore.inMemory(status == .notSet ? nil : "sk-preview00000000000000000003f9a")
        if status != .notSet { settings.vertexProxyURL = url }
        settings.cloudProvider = enabled ?? (status != .notSet) ? .vertexProxy : .openRouter
        let account = VertexProxyAccount(keyStore: keyStore, settings: settings)
        account.isPreview = true
        account.status = status
        return account
    }

    // MARK: Base URL

    /// The endpoint's API base (`VertexProxy.normalizedBaseURL` of what's saved: a saved host-only address means
    /// `<host>/api/v1`); nil when none is set.
    var baseURL: URL? {
        settings.vertexProxyURL.flatMap { try? VertexProxy.normalizedBaseURL($0).get() }
    }

    /// The base URL as requests use it, for the field: "https://api.example.com/v1".
    var urlText: String { baseURL?.absoluteString ?? "" }

    /// Saves the base URL (normalized), or removes it when `raw` is empty, then checks the endpoint. A bad URL
    /// isn't saved: its problem comes back for the field to show.
    @discardableResult
    func setURL(_ raw: String) async -> VertexProxy.URLProblem? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settings.vertexProxyURL = nil
            generation += 1
            status = .notSet
            return nil
        }
        switch VertexProxy.normalizedBaseURL(trimmed) {
        case .failure(let problem):
            return problem
        case .success(let url):
            let changed = url != baseURL
            settings.vertexProxyURL = url.absoluteString
            if changed || status != .works { await validate() }
            return nil
        }
    }

    // MARK: Key

    func apiKey() -> String? {
        if cachedKey == nil, !isKeyUnreadable { readKey() }
        return cachedKey
    }

    private func readKey() {
        do {
            cachedKey = try keyStore.lookup()
            isKeyUnreadable = false
            maskedKey = cachedKey.map(VertexProxy.mask)
        } catch {
            cachedKey = nil
            isKeyUnreadable = true
            maskedKey = nil
        }
    }

    /// Stores the key and checks it. Any key that isn't empty is saved; an empty one removes the key. Returns why a
    /// key wasn't saved, for the field to show (nil: it was, or it was removed).
    @discardableResult
    func setKey(_ raw: String) async -> String? {
        let key = OpenRouterAccount.sanitize(raw)
        guard !key.isEmpty else {
            removeKey()
            return nil
        }
        do {
            try keyStore.write(key)
        } catch {
            Log.app.error("Couldn't save the endpoint's key: \(String(describing: error), privacy: .public)")
            generation += 1
            status = .failed("Couldn’t save the key on this Mac.")
            return nil
        }
        cachedKey = key
        isKeyUnreadable = false
        maskedKey = VertexProxy.mask(key)
        await validate()
        return nil
    }

    func removeKey() {
        generation += 1
        keyStore.delete()
        cachedKey = nil
        isKeyUnreadable = false
        maskedKey = nil
        status = .notSet
    }

    // MARK: Routing

    /// The endpoint is the provider picked for cloud requests (Models → API keys → Provider).
    var isEnabled: Bool {
        get { settings.cloudProvider == .vertexProxy }
        set { settings.cloudProvider = newValue ? .vertexProxy : .openRouter }
    }

    /// A base URL and a key (one that can't be read counts: Gemini then fails as the endpoint's).
    var isConfigured: Bool { baseURL != nil && (maskedKey != nil || isKeyUnreadable) }

    /// Gemini's requests go to the endpoint, not OpenRouter: it's the provider, whether it's set up or not.
    var routesGemini: Bool { isEnabled }

    /// The client for the base URL set now; nil without one.
    func client() -> OpenRouterClient? {
        guard let base = baseURL else { return nil }
        if let cached = clientCache, cached.base == base { return cached.client }
        let client = makeClient(base)
        clientCache = (base, client)
        return client
    }

    /// The endpoint as a key status, for the readiness of the models it serves (`EngineReadiness`, notices): works is
    /// `.valid`, a spend limit `.noCredit` labeled as the endpoint's (`KeyStatus.isProxySpendLimit`), unreachable
    /// `.offline`.
    var keyStatus: KeyStatus {
        if isKeyUnreadable { return .failed(Self.keyUnreadableMessage) }
        switch status {
        case .notSet: return .missing
        case .checking: return .checking
        case .works: return .valid(KeyInfo(label: VertexProxy.label))
        case .keyRejected(let message): return .invalid(message)
        case .spendLimit: return .noCredit(KeyInfo(label: VertexProxy.label))
        case .unreachable: return .offline
        case .failed(let message): return .failed(message)
        }
    }

    // MARK: Checking

    /// Checks the base URL and key with `GET <base>/models`, which costs nothing. Calls in quick succession collapse
    /// into one request, and an answer that arrives after a newer check started is dropped. `quietly` keeps the
    /// current status on screen until the answer comes.
    func validate(quietly: Bool = false) async {
        generation += 1
        let current = generation
        if cachedKey == nil { readKey() }
        if isKeyUnreadable {
            status = .failed(Self.keyUnreadableMessage)
            return
        }
        guard let key = cachedKey, let client = client() else {
            status = .notSet
            return
        }
        if !quietly { status = .checking }
        await Task { await self.check(key, client: client, generation: current) }.value
    }

    private func check(_ key: String, client: OpenRouterClient, generation current: Int) async {
        if debounce > .zero {
            try? await Task.sleep(for: debounce)
            guard current == generation else { return }
        }
        let outcome: Error?
        do {
            try await client.checkProxyKey(apiKey: key)
            outcome = nil
        } catch {
            outcome = error
        }
        guard current == generation else { return }
        lastCheckedAt = Date()
        status = outcome.map(Self.status(for:)) ?? .works
        DiagnosticLog.shared.event(.net, "endpoint.checked", ["status": Self.code(of: status)])
    }

    /// A failed request corrects the status: a key the endpoint no longer takes, a spend limit reached.
    func noteCloudFailure(_ error: AppError) {
        switch error {
        case .vertexProxy(.keyRejected(let message)):
            generation += 1
            status = .keyRejected(message)
        case .vertexProxy(.spendLimit(let message)):
            generation += 1
            status = .spendLimit(message)
        default:
            break
        }
    }

    /// A request went through: whatever an earlier one said, the endpoint works now.
    func noteCloudSuccess() {
        guard status != .works, !isKeyUnreadable, isConfigured else { return }
        generation += 1
        status = .works
    }

    /// Checks again when the last check is older than `maxAge` (Models appeared). Never without a base URL and a key.
    func refreshIfStale(maxAge: TimeInterval, now: Date = Date()) {
        guard !isPreview, !isKeyUnreadable, isConfigured, status != .checking else { return }
        let last = [lastCheckedAt, lastRefreshAt].compactMap { $0 }.max()
        if let last, now.timeIntervalSince(last) < maxAge { return }
        lastRefreshAt = now
        Task { await self.validate(quietly: status != .notSet) }
    }

    // MARK: Pure helpers

    nonisolated static func status(for error: Error) -> VertexProxyStatus {
        if error is CancellationError { return .failed("The check didn’t finish.") }
        guard let error = error as? AppError else { return .failed(error.localizedDescription) }
        switch error {
        case .vertexProxy(.keyRejected(let message)):
            return .keyRejected(message.isEmpty ? "Your endpoint didn’t accept this key." : message)
        case .vertexProxy(.spendLimit(let message)): return .spendLimit(message)
        case .vertexProxy(.unreachable), .offline: return .unreachable
        case .vertexProxy(.keyUnreadable): return .failed(keyUnreadableMessage)
        case .timeout: return .failed("Your endpoint didn’t answer in time.")
        case .vertexProxy(.badRequest(let message)) where message == VertexProxy.notAnAPIMessage:
            return .failed(message)
        case .vertexProxy(.badRequest):
            // A 404 or the like: the URL answers, but not as an OpenAI-compatible API does.
            return .failed("No OpenAI-compatible API answers at this URL. Check that it’s the one that ends in /v1.")
        default: return .failed(error.detail ?? error.localizedDescription)
        }
    }

    /// The status as the log names it: never a message, which could quote the URL.
    nonisolated static func code(of status: VertexProxyStatus) -> String {
        switch status {
        case .notSet: "notSet"
        case .checking: "checking"
        case .works: "works"
        case .keyRejected: "keyRejected"
        case .spendLimit: "spendLimit"
        case .unreachable: "unreachable"
        case .failed: "failed"
        }
    }
}

extension KeyStatus {
    /// The endpoint's spend limit, as `VertexProxyAccount.keyStatus` reports it.
    var isProxySpendLimit: Bool {
        guard case .noCredit(let info?) = self else { return false }
        return info.label == VertexProxy.label
    }
}

/// Where a cloud engine's requests go, and the key status that decides whether it can run: Gemini through the
/// endpoint while it routes Gemini (`VertexProxyAccount.routesGemini`), everything else through OpenRouter.
@MainActor
enum CloudRoute {
    /// nil for a local engine.
    static func provider(for engine: EngineID, proxy: VertexProxyAccount?) -> CloudProvider? {
        guard engine.isCloud else { return nil }
        return engine.isGemini && proxy?.routesGemini == true ? .vertexProxy : .openRouter
    }

    /// The status of the key `engine`'s requests go with (OpenRouter's for a local engine, which needs none).
    static func keyStatus(for engine: EngineID, account: OpenRouterAccount, proxy: VertexProxyAccount?) -> KeyStatus {
        if provider(for: engine, proxy: proxy) == .vertexProxy, let proxy { return proxy.keyStatus }
        return account.status
    }
}

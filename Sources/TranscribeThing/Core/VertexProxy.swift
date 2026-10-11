import Foundation

/// The service a cloud engine's requests go to: OpenRouter, or the user's own Vertex proxy for Gemini
/// (`VertexProxyAccount.routesGemini`). Cloud Parakeet always goes through OpenRouter.
enum CloudProvider: String, Sendable, Equatable, CaseIterable {
    case openRouter, vertexProxy

    /// "OpenRouter", "Vertex proxy": what copy calls the service.
    var name: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .vertexProxy: "Vertex proxy"
        }
    }
}

/// The user's own proxy in front of Vertex AI (paid from their Google Cloud credits), which speaks OpenRouter's chat
/// completions at `<base>/api/v1`. What it is told and how its address and keys look; pure, so tests drive it.
enum VertexProxy {
    /// Every key the proxy issues starts with this (its `KEY_PREFIX`).
    static let keyPrefix = "sk-vp-"
    /// Who served a request that went through the proxy, as History names it.
    static let providerName = "Vertex AI"
    /// What the proxy's answers are labeled with where a key status carries a label (`KeyInfo.label`).
    static let label = "Vertex proxy"
    /// The OpenRouter-style API under the base URL.
    static let apiPath = "api/v1"
    /// The most output tokens Vertex takes for Gemini (65,536); a request asking for more is refused there, so
    /// requests through the proxy never ask for more.
    static let maxOutputTokens = 65_536
    /// A check that reached something other than the proxy: a page that answers anything.
    static let notAProxyMessage = "Something answered at this address, but it isn’t a Vertex proxy."

    /// Why a base URL can't be used.
    enum URLProblem: Error, Equatable, Sendable {
        case empty
        /// Not https: the key goes in a header, never in the clear.
        case notHTTPS
        case invalid

        var message: String {
            switch self {
            case .empty: "Enter your proxy’s address."
            case .notHTTPS: "The address has to start with https://."
            case .invalid: "That doesn’t look like a web address."
            }
        }
    }

    /// The proxy's base URL from what the user typed or pasted: https only, with a host, without a query or fragment.
    /// Whitespace, trailing slashes, a trailing `/api/v1` and a trailing `/api/v1/chat/completions` (the endpoint
    /// pasted whole) come off, so every spelling of the same proxy gives the same base:
    /// `https://vertex-proxy-xyz.a.run.app`.
    static func normalizedBaseURL(_ raw: String) -> Result<URL, URLProblem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if !text.contains("://") {
            // A bare host ("vertex-proxy.a.run.app") is taken as https; "http:" isn't.
            if text.lowercased().hasPrefix("http:") { return .failure(.notHTTPS) }
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        guard scheme == "https" else { return .failure(.notHTTPS) }
        guard let host = components.host, !host.isEmpty, !host.contains(" "),
              components.query == nil, components.fragment == nil, components.user == nil,
              components.password == nil else {
            return .failure(.invalid)
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/chat/completions", "/api/v1"] where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
            while path.hasSuffix("/") { path.removeLast() }
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = path
        guard let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }

    /// `<base>/api/v1`: where its chat completions and models are.
    static func apiBase(_ base: URL) -> URL {
        base.appendingPathComponent("api", isDirectory: false).appendingPathComponent("v1", isDirectory: false)
    }

    /// Why `key` isn't a proxy key, or nil when it looks like one.
    static func keyProblem(_ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if !key.hasPrefix(keyPrefix) { return "Vertex proxy keys start with “\(keyPrefix)”." }
        if key.count <= keyPrefix.count + 4 { return "That key looks too short." }
        return nil
    }

    /// Whether `key` can be saved: it starts with `keyPrefix` and has more after it.
    static func looksLikeKey(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && keyProblem(key) == nil
    }

    /// "sk-vp-••••3f9a": never more of the key than its prefix and last four characters.
    static func mask(_ key: String) -> String {
        let prefix = key.hasPrefix(keyPrefix) ? keyPrefix : ""
        let tail = key.count > prefix.count + 8 ? String(key.suffix(4)) : ""
        return "\(prefix)••••\(tail)"
    }

    /// "vertex-proxy-xyz.a.run.app": the address as the card and the CLI show it, without the scheme.
    static func displayHost(_ base: URL) -> String {
        let host = base.host ?? base.absoluteString
        let path = base.path == "/" ? "" : base.path
        return host + path
    }
}

/// How a request through the Vertex proxy failed, in the words its card and notices use. The proxy answers like
/// OpenRouter (an `error` object with a message), but its own limits and failures differ: a 401 is the proxy's key,
/// a 429 that says "spend limit" is the proxy's spend limit, and nothing can be fixed on openrouter.ai.
enum VertexProxyFailure: Equatable, Sendable {
    /// The key file is there but can't be read.
    case keyUnreadable
    /// 401: the proxy doesn't know this key (revoked, mistyped).
    case keyRejected(String)
    /// 429 "Proxy spend limit reached" or "Spend limit for key … reached": the proxy stopped taking requests.
    case spendLimit(String)
    /// The address doesn't answer: no network, a wrong host, a proxy that's down.
    case unreachable
    /// 429 without a spend limit: Vertex was out of capacity even after the proxy's own retries.
    case rateLimited(retryAfter: Double?)
    /// 403: Google Cloud refused the proxy (billing disabled when the trial ends, a missing role).
    case forbidden(String)
    /// 5xx, or an answer that couldn't be read: usually brief.
    case unavailable(String)
    /// 400, 404, 422: the request itself was refused.
    case badRequest(String)
    /// 413: the recording is larger than the proxy takes in one request.
    case tooLarge

    var code: String {
        switch self {
        case .keyUnreadable: "keyUnreadable"
        case .keyRejected: "keyRejected"
        case .spendLimit: "spendLimit"
        case .unreachable: "unreachable"
        case .rateLimited: "rateLimited"
        case .forbidden: "forbidden"
        case .unavailable: "unavailable"
        case .badRequest: "badRequest"
        case .tooLarge: "tooLarge"
        }
    }

    var detail: String? {
        switch self {
        case .keyRejected(let s), .spendLimit(let s), .forbidden(let s), .unavailable(let s), .badRequest(let s):
            s.isEmpty ? nil : s
        case .keyUnreadable, .unreachable, .rateLimited, .tooLarge:
            nil
        }
    }

    /// The same request sent again a moment later can succeed.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .unavailable: true
        default: false
        }
    }
}

/// Maps the proxy's answers to `AppError`. Its error bodies are OpenAI's (`{"error": {"message", "type", "code"}}`,
/// `code` a Google status like "RESOURCE_EXHAUSTED"), and an error after a 200 comes as a chunk with an `error` whose
/// `code` is the HTTP status.
enum VertexProxyErrorMapper {
    /// How the proxy says a spend limit stopped it (lowercased): the proxy-wide `SPEND_LIMIT_USD` and a key's own.
    static let spendLimitPhrases = ["spend limit"]

    static func httpError(status: Int, data: Data, retryAfter: Double?, engine: EngineID) -> AppError {
        let message: String
        if let envelope = try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: data) {
            message = envelope.error.message ?? ""
        } else {
            message = OpenRouterErrorMapper.plainMessage(from: data)
        }
        return map(status: status, message: message, retryAfter: retryAfter, engine: engine)
    }

    /// An error object inside a 200 (or a body): its numeric `code` when it has one, else `status`.
    static func map(_ body: OpenRouterAPIError, status: Int, retryAfter: Double?, engine: EngineID) -> AppError {
        map(status: body.code?.intValue ?? status, message: body.message ?? "", retryAfter: retryAfter, engine: engine)
    }

    static func map(status: Int, message rawMessage: String, retryAfter: Double?, engine: EngineID) -> AppError {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if spendLimitPhrases.contains(where: lowered.contains) { return .vertexProxy(.spendLimit(message)) }
        if status == 400, OpenRouterErrorMapper.tooLargePhrases.contains(where: lowered.contains) {
            return .vertexProxy(.tooLarge)
        }
        switch status {
        case 401: return .vertexProxy(.keyRejected(message))
        case 403: return .vertexProxy(.forbidden(message))
        case 408, 504: return .timeout(engine)
        case 413: return .vertexProxy(.tooLarge)
        case 429: return .vertexProxy(.rateLimited(retryAfter: retryAfter))
        case 500...599: return .vertexProxy(.unavailable(message.isEmpty ? "HTTP \(status)" : message))
        case 400...499: return .vertexProxy(.badRequest(message.isEmpty ? "HTTP \(status)" : message))
        default: return .vertexProxy(.unavailable(message.isEmpty ? "Unexpected HTTP \(status)" : "HTTP \(status): \(message)"))
        }
    }

    /// An `AppError` the shared stream and response readers made, in the proxy's terms: anything that names
    /// OpenRouter or its settings becomes the proxy's own failure. What any service says the same way (a cut-off
    /// answer, a refusal by the model, a timeout, no speech) stays as it is.
    static func adapt(_ error: AppError) -> AppError {
        switch error {
        case .openRouterMissingKey, .openRouterKeyUnreadable: .vertexProxy(.keyUnreadable)
        case .openRouterInvalidKey(let message): .vertexProxy(.keyRejected(message))
        case .openRouterNoCredits(let message), .openRouterKeyLimit(let message): .vertexProxy(.spendLimit(message))
        case .openRouterRateLimited(let retryAfter): .vertexProxy(.rateLimited(retryAfter: retryAfter))
        case .openRouterNoRoute(let message), .openRouterBadRequest(let message): .vertexProxy(.badRequest(message))
        case .openRouterProviderUnavailable(let message), .openRouterServer(let message):
            .vertexProxy(.unavailable(message.replacingOccurrences(of: "OpenRouter", with: CloudProvider.vertexProxy.name)))
        case .offline, .connectionBlocked: .vertexProxy(.unreachable)
        case .recordingTooLarge: .vertexProxy(.tooLarge)
        default: error
        }
    }
}

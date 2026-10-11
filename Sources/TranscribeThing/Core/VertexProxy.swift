import Foundation

/// The service a cloud engine's requests go to: OpenRouter, or the user's own OpenAI-compatible endpoint for Gemini
/// (`VertexProxyAccount.routesGemini`). Cloud Parakeet always goes through OpenRouter. (`vertexProxy` and the
/// `VertexProxy…` names are what the endpoint was called when it could only be the user's Vertex proxy; the app calls
/// it "OpenAI-compatible endpoint", "Custom endpoint" for short, and "your endpoint" in sentences.)
enum CloudProvider: String, Sendable, Equatable, CaseIterable {
    case openRouter, vertexProxy

    /// "OpenRouter", "Custom endpoint": what a short label calls the service.
    var name: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .vertexProxy: "Custom endpoint"
        }
    }
}

/// The user's own OpenAI-compatible endpoint: any service that takes OpenAI's (and OpenRouter's) chat completions at
/// `<base URL>/chat/completions` and lists its models at `<base URL>/models`. What it is told and how its address
/// and keys look; pure, so tests drive it.
///
/// The base URL is the one that ends in `/v1` (`https://api.example.com/v1`, `https://example.com/api/v1`). One rule
/// covers a URL without a path: it means `<host>/api/v1`. That is how the app read the host-only address it saved
/// when the endpoint could only be the user's Vertex proxy (whose OpenRouter-style API is at `/api/v1`), so that
/// setup keeps working as it is, and a new entry without a path means the same.
enum VertexProxy {
    /// What a key status is labeled with when it is the endpoint's (`KeyInfo.label`).
    static let label = "Custom endpoint"
    /// The API path a base URL without one stands for.
    static let defaultAPIPath = "/api/v1"
    /// The most output tokens a request through the endpoint asks for (65,536, Gemini's most): some refuse a request
    /// that asks for more, so requests through the endpoint never do.
    static let maxOutputTokens = 65_536
    /// A check that reached something other than an OpenAI-compatible API: a page that answers anything.
    static let notAnAPIMessage = "Something answered at this URL, but not as an OpenAI-compatible API."

    /// Why a base URL can't be used.
    enum URLProblem: Error, Equatable, Sendable {
        case empty
        /// Not https: the key goes in a header, never in the clear.
        case notHTTPS
        case invalid

        var message: String {
            switch self {
            case .empty: "Enter your endpoint’s base URL."
            case .notHTTPS: "The URL has to start with https://."
            case .invalid: "That doesn’t look like a web address."
            }
        }
    }

    /// The endpoint's API base from what the user typed or pasted: https only, with a host, without a query, a
    /// fragment or credentials. Whitespace, trailing slashes and a trailing `/chat/completions` (the endpoint pasted
    /// whole) come off; a missing scheme is taken as https; the path is kept as given, and an empty one means
    /// `/api/v1` (`defaultAPIPath`). Requests go to `<result>/chat/completions`, the key check to `<result>/models`.
    static func normalizedBaseURL(_ raw: String) -> Result<URL, URLProblem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if !text.contains("://") {
            // A bare host ("api.example.com/v1") is taken as https; "http:" isn't.
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
        let endpoint = "/chat/completions"
        if path.lowercased().hasSuffix(endpoint) {
            path.removeLast(endpoint.count)
            while path.hasSuffix("/") { path.removeLast() }
        }
        if path.isEmpty { path = defaultAPIPath }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = path
        guard let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }

    /// Whether `key` can be saved: anything that isn't empty once whitespace (and a pasted "Bearer ") is off.
    static func looksLikeKey(_ key: String) -> Bool {
        !OpenRouterAccount.sanitize(key).isEmpty
    }

    /// "sk-proj-••••3f9a", "••••3f9a": never more of the key than a kind prefix it starts with (lowercase letters,
    /// digits and dashes, ending in a dash, within its first 8 characters: "sk-", "sk-proj-") and, for a key long
    /// enough, its last four.
    static func mask(_ key: String) -> String {
        let head = key.prefix(8)
        let prefix = head.lastIndex(of: "-").map { String(head[...$0]) }
            .flatMap { $0.allSatisfy { $0 == "-" || ($0.isASCII && ($0.isLowercase || $0.isNumber)) } ? $0 : nil } ?? ""
        let tail = key.count >= prefix.count + 12 ? String(key.suffix(4)) : ""
        return "\(prefix)••••\(tail)"
    }

    /// "api.example.com/v1": the base URL as the card and the CLI show it, without the scheme.
    static func displayHost(_ base: URL) -> String {
        let host = base.host ?? base.absoluteString
        let path = base.path == "/" ? "" : base.path
        return host + path
    }

    /// `message` (one the shared readers wrote about OpenRouter) about the endpoint instead.
    static func reword(_ message: String) -> String {
        var text = message
        if text.hasPrefix("OpenRouter") { text = "Your endpoint" + text.dropFirst("OpenRouter".count) }
        return text.replacingOccurrences(of: "OpenRouter", with: "your endpoint")
    }
}

/// How a request through the endpoint failed, in the words its card and notices use. The endpoint answers like
/// OpenAI or OpenRouter (an `error` object with a message), but its limits and failures are its own: a 401 is the
/// endpoint's key, a 402 or a 429 that says "spend limit" is its spend limit, and nothing can be fixed on
/// openrouter.ai.
enum VertexProxyFailure: Equatable, Sendable {
    /// The key file is there but can't be read.
    case keyUnreadable
    /// 401: the endpoint doesn't know this key (revoked, mistyped).
    case keyRejected(String)
    /// 402, or a 429 that names a spend limit or a used-up quota: the endpoint stopped taking requests.
    case spendLimit(String)
    /// The address doesn't answer: no network, a wrong host, an endpoint that's down.
    case unreachable
    /// 429 without a spend limit: the model was out of capacity even after the endpoint's own retries.
    case rateLimited(retryAfter: Double?)
    /// 403: the endpoint, or the service behind it, refused (billing disabled, a missing permission).
    case forbidden(String)
    /// 5xx, or an answer that couldn't be read: usually brief.
    case unavailable(String)
    /// 400, 404, 422: the request itself was refused.
    case badRequest(String)
    /// 413: the recording is larger than the endpoint takes in one request.
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

/// Maps the endpoint's answers to `AppError`. Its error bodies are OpenAI's (`{"error": {"message", "type", "code"}}`),
/// and an error after a 200 comes as a chunk with an `error` whose `code` is the HTTP status.
enum VertexProxyErrorMapper {
    /// How an endpoint says a spend limit or a used-up quota stopped it (lowercased).
    static let spendLimitPhrases = ["spend limit", "exceeded your current quota"]

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
        case 402: return .vertexProxy(.spendLimit(message))
        case 403: return .vertexProxy(.forbidden(message))
        case 408, 504: return .timeout(engine)
        case 413: return .vertexProxy(.tooLarge)
        case 429: return .vertexProxy(.rateLimited(retryAfter: retryAfter))
        case 500...599: return .vertexProxy(.unavailable(message.isEmpty ? "HTTP \(status)" : message))
        case 400...499: return .vertexProxy(.badRequest(message.isEmpty ? "HTTP \(status)" : message))
        default: return .vertexProxy(.unavailable(message.isEmpty ? "Unexpected HTTP \(status)" : "HTTP \(status): \(message)"))
        }
    }

    /// An `AppError` the shared stream and response readers made, in the endpoint's terms: anything that names
    /// OpenRouter or its settings becomes the endpoint's own failure. What any service says the same way (a cut-off
    /// answer, a refusal by the model, a timeout, no speech) stays as it is.
    static func adapt(_ error: AppError) -> AppError {
        switch error {
        case .openRouterMissingKey, .openRouterKeyUnreadable: .vertexProxy(.keyUnreadable)
        case .openRouterInvalidKey(let message): .vertexProxy(.keyRejected(message))
        case .openRouterNoCredits(let message), .openRouterKeyLimit(let message): .vertexProxy(.spendLimit(message))
        case .openRouterRateLimited(let retryAfter): .vertexProxy(.rateLimited(retryAfter: retryAfter))
        case .openRouterNoRoute(let message), .openRouterBadRequest(let message): .vertexProxy(.badRequest(message))
        case .openRouterProviderUnavailable(let message), .openRouterServer(let message):
            .vertexProxy(.unavailable(VertexProxy.reword(message)))
        case .offline, .connectionBlocked: .vertexProxy(.unreachable)
        case .recordingTooLarge: .vertexProxy(.tooLarge)
        default: error
        }
    }
}

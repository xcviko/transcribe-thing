import Foundation

// Wire formats for OpenRouter's chat completions and key endpoints, and the mapping of every documented
// failure shape to `AppError`. Pure and synchronous so tests can drive them with canned bodies.

// MARK: Request

struct OpenRouterChatRequest: Encodable, Equatable {
    let model: String
    let messages: [OpenRouterMessage]
    let reasoning: Reasoning
    let provider: Provider
    let maxTokens: Int
    let stream: Bool

    struct Reasoning: Encodable, Equatable {
        let effort: String
        let exclude: Bool
    }

    struct Provider: Encodable, Equatable {
        let only: [String]
        let allowFallbacks: Bool
        enum CodingKeys: String, CodingKey { case only, allowFallbacks = "allow_fallbacks" }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, reasoning, provider, stream
        case maxTokens = "max_tokens"
    }

    /// Gemini via Google AI Studio only, high reasoning with the reasoning text excluded, no temperature
    /// (Google recommends the default for Gemini 3). The system message exists only for a non-empty prompt,
    /// and the user message carries ONLY the audio: no text part, ever.
    static func transcription(model: String, audioBase64: String, systemPrompt: String?) -> OpenRouterChatRequest {
        var messages: [OpenRouterMessage] = []
        if let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            messages.append(.system(prompt))
        }
        messages.append(.userAudio(base64: audioBase64, format: "wav"))
        return OpenRouterChatRequest(
            model: model,
            messages: messages,
            reasoning: Reasoning(effort: "high", exclude: true),
            provider: Provider(only: ["google-ai-studio"], allowFallbacks: false),
            maxTokens: 32_768,
            stream: false)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Base64 is full of "/"; the default encoder would send every one as "\/".
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum OpenRouterMessage: Encodable, Equatable {
    case system(String)
    case userAudio(base64: String, format: String)

    private struct AudioPart: Encodable {
        let type = "input_audio"
        let inputAudio: Payload
        struct Payload: Encodable { let data: String; let format: String }
        enum CodingKeys: String, CodingKey { case type, inputAudio = "input_audio" }
    }

    private enum CodingKeys: String, CodingKey { case role, content }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let text):
            try container.encode("system", forKey: .role)
            try container.encode(text, forKey: .content)
        case .userAudio(let data, let format):
            try container.encode("user", forKey: .role)
            try container.encode([AudioPart(inputAudio: .init(data: data, format: format))], forKey: .content)
        }
    }
}

// MARK: Response

struct OpenRouterChatResponse: Decodable {
    let id: String?
    let model: String?
    let provider: String?
    let serviceTier: String?
    let choices: [Choice]?
    let usage: Usage?
    let error: OpenRouterAPIError?

    struct Choice: Decodable {
        let finishReason: String?
        let nativeFinishReason: String?
        let message: Message?
        let error: OpenRouterAPIError?
        enum CodingKeys: String, CodingKey {
            case message, error
            case finishReason = "finish_reason", nativeFinishReason = "native_finish_reason"
        }
    }

    struct Message: Decodable {
        let content: Content?
        let refusal: String?
    }

    /// A string, null, or (rarely) an array of parts.
    enum Content: Decodable {
        case text(String)
        case parts([Part])
        struct Part: Decodable { let type: String?; let text: String? }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .parts(try container.decode([Part].self))
            }
        }

        var text: String {
            switch self {
            case .text(let text): text
            case .parts(let parts): parts.compactMap(\.text).joined()
            }
        }
    }

    struct Usage: Decodable {
        let cost: Double?
        let completionTokensDetails: CompletionDetails?
        struct CompletionDetails: Decodable {
            let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
        enum CodingKeys: String, CodingKey { case cost, completionTokensDetails = "completion_tokens_details" }
    }

    enum CodingKeys: String, CodingKey {
        case id, model, provider, choices, usage, error
        case serviceTier = "service_tier"
    }
}

struct OpenRouterErrorEnvelope: Decodable { let error: OpenRouterAPIError }

struct OpenRouterAPIError: Decodable, Equatable {
    /// A number normally; a string in some streamed errors ("server_error").
    let code: Code?
    let message: String?
    let metadata: Metadata?

    enum Code: Decodable, Equatable {
        case int(Int), string(String)
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
        var intValue: Int? { if case .int(let value) = self { value } else { nil } }
    }

    struct Metadata: Decodable, Equatable {
        let errorType: String?
        let limitSource: String?
        let providerName: String?
        enum CodingKeys: String, CodingKey {
            case errorType = "error_type", limitSource = "limit_source", providerName = "provider_name"
        }
    }
}

/// `GET /api/v1/key` → `data`.
struct OpenRouterKeyInfo: Decodable {
    let label: String?
    let limit: Double?
    let limitRemaining: Double?
    let usage: Double?
    let isFreeTier: Bool?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case label, limit, usage
        case limitRemaining = "limit_remaining"
        case isFreeTier = "is_free_tier"
        case expiresAt = "expires_at"
    }

    var keyInfo: KeyInfo {
        KeyInfo(label: label, limit: limit, limitRemaining: limitRemaining, usage: usage ?? 0,
                isFreeTier: isFreeTier ?? false, expiresAt: expiresAt.flatMap(Self.parseDate))
    }

    static func parseDate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}

struct OpenRouterDataEnvelope<T: Decodable>: Decodable { let data: T }

// MARK: Error mapping

enum OpenRouterErrorMapper {
    static let noRouteHint = "Google AI Studio isn’t reachable with your OpenRouter settings. Check openrouter.ai/settings/privacy: zero data retention (ZDR) for Google and your allowed providers must let Google AI Studio through."

    /// Maps a non-200 response (body may be JSON, HTML or empty).
    static func httpError(status: Int, data: Data, retryAfter: Double?, engine: EngineID) -> AppError {
        if let envelope = try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: data) {
            return map(envelope.error, status: status, retryAfter: retryAfter, engine: engine)
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return map(status: status, message: text.hasPrefix("<") ? "" : text, errorType: nil, retryAfter: retryAfter, engine: engine)
    }

    /// Maps an error object (top level or inside a choice). `status` is the HTTP status, used when the object
    /// carries no numeric code.
    static func map(_ body: OpenRouterAPIError, status: Int, retryAfter: Double?, engine: EngineID) -> AppError {
        map(status: body.code?.intValue ?? status, message: body.message ?? "",
            errorType: body.metadata?.errorType, limitSource: body.metadata?.limitSource,
            retryAfter: retryAfter, engine: engine)
    }

    static func map(status: Int, message rawMessage: String, errorType: String?, limitSource: String? = nil,
                    retryAfter: Double?, engine: EngineID) -> AppError {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        // Routing dead ends are documented both as 404 and as 503; the message tells them apart.
        let noRoute = lowered.hasPrefix("no endpoints") || lowered.hasPrefix("no allowed providers")
            || lowered.contains("no endpoints found")
        if noRoute { return .openRouterNoRoute(join(message, noRouteHint)) }

        // A 402 says which limit it hit. Only openrouter_credits means the account is out of credit.
        switch limitSource {
        case "openrouter_in_flight_budget":
            // Too much reserved by requests still running (each reserves up to max_tokens): wait, then retry.
            return .openRouterRateLimited(retryAfter: retryAfter)
        case "openrouter_key_limit":
            return .openRouterKeyLimit(message)
        default:
            break
        }

        switch errorType {
        case "content_policy_violation", "refusal": return .openRouterRefused(message)
        case "payload_too_large": return .recordingTooLarge
        case "timeout": return .timeout(engine)
        case "rate_limit_exceeded": return .openRouterRateLimited(retryAfter: retryAfter)
        case "provider_overloaded", "provider_unavailable": return .openRouterProviderUnavailable(message)
        case "authentication": return .openRouterInvalidKey(message)
        case "payment_required": return .openRouterNoCredits(message)
        case "not_found": return .openRouterNoRoute(join(message, noRouteHint))
        case "permission_denied": return .openRouterRefused(message)
        case "context_length_exceeded", "max_tokens_exceeded", "token_limit_exceeded", "string_too_long",
             "invalid_request", "invalid_prompt", "unprocessable", "precondition_failed":
            return .openRouterBadRequest(message)
        default: break
        }

        switch status {
        case 400, 422: return .openRouterBadRequest(message)
        case 401: return .openRouterInvalidKey(message)
        case 402: return .openRouterNoCredits(message)
        case 403: return .openRouterRefused(message)
        case 404: return .openRouterNoRoute(join(message, noRouteHint))
        case 408, 504, 524: return .timeout(engine)
        case 413: return .recordingTooLarge
        case 429: return .openRouterRateLimited(retryAfter: retryAfter)
        case 502, 503, 529: return .openRouterProviderUnavailable(message)
        case 500...599: return .openRouterServer(message.isEmpty ? "HTTP \(status)" : message)
        case 400...499: return .openRouterBadRequest(message.isEmpty ? "HTTP \(status)" : message)
        default: return .openRouterServer(message.isEmpty ? "Unexpected HTTP \(status)" : "HTTP \(status): \(message)")
        }
    }

    /// Interprets a 200 response. Failures can still arrive with 200: a top-level `error`, an error in the
    /// choice, or a finish reason of error / content_filter / length.
    static func success(data: Data, engine: EngineID) throws -> CloudResult {
        let decoded: OpenRouterChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        } catch {
            throw AppError.openRouterServer("OpenRouter sent a response \(Brand.name) couldn’t read.")
        }
        if let error = decoded.error { throw map(error, status: 502, retryAfter: nil, engine: engine) }
        guard let choice = decoded.choices?.first else {
            throw AppError.openRouterServer("OpenRouter sent no transcript.")
        }
        if let error = choice.error { throw map(error, status: 502, retryAfter: nil, engine: engine) }

        let text = (choice.message?.content?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch choice.finishReason {
        case "error":
            throw AppError.openRouterProviderUnavailable("Gemini stopped with an error before finishing.")
        case "content_filter":
            let reason = choice.message?.refusal ?? choice.nativeFinishReason.map { "Stopped by the safety filter (\($0))." }
            throw AppError.openRouterRefused(reason ?? "Stopped by the safety filter.")
        case "length" where text.isEmpty:
            throw AppError.emptyResult(engine)
        case "length":
            // Out of output tokens mid-transcript: a repetition loop or a cut-off ending. Never pasted as if whole.
            throw AppError.openRouterTruncated(text)
        default:
            break
        }
        if text.isEmpty, let refusal = choice.message?.refusal, !refusal.isEmpty {
            throw AppError.openRouterRefused(refusal)
        }
        return CloudResult(text: text, provider: decoded.provider, costUSD: decoded.usage?.cost,
                           reasoningTokens: decoded.usage?.completionTokensDetails?.reasoningTokens)
    }

    /// `Retry-After` is seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date = Date()) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    private static func join(_ message: String, _ hint: String) -> String {
        message.isEmpty ? hint : "\(message) \(hint)"
    }
}

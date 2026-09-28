import Foundation

// Wire formats for OpenRouter's chat completions, transcription, generation and key endpoints, and the mapping of every documented
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

    struct Provider: Encodable, Equatable, Sendable {
        let only: [String]
        let allowFallbacks: Bool
        enum CodingKeys: String, CodingKey { case only, allowFallbacks = "allow_fallbacks" }

        /// Google AI Studio and nothing else, no fallbacks: every Gemini request.
        static let googleAIStudio = Provider(only: ["google-ai-studio"], allowFallbacks: false)
        /// OpenAI and nothing else, no fallbacks: GPT-6 Luna as Clean-up.
        static let openAI = Provider(only: ["openai"], allowFallbacks: false)
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, reasoning, provider, stream
        case maxTokens = "max_tokens"
    }

    /// Gemini via Google AI Studio only, thinking at `effort` (the model's fixed level, `EngineID.reasoningEffort`)
    /// with the reasoning text excluded, no temperature (Google recommends the default for Gemini 3). The system
    /// message exists only for a non-empty prompt, and the user message carries ONLY the audio, in `format` ("wav",
    /// "m4a"): no text part, ever. `maxTokens` grows with the audio (`OpenRouterClient.transcriptionMaxTokens`).
    static func transcription(model: String, audioBase64: String, format: String, systemPrompt: String?,
                              effort: ReasoningEffort, maxTokens: Int) -> OpenRouterChatRequest {
        var messages: [OpenRouterMessage] = []
        if let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            messages.append(.system(prompt))
        }
        messages.append(.userAudio(base64: audioBase64, format: format))
        return OpenRouterChatRequest(
            model: model,
            messages: messages,
            reasoning: Reasoning(effort: effort.rawValue, exclude: true),
            provider: .googleAIStudio,
            maxTokens: maxTokens,
            stream: false)
    }

    /// Clean-up of a transcript: the prompt as the system message, then the transcript as plain user text inside
    /// `<transcript>` tags. `route` names the model, the provider it's pinned to (no fallbacks) and the effort as
    /// sent (`CleanupModel.route`, or any model for `EngineCLI --cleanup-bench`). Reasoning excluded and no
    /// temperature like transcription; `max_tokens` grows with the text (`CleanupModel.maxTokens`).
    static func cleanup(route: CleanupRoute, systemPrompt: String, transcript: String) -> OpenRouterChatRequest {
        var messages: [OpenRouterMessage] = []
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { messages.append(.system(prompt)) }
        messages.append(.user(CleanupModel.userMessage(for: transcript)))
        return OpenRouterChatRequest(
            model: route.model,
            messages: messages,
            reasoning: Reasoning(effort: route.effort, exclude: true),
            provider: route.provider,
            maxTokens: CleanupModel.maxTokens(forCharacterCount: transcript.count, effort: route.budget),
            stream: false)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Base64 is full of "/"; the default encoder would send every one as "\/".
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Where a clean-up request goes and how hard the model thinks. The app sends the clean-up model's
/// (`CleanupModel.route`): GPT-6 Luna on OpenAI, thinking off.
struct CleanupRoute: Equatable, Sendable {
    var model: String
    var provider: OpenRouterChatRequest.Provider
    /// `reasoning.effort` as sent: a `ReasoningEffort`, or a level no clean-up model offers ("xhigh", for the bench).
    var effort: String
    /// The level `max_tokens` is sized for (`CleanupModel.maxTokens`).
    var budget: ReasoningEffort

    init(model: String, effort: ReasoningEffort, provider: OpenRouterChatRequest.Provider) {
        self.init(model: model, provider: provider, effort: effort.rawValue, budget: effort)
    }

    init(model: String, provider: OpenRouterChatRequest.Provider, effort: String, budget: ReasoningEffort) {
        self.model = model
        self.provider = provider
        self.effort = effort
        self.budget = budget
    }
}

enum OpenRouterMessage: Encodable, Equatable {
    case system(String)
    /// Plain text from the user (the transcript a clean-up works on).
    case user(String)
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
        case .user(let text):
            try container.encode("user", forKey: .role)
            try container.encode(text, forKey: .content)
        case .userAudio(let data, let format):
            try container.encode("user", forKey: .role)
            try container.encode([AudioPart(inputAudio: .init(data: data, format: format))], forKey: .content)
        }
    }
}

/// `POST /audio/transcriptions` body. No `provider` object: routing preferences (`order`, `only`, `ignore`) are
/// not applied to transcription requests, so sending them would only suggest a pin that doesn't exist.
struct OpenRouterSpeechRequest: Encodable, Equatable {
    let model: String
    let inputAudio: InputAudio

    struct InputAudio: Encodable, Equatable {
        /// Raw base64, not a data URI.
        let data: String
        let format: String
    }

    enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
    }

    /// No `language`: Parakeet v3 detects it.
    static func wav(model: String, audioBase64: String) -> OpenRouterSpeechRequest {
        OpenRouterSpeechRequest(model: model, inputAudio: InputAudio(data: audioBase64, format: "wav"))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: Response

/// `POST /audio/transcriptions` → `{ text, usage }`; the generation id comes in the `X-Generation-Id` header.
struct OpenRouterSpeechResponse: Decodable {
    let text: String?
    let usage: Usage?
    let error: OpenRouterAPIError?

    struct Usage: Decodable {
        let seconds: Double?
        let cost: Double?
    }
}

/// `GET /api/v1/generation?id=` → `data`. Only what transcribe-thing reads; every field is nullable.
struct OpenRouterGeneration: Decodable {
    let id: String?
    let providerName: String?
    let totalCost: Double?
    /// Milliseconds. The API reference calls it total latency; OpenRouter has also used it for the time to the
    /// first token. Unverified for these models, so it's recorded, not labeled in the UI.
    let latency: Double?
    /// Milliseconds spent generating.
    let generationTime: Double?
    let tokensPrompt: Int?
    let tokensCompletion: Int?
    let nativeTokensPrompt: Int?
    let nativeTokensCompletion: Int?
    let nativeTokensReasoning: Int?
    let nativeTokensCached: Int?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case id, latency
        case providerName = "provider_name"
        case totalCost = "total_cost"
        case generationTime = "generation_time"
        case tokensPrompt = "tokens_prompt", tokensCompletion = "tokens_completion"
        case nativeTokensPrompt = "native_tokens_prompt", nativeTokensCompletion = "native_tokens_completion"
        case nativeTokensReasoning = "native_tokens_reasoning", nativeTokensCached = "native_tokens_cached"
        case finishReason = "finish_reason"
    }

    var details: GenerationDetails {
        let name = providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GenerationDetails(provider: name?.isEmpty == false ? name : nil, costUSD: totalCost,
                                 latency: latency.map { $0 / 1000 }, generationTime: generationTime.map { $0 / 1000 },
                                 reasoningTokens: nativeTokensReasoning)
    }
}

/// What OpenRouter's generation record adds to a delivered result, in seconds and dollars.
struct GenerationDetails: Sendable, Equatable {
    var provider: String?
    var costUSD: Double?
    /// OpenRouter's `latency` (see `OpenRouterGeneration.latency`).
    var latency: TimeInterval?
    var generationTime: TimeInterval?
    var reasoningTokens: Int?
}

struct OpenRouterChatResponse: Decodable {
    let id: String?
    let model: String?
    let provider: String?
    let serviceTier: String?
    let choices: [Choice]?
    let usage: Usage?
    let error: OpenRouterAPIError?
    /// Present with the `X-OpenRouter-Metadata: enabled` request header.
    let openrouterMetadata: Metadata?

    struct Metadata: Decodable {
        /// Milliseconds from dispatching the upstream request until its response body ended.
        let generationTime: Double?
        enum CodingKeys: String, CodingKey { case generationTime = "generation_time" }
    }

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

    /// Always included now. `completion_tokens` includes the reasoning tokens.
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let cost: Double?
        let isBYOK: Bool?
        let promptTokensDetails: PromptDetails?
        let completionTokensDetails: CompletionDetails?
        struct PromptDetails: Decodable {
            let cachedTokens: Int?
            let audioTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens", audioTokens = "audio_tokens" }
        }
        struct CompletionDetails: Decodable {
            let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
        enum CodingKeys: String, CodingKey {
            case cost
            case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
            case isBYOK = "is_byok"
            case promptTokensDetails = "prompt_tokens_details", completionTokensDetails = "completion_tokens_details"
        }

        var tokens: TokenUsage {
            TokenUsage(promptTokens: promptTokens, audioTokens: promptTokensDetails?.audioTokens,
                       cachedTokens: promptTokensDetails?.cachedTokens, completionTokens: completionTokens,
                       reasoningTokens: completionTokensDetails?.reasoningTokens, totalTokens: totalTokens)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, model, provider, choices, usage, error
        case serviceTier = "service_tier"
        case openrouterMetadata = "openrouter_metadata"
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

    static func noRouteHint(for engine: EngineID) -> String {
        guard engine.cloudAPI == .transcriptions else { return noRouteHint }
        let provider = engine.provider ?? "its provider"
        return "No provider of \(engine.modelName) is reachable with your OpenRouter settings. Check openrouter.ai/settings/privacy: your data policy and allowed providers must let \(provider) through."
    }

    /// How a 400 says the request is too large to take (lowercased).
    static let tooLargePhrases = ["payload size", "request entity too large", "request too large"]

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
        if noRoute { return .openRouterNoRoute(join(message, noRouteHint(for: engine))) }

        // A request too large to take, reported as a bad request. Only these phrases: a clean-up's errors come
        // through here too.
        if status == 400, Self.tooLargePhrases.contains(where: lowered.contains) { return .recordingTooLarge }

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
        case "not_found": return .openRouterNoRoute(join(message, noRouteHint(for: engine)))
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
        case 404: return .openRouterNoRoute(join(message, noRouteHint(for: engine)))
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
    /// choice, or a finish reason of error / content_filter / length. Empty text on a normal finish is returned
    /// as is: Gemini heard no speech.
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
        case "length":
            // Out of output tokens: a repetition loop, a cut-off ending, or reasoning that used every token before
            // any text (empty `text`). Never pasted as if whole, and never taken for silence.
            throw AppError.openRouterTruncated(text)
        default:
            break
        }
        if text.isEmpty, let refusal = choice.message?.refusal, !refusal.isEmpty {
            throw AppError.openRouterRefused(refusal)
        }
        return CloudResult(text: text, provider: decoded.provider, costUSD: decoded.usage?.cost,
                           usage: decoded.usage?.tokens, generationID: decoded.id, model: decoded.model,
                           finishReason: choice.finishReason,
                           generationTime: decoded.openrouterMetadata?.generationTime.map { $0 / 1000 },
                           serviceTier: decoded.serviceTier)
    }

    /// Interprets a 200 from the transcription endpoint. An error object inside it is an upstream failure, mapped
    /// like the chat endpoint's. Empty text is returned as is: silence legitimately transcribes to nothing.
    static func speechSuccess(data: Data, engine: EngineID) throws -> CloudResult {
        let decoded: OpenRouterSpeechResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterSpeechResponse.self, from: data)
        } catch {
            throw AppError.openRouterServer("OpenRouter sent a response \(Brand.name) couldn’t read.")
        }
        if let error = decoded.error { throw map(error, status: 502, retryAfter: nil, engine: engine) }
        guard let text = decoded.text else { throw AppError.openRouterServer("OpenRouter sent no transcript.") }
        return CloudResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), provider: nil,
                           costUSD: decoded.usage?.cost, audioSeconds: decoded.usage?.seconds)
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

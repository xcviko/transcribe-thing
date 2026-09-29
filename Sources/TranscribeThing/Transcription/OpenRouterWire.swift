import Foundation

// Wire formats for OpenRouter's chat completions (streamed), transcription, generation and key endpoints, and the mapping
// of every documented failure shape to `AppError`. Pure and synchronous so tests can drive them with canned bodies and
// streams.

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

    /// Gemini via Google AI Studio only, streamed, thinking at `effort` (the model's fixed level,
    /// `EngineID.reasoningEffort`) with its reasoning included: the summaries of its thoughts stream ahead of the
    /// transcript, so the pill can count them (the bill is the same either way). No temperature (Google recommends the
    /// default for Gemini 3). The system message exists only for a non-empty prompt, and the user message carries ONLY
    /// the audio, in `format` ("wav", "m4a"): no text part, ever. `maxTokens` grows with the audio
    /// (`OpenRouterClient.transcriptionMaxTokens`).
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
            reasoning: Reasoning(effort: effort.rawValue, exclude: false),
            provider: .googleAIStudio,
            maxTokens: maxTokens,
            stream: true)
    }

    /// Clean-up of a transcript: the prompt as the system message, then the transcript as plain user text inside
    /// `<transcript>` tags. `route` names the model, the provider it's pinned to (no fallbacks) and the effort as
    /// sent (`CleanupModel.route`, or any model for `EngineCLI --cleanup-bench`). Streamed like transcription, with no
    /// temperature; reasoning excluded (GPT-6 Luna doesn't think at "none"). `max_tokens` grows with the text
    /// (`CleanupModel.maxTokens`).
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
            stream: true)
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

/// One event of a streamed chat completion (`chat.completion.chunk`), every field optional: most carry a delta of
/// reasoning or text, the last one before `[DONE]` carries `usage`, and a failure after OpenRouter answered 200
/// arrives as a chunk with an `error`.
struct OpenRouterChatChunk: Decodable {
    let id: String?
    let model: String?
    let provider: String?
    let serviceTier: String?
    /// Present with the `X-OpenRouter-Metadata: enabled` request header.
    let openrouterMetadata: Metadata?
    let usage: Usage?
    let error: OpenRouterAPIError?
    let choices: [Choice]?

    struct Metadata: Decodable, Equatable {
        /// Milliseconds from dispatching the upstream request until its response body ended.
        let generationTime: Double?
        enum CodingKeys: String, CodingKey { case generationTime = "generation_time" }
    }

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?
        let nativeFinishReason: String?
        let error: OpenRouterAPIError?
        enum CodingKeys: String, CodingKey {
            case delta, error
            case finishReason = "finish_reason", nativeFinishReason = "native_finish_reason"
        }
    }

    /// What one chunk adds. Lenient field by field: a part this build can't read is dropped, not the chunk's text.
    struct Delta: Decodable {
        let content: String?
        /// The reasoning as plain text (for Gemini, a summary of its thoughts).
        let reasoning: String?
        /// The same reasoning as typed parts; only `reasoning.text` and `reasoning.summary` hold readable text.
        let reasoningDetails: [ReasoningDetail]?
        let refusal: String?

        enum CodingKeys: String, CodingKey {
            case content, reasoning, refusal
            case reasoningDetails = "reasoning_details"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            content = try? c.decodeIfPresent(String.self, forKey: .content)
            reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
            reasoningDetails = try? c.decodeIfPresent([ReasoningDetail].self, forKey: .reasoningDetails)
            refusal = try? c.decodeIfPresent(String.self, forKey: .refusal)
        }

        /// Characters of readable reasoning: `reasoning`, else the text of its details. Never an encrypted part
        /// (`reasoning.encrypted` is an opaque blob, Gemini's thought signature).
        var reasoningCharacters: Int {
            if let reasoning, !reasoning.isEmpty { return reasoning.count }
            return (reasoningDetails ?? []).reduce(0) { sum, detail in
                switch detail.type {
                case "reasoning.text": sum + (detail.text?.count ?? 0)
                case "reasoning.summary": sum + (detail.summary?.count ?? 0)
                default: sum
                }
            }
        }
    }

    struct ReasoningDetail: Decodable {
        let type: String?
        let text: String?
        let summary: String?

        enum CodingKeys: String, CodingKey { case type, text, summary }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            text = try? c.decodeIfPresent(String.self, forKey: .text)
            summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        }
    }

    /// Sent once, in the chunk just before `[DONE]`. `completion_tokens` includes the reasoning tokens.
    struct Usage: Decodable, Equatable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let cost: Double?
        let isBYOK: Bool?
        let promptTokensDetails: PromptDetails?
        let completionTokensDetails: CompletionDetails?
        struct PromptDetails: Decodable, Equatable {
            let cachedTokens: Int?
            let audioTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens", audioTokens = "audio_tokens" }
        }
        struct CompletionDetails: Decodable, Equatable {
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
        case id, model, provider, usage, error, choices
        case serviceTier = "service_tier"
        case openrouterMetadata = "openrouter_metadata"
    }
}

/// How much of a streamed answer has come so far, for the pill's live count: characters of reasoning (for Gemini, the
/// summaries of its thoughts, far shorter than the reasoning it's billed for) and of the answer itself.
struct ChatStreamProgress: Equatable, Sendable {
    var reasoningCharacters = 0
    var outputCharacters = 0
}

/// Cuts a server-sent-event stream into lines at line feeds only (a carriage return before one goes with it), each
/// decoded as UTF-8 once it's whole. Foundation's `lines` also cuts at U+2028, U+2029 and U+0085, which JSON leaves
/// unescaped inside strings: the event holding one would be split in two and its text lost. Keeping bytes until
/// their line ends also keeps a character whole when the network splits it.
struct ServerSentEventLines {
    private var pending: [UInt8] = []

    /// The line `byte` ends, when it's a line feed.
    mutating func take(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            pending.append(byte)
            return nil
        }
        return flush()
    }

    /// The last line, when the stream ended without a line feed after it.
    mutating func finish() -> String? {
        pending.isEmpty ? nil : flush()
    }

    private mutating func flush() -> String {
        if pending.last == 0x0D { pending.removeLast() }
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// A streamed chat completion put together as its lines arrive. OpenRouter sends server-sent events: each event one
/// `data: {chunk}` line, `: OPENROUTER PROCESSING` comments while it waits (so the connection never idles out), and
/// `data: [DONE]` last. Pure, so tests feed it canned streams.
struct OpenRouterChatStream {
    private(set) var text = ""
    private(set) var refusal = ""
    private(set) var progress = ChatStreamProgress()
    /// The last finish reasons any chunk named (the accounting chunk repeats them).
    private(set) var finishReason: String?
    private(set) var nativeFinishReason: String?
    /// From the accounting chunk just before `[DONE]`.
    private(set) var usage: OpenRouterChatChunk.Usage?
    private(set) var id: String?
    private(set) var model: String?
    private(set) var provider: String?
    private(set) var serviceTier: String?
    private(set) var metadata: OpenRouterChatChunk.Metadata?
    /// A failure reported inside the stream, at the top level or in the choice.
    private(set) var error: OpenRouterAPIError?
    /// `data: [DONE]` arrived: the stream ended as it should.
    private(set) var isDone = false
    /// Some chunk carried a choice: a stream with none sent no answer at all.
    private var sawChoice = false
    /// A line that isn't server-sent events at all (an HTML page, say).
    private var sawForeignLine = false
    private let decoder = JSONDecoder()

    /// Any reasoning or text has come: a failure now is no quick one to send again.
    var hasOutput: Bool { progress.reasoningCharacters > 0 || progress.outputCharacters > 0 }

    /// Takes one line of the stream; true when `progress` changed. Comments (":"), `event:` and `id:` fields and blank
    /// lines are skipped, and so is an event this build can't read (logged without its content).
    mutating func consume(_ line: some StringProtocol) -> Bool {
        guard line.hasPrefix("data:") else {
            let field = line.prefix { $0 != ":" }
            if !line.allSatisfy(\.isWhitespace), !line.hasPrefix(":"), !Self.fields.contains(String(field)) {
                sawForeignLine = true
            }
            return false
        }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            isDone = true
            return false
        }
        guard let chunk = try? decoder.decode(OpenRouterChatChunk.self, from: Data(payload.utf8)) else {
            Log.net.warning("Skipped a streamed event that couldn’t be read (\(payload.utf8.count) bytes)")
            return false
        }
        return apply(chunk)
    }

    private mutating func apply(_ chunk: OpenRouterChatChunk) -> Bool {
        if let value = chunk.id { id = value }
        if let value = chunk.model { model = value }
        if let value = chunk.provider { provider = value }
        if let value = chunk.serviceTier { serviceTier = value }
        if let value = chunk.openrouterMetadata { metadata = value }
        if let value = chunk.usage { usage = value }
        if let value = chunk.error { error = value }
        let before = progress
        for choice in chunk.choices ?? [] {
            sawChoice = true
            if let value = choice.error { error = value }
            if let value = choice.finishReason { finishReason = value }
            if let value = choice.nativeFinishReason { nativeFinishReason = value }
            guard let delta = choice.delta else { continue }
            if let content = delta.content, !content.isEmpty {
                text += content
                progress.outputCharacters += content.count
            }
            if let value = delta.refusal { refusal += value }
            progress.reasoningCharacters += delta.reasoningCharacters
        }
        return progress != before
    }

    /// The server-sent event fields besides `data`, which OpenRouter doesn't use.
    private static let fields: Set<String> = ["event", "id", "retry"]

    /// The answer once the stream has ended, or the failure it carried. Failures can come inside a 200: an `error`
    /// (the only event, or after some text), or a finish reason of error / content_filter / length. A stream that
    /// just stops, with no finish reason and no `[DONE]`, lost its connection. Empty text on a normal finish is
    /// returned as is: Gemini heard no speech.
    func result(engine: EngineID) throws -> CloudResult {
        if let error { throw OpenRouterErrorMapper.map(error, status: 502, retryAfter: nil, engine: engine) }
        guard finishReason != nil || isDone else {
            if sawForeignLine, !sawChoice {
                throw AppError.openRouterServer("OpenRouter sent a response \(Brand.name) couldn’t read.")
            }
            throw AppError.openRouterServer("The connection to OpenRouter was lost.")
        }
        guard sawChoice else { throw AppError.openRouterServer("OpenRouter sent no transcript.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch finishReason {
        case "error":
            throw AppError.openRouterProviderUnavailable("Gemini stopped with an error before finishing.")
        case "content_filter":
            let reason = refusal.isEmpty ? nativeFinishReason.map { "Stopped by the safety filter (\($0))." } : refusal
            throw AppError.openRouterRefused(reason ?? "Stopped by the safety filter.")
        case "length":
            // Out of output tokens: a repetition loop, a cut-off ending, or reasoning that used every token before
            // any text (empty `text`). Never pasted as if whole, and never taken for silence.
            throw AppError.openRouterTruncated(text)
        default:
            break
        }
        if text.isEmpty, !refusal.isEmpty { throw AppError.openRouterRefused(refusal) }
        return CloudResult(text: text, provider: provider, costUSD: usage?.cost, usage: usage?.tokens,
                           generationID: id, model: model, finishReason: finishReason,
                           generationTime: metadata?.generationTime.map { $0 / 1000 }, serviceTier: serviceTier,
                           reasoningCharacters: progress.reasoningCharacters > 0 ? progress.reasoningCharacters : nil)
    }

    /// A whole stream at once (tests, canned answers): every line of `sse`, cut as the client cuts them, then the result.
    static func parse(_ sse: String, engine: EngineID) throws -> CloudResult {
        var stream = OpenRouterChatStream()
        var lines = ServerSentEventLines()
        for byte in sse.utf8 {
            if let line = lines.take(byte) { _ = stream.consume(line) }
        }
        if let line = lines.finish() { _ = stream.consume(line) }
        return try stream.result(engine: engine)
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

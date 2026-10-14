import Foundation

// Wire formats for OpenRouter's chat completions (streamed), transcription, generation and key endpoints, and the mapping
// of every documented failure shape to `AppError`. Pure and synchronous so tests can drive them with canned bodies and
// streams.

// MARK: Request

struct OpenRouterChatRequest: Encodable, Equatable {
    let model: String
    let messages: [OpenRouterMessage]
    let reasoning: Reasoning
    /// OpenRouter's routing; nil leaves it out (the user's own endpoint has no routing to choose).
    var provider: Provider?
    var maxTokens: Int
    let stream: Bool
    /// Sent only when set: otherwise the model's default (every request the app sends).
    var temperature: Double? = nil

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
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, reasoning, provider, stream, temperature
        case maxTokens = "max_tokens"
    }

    /// Gemini via Google AI Studio only, streamed, thinking at `effort` (the level picked for the model,
    /// `AppSettings.reasoningEfforts`) with its reasoning included: the summaries of its thoughts stream ahead of the
    /// transcript, so the pill can count them (the bill is the same either way). No temperature (Google recommends the
    /// default for Gemini 3). The system message exists only for a non-empty prompt, and the user message carries ONLY
    /// the audio, in `format` ("m4a"; "wav" from `EngineCLI --upload`): no text part, ever. `maxTokens`
    /// grows with the audio (`OpenRouterClient.transcriptionMaxTokens`).
    /// `provider`: another endpoint than Google AI Studio's ("google-ai-studio/priority", `EngineCLI --provider`).
    /// `voiceSampleBase64` (a call's only, `CallVoiceSample`): the user message carries two audio parts, the sample of
    /// the person's voice first, then the audio, both in `format`, still no text part; the system prompt says which is
    /// which. OpenRouter hands Gemini the parts in this order. Nil: the one part, as every other request.
    static func transcription(model: String, audioBase64: String, format: String, systemPrompt: String?,
                              effort: ReasoningEffort, maxTokens: Int, provider: Provider = .googleAIStudio,
                              voiceSampleBase64: String? = nil) -> OpenRouterChatRequest {
        var messages: [OpenRouterMessage] = []
        if let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            messages.append(.system(prompt))
        }
        if let voiceSampleBase64 {
            messages.append(.userAudioParts([.init(base64: voiceSampleBase64, format: format),
                                             .init(base64: audioBase64, format: format)]))
        } else {
            messages.append(.userAudio(base64: audioBase64, format: format))
        }
        return OpenRouterChatRequest(
            model: model,
            messages: messages,
            reasoning: Reasoning(effort: effort.rawValue, exclude: false),
            provider: provider,
            maxTokens: maxTokens,
            stream: true)
    }

    /// Text in, text out (Polish Selection): the prompt as the system message, then the text as plain user text inside
    /// `<transcript>` tags (`TextRoute.userMessage(for:)`). `route` names the model, the provider it's pinned to (no
    /// fallbacks) and the effort as sent. Streamed like transcription; reasoning excluded unless the route streams it.
    /// `max_tokens` grows with the text (`TextRoute.maxTokens`).
    static func text(route: TextRoute, systemPrompt: String, text: String) -> OpenRouterChatRequest {
        var messages: [OpenRouterMessage] = []
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { messages.append(.system(prompt)) }
        messages.append(.user(TextRoute.userMessage(for: text)))
        return OpenRouterChatRequest(
            model: route.model,
            messages: messages,
            reasoning: Reasoning(effort: route.effort, exclude: !route.streamsReasoning),
            provider: route.provider,
            maxTokens: TextRoute.maxTokens(forCharacterCount: text.count, effort: route.budget),
            stream: true,
            temperature: route.temperature)
    }

    /// A video already uploaded to the endpoint's Files API (`OpenRouterClient.uploadVideo`), then a question about
    /// it, in one user message and no system message: how the speakers of a call made from a video are told apart by
    /// their tiles (`CallVideoNames`). `processing` is how Vertex looks at it ("agentic": it looks where it needs to,
    /// for a fraction of what reading every frame costs). Streamed, thinking at `effort` with its reasoning included,
    /// as the app's other requests. Only the user's endpoint takes it: OpenRouter has no files to point at.
    static func video(model: String, fileURI: String, processing: String, text: String, effort: ReasoningEffort,
                      maxTokens: Int) -> OpenRouterChatRequest {
        OpenRouterChatRequest(
            model: model,
            messages: [.userVideo(uri: fileURI, processing: processing, text: text)],
            reasoning: Reasoning(effort: effort.rawValue, exclude: false),
            provider: nil,
            maxTokens: maxTokens,
            stream: true)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Base64 is full of "/"; the default encoder would send every one as "\/".
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Where a text request (`OpenRouterChatRequest.text`, Polish Selection's) goes and how hard the model thinks, and
/// how such a request is sized and read.
struct TextRoute: Equatable, Sendable {
    var model: String
    var provider: OpenRouterChatRequest.Provider
    /// `reasoning.effort` as sent.
    var effort: String
    /// The level `max_tokens` is sized for (`maxTokens`).
    var budget: ReasoningEffort
    /// Its thinking streams in, as a Gemini transcription's does (Polish Selection's Gemini): the answer has started
    /// with its first thought, and the pill counts them. Off, the model's first word is the start, which a thinking
    /// model reaches only after all of its thinking.
    var streamsReasoning = false
    /// The model's default when nil.
    var temperature: Double?

    init(model: String, effort: ReasoningEffort, provider: OpenRouterChatRequest.Provider) {
        self.init(model: model, provider: provider, effort: effort.rawValue, budget: effort)
    }

    init(model: String, provider: OpenRouterChatRequest.Provider, effort: String, budget: ReasoningEffort) {
        self.model = model
        self.provider = provider
        self.effort = effort
        self.budget = budget
    }

    /// How long a text request waits for its answer to start, and how long its stream may then go without a byte:
    /// 12 s, plus about 1 s per 200 characters of text, with no cap (60,000 characters get 312 s). An answer that
    /// streams is never cut off for taking long.
    static func timeout(forCharacterCount count: Int) -> TimeInterval {
        12 + Double(max(0, count)) / 200
    }

    /// `max_tokens` for `count` characters of text. Reasoning counts against it, and every request in flight reserves
    /// it from OpenRouter's in-flight budget, so it grows with the text instead of being huge: about two characters
    /// per token (a pessimistic figure for Cyrillic) doubled for slack, plus room to think. No thinking gets the room
    /// of minimal. At most 128,000.
    static func maxTokens(forCharacterCount count: Int, effort: ReasoningEffort) -> Int {
        let headroom = switch effort {
        case .off, .minimal: 1_024
        case .low: 2_048
        case .medium: 8_192
        case .high: 16_384
        }
        return min(128_000, max(4_096, max(0, count) + headroom))
    }

    /// The text goes to the model as data inside tags, so a sentence like "Can you remove…" reads as text to work on,
    /// not as a request.
    static func userMessage(for text: String) -> String {
        "<transcript>\n\(text)\n</transcript>"
    }

    /// The model's answer without anything it may have wrapped around the text: the transcript tags, a code fence,
    /// surrounding quotes.
    static func answerText(from reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            text = String(text.dropFirst(3).dropLast(3))
            if let newline = text.firstIndex(of: "\n"), !text[..<newline].contains(" ") {
                text = String(text[text.index(after: newline)...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("<transcript>") { text = String(text.dropFirst("<transcript>".count)) }
        if text.hasSuffix("</transcript>") { text = String(text.dropLast("</transcript>".count)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("«", "»")]
        where text.count >= 2 && text.hasPrefix(open) && text.hasSuffix(close)
            && !text.dropFirst().dropLast().contains(where: { String($0) == open || String($0) == close }) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

enum OpenRouterMessage: Encodable, Equatable {
    case system(String)
    /// Plain text from the user (the text Polish Selection works on).
    case user(String)
    case userAudio(base64: String, format: String)
    /// Several audio parts in one user message, in order, and no text: a call's voice sample, then the call
    /// (`OpenRouterChatRequest.transcription(voiceSampleBase64:)`).
    case userAudioParts([AudioClip])
    /// A video by its uploaded file's `uri`, then `text` about it (`OpenRouterChatRequest.video`).
    case userVideo(uri: String, processing: String, text: String)

    struct AudioClip: Equatable, Sendable {
        let base64: String
        let format: String
    }

    private struct AudioPart: Encodable {
        let type = "input_audio"
        let inputAudio: Payload
        struct Payload: Encodable { let data: String; let format: String }
        enum CodingKeys: String, CodingKey { case type, inputAudio = "input_audio" }
    }

    private struct VideoPart: Encodable {
        let type = "video_url"
        let videoURL: Payload
        struct Payload: Encodable { let url: String; let processing: String }
        enum CodingKeys: String, CodingKey { case type, videoURL = "video_url" }
    }

    private struct TextPart: Encodable {
        let type = "text"
        let text: String
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
        case .userAudioParts(let clips):
            try container.encode("user", forKey: .role)
            try container.encode(clips.map { AudioPart(inputAudio: .init(data: $0.base64, format: $0.format)) },
                                 forKey: .content)
        case .userVideo(let uri, let processing, let text):
            try container.encode("user", forKey: .role)
            var parts = container.nestedUnkeyedContainer(forKey: .content)
            try parts.encode(VideoPart(videoURL: .init(url: uri, processing: processing)))
            try parts.encode(TextPart(text: text))
        }
    }
}

// MARK: Response

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
    /// returned as is: Gemini heard no speech. With `keepTruncated`, an answer cut off by its token limit is returned
    /// as is too (finish reason "length"), with what it cost, for a caller that reads what it can of it.
    func result(engine: EngineID, keepTruncated: Bool = false) throws -> CloudResult {
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
            if !keepTruncated { throw AppError.openRouterTruncated(text) }
        default:
            break
        }
        if text.isEmpty, !refusal.isEmpty { throw AppError.openRouterRefused(refusal) }
        return CloudResult(text: text, provider: provider, costUSD: usage?.cost, usage: usage?.tokens,
                           generationID: id, model: model, finishReason: finishReason,
                           generationTime: metadata?.generationTime.map { $0 / 1000 }, serviceTier: serviceTier,
                           reasoningCharacters: progress.reasoningCharacters > 0 ? progress.reasoningCharacters : nil)
    }

    /// What a failed stream said, for the log: its finish reasons, the error it carried in the provider's own words,
    /// how far the answer got and the generation to look up. Never the answer's text.
    var failureSummary: String {
        var parts: [String] = []
        if let finishReason {
            parts.append("finish \(finishReason)" + (nativeFinishReason.map { " (native \($0))" } ?? ""))
        } else if let nativeFinishReason {
            parts.append("native finish \(nativeFinishReason)")
        }
        if let error { parts.append(error.logSummary) }
        parts.append("\(progress.reasoningCharacters) reasoning and \(progress.outputCharacters) text characters")
        parts.append(isDone ? "ended with [DONE]" : "no [DONE]")
        if let provider { parts.append("provider \(provider)") }
        if let id { parts.append("generation \(id)") }
        return parts.joined(separator: "; ")
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

    /// The error for the log: its code, message, type, provider and the provider's own words. Only these fields:
    /// a moderation error's `flagged_input` quotes the request (a transcript being cleaned up).
    var logSummary: String {
        let code = switch code {
        case .int(let value)?: String(value)
        case .string(let value)?: value
        case nil: "no code"
        }
        var said = "error \(code): \(message ?? "no message")"
        if let type = metadata?.errorType { said += " [\(type)]" }
        if let name = metadata?.providerName { said += " from \(name)" }
        if let raw = metadata?.raw {
            said += ", raw: " + raw.prefix(600).split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        return said
    }

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
        /// The provider's own error, as it sent it (Google's JSON inside a string); nil when it isn't a string.
        let raw: String?
        enum CodingKeys: String, CodingKey {
            case errorType = "error_type", limitSource = "limit_source", providerName = "provider_name", raw
        }

        init(errorType: String? = nil, limitSource: String? = nil, providerName: String? = nil, raw: String? = nil) {
            self.errorType = errorType
            self.limitSource = limitSource
            self.providerName = providerName
            self.raw = raw
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
            limitSource = try container.decodeIfPresent(String.self, forKey: .limitSource)
            providerName = try container.decodeIfPresent(String.self, forKey: .providerName)
            // Some providers' raw error is an object: it never makes the whole error unreadable.
            raw = try? container.decodeIfPresent(String.self, forKey: .raw)
        }
    }
}

/// Gemini puts the transcript between `<transcript>` tags (`EngineID.geminiSystemPrompt`). Once in a while it writes
/// its thinking into the answer instead of its reasoning, drafts in tags included: the transcript is what the last
/// pair holds. An answer without tags (a prompt that doesn't ask for them) is the transcript as it is, out of the code
/// fence it may come in.
/// Two slips never lose what was said: an answer in the other tags the app asks for (`<message>` where `<transcript>`
/// was asked, or the reverse) is read from those, and a lone pair left empty with the words written outside it
/// (`rescueMinimumCharacters` of them, and not a remark that there was no speech) gives those words.
enum TaggedTranscript {
    static let open = "<transcript>"
    static let close = "</transcript>"
    /// Polish's tags (`Polish.open`, `Polish.close`).
    static let messageOpen = "<message>"
    static let messageClose = "</message>"

    /// What the answer had: one pair, more than one (thinking in the answer), only an opening tag (cut short), none,
    /// the other tags the app asks for (`other`), or an empty pair with the answer written outside it (`outside`).
    /// Raw values go to the diagnostic log.
    enum Tags: String, Sendable, Equatable {
        case pair, several, unclosed, none, other, outside
    }

    /// Text outside an empty pair shorter than this is taken for a remark, not for what was said.
    static let rescueMinimumCharacters = 20

    /// The text of the last `open`…`close` pair (`Polish` reads its `<message>` tags the same way).
    static func extract(_ answer: String, open: String = open, close: String = close) -> (text: String, tags: Tags) {
        if let found = extractPair(answer, open: open, close: close) {
            if found.text.isEmpty, found.tags == .pair, let words = wordsOutside(answer) { return (words, .outside) }
            return found
        }
        let asksForMessage = open.caseInsensitiveCompare(messageOpen) == .orderedSame
        let (otherOpen, otherClose) = asksForMessage ? (Self.open, Self.close) : (messageOpen, messageClose)
        if let other = extractPair(answer, open: otherOpen, close: otherClose) { return (other.text, .other) }
        // A call's "no speech" (`CallTranscriber.noSpeech`) where a dictation's empty tags were asked for.
        if isNoSpeechLiteral(answer) { return ("", .none) }
        return (unfenced(answer), .none)
    }

    /// Only the words "NO SPEECH", in any case, with any punctuation around them.
    static func isNoSpeechLiteral(_ answer: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .caseInsensitiveCompare("NO SPEECH") == .orderedSame
    }

    /// The last pair's text; nil when the answer has neither tag.
    private static func extractPair(_ answer: String, open: String, close: String) -> (text: String, tags: Tags)? {
        let opens = ranges(of: open, in: answer), closes = ranges(of: close, in: answer)
        let several = opens.count > 1 || closes.count > 1
        if let closing = closes.last {
            let start = opens.last { $0.upperBound <= closing.lowerBound }?.upperBound ?? answer.startIndex
            return (trimmed(answer[start..<closing.lowerBound]), several ? .several : .pair)
        }
        if let opening = opens.last { return (trimmed(answer[opening.upperBound...]), .unclosed) }
        return nil
    }

    /// What an answer holding one empty pair wrote outside it, when that reads as the transcript: long enough, and
    /// not a remark about the audio. nil otherwise.
    private static func wordsOutside(_ answer: String) -> String? {
        let words = unfenced(stripped(answer))
        guard words.count >= rescueMinimumCharacters, !isRemark(words) else { return nil }
        return words
    }

    /// Words a model uses to say what it heard instead of speech, in English and Russian (lowercased).
    static let remarkMarkers = ["speech", "audible", "intelligible", "silence", "silent", "noise", "background",
                                "voices", "dictation", "audio", "empty tags",
                                "речи", "речь", "слыш", "неразборчив", "тишин", "шум", "чужие голос", "чужой голос",
                                "диктовк", "аудио", "пустые теги"]

    /// A short remark about the audio ("Only background noise, no speech."), not something the user said.
    static func isRemark(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return text.count < 200 && remarkMarkers.contains(where: lowered.contains)
    }

    /// `answer` without any of the tags the app asks for, trimmed.
    static func stripped(_ answer: String) -> String {
        var text = answer
        for tag in [open, close, messageOpen, messageClose] {
            text = text.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text inside a Markdown code fence that wraps the whole answer ("```" or "```text" on the first line, "```"
    /// at the end), trimmed; anything else as it is.
    static func unfenced(_ answer: String) -> String {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6, text.hasPrefix("```"), text.hasSuffix("```"),
              let firstBreak = text.firstIndex(of: "\n") else { return answer }
        let end = text.index(text.endIndex, offsetBy: -3)
        guard firstBreak < end else { return answer }
        return trimmed(text[text.index(after: firstBreak)..<end])
    }

    /// How a model's answer looked, for the diagnostic log: sizes and flags, never its words.
    struct Shape: Equatable, Sendable {
        /// Characters in the whole answer, tags and all.
        var characters: Int
        var hasTranscriptTags: Bool
        var hasMessageTags: Bool
        /// Tags and nothing in or around them (white space and a code fence aside): the model's "no speech".
        var isOnlyTags: Bool
        /// Only the words "NO SPEECH" (what a call's prompt asks for when there is none).
        var isNoSpeechLiteral: Bool
        /// Characters before the first tag and after the last; nil without tags.
        var charactersOutsideTags: Int?
    }

    static func shape(of answer: String) -> Shape {
        let lowered = answer.lowercased()
        let hasTranscript = lowered.contains(open) || lowered.contains(close)
        let hasMessage = lowered.contains(messageOpen) || lowered.contains(messageClose)
        let tagged = hasTranscript || hasMessage
        return Shape(characters: answer.count, hasTranscriptTags: hasTranscript, hasMessageTags: hasMessage,
                     isOnlyTags: tagged && unfenced(stripped(answer)).isEmpty,
                     isNoSpeechLiteral: isNoSpeechLiteral(answer),
                     charactersOutsideTags: tagged ? outsideCount(answer) : nil)
    }

    /// Characters of `answer` before its first tag and after its last one (of either pair), trimmed.
    private static func outsideCount(_ answer: String) -> Int {
        let tags = [open, close, messageOpen, messageClose].flatMap { ranges(of: $0, in: answer) }
        guard let first = tags.map(\.lowerBound).min(), let last = tags.map(\.upperBound).max() else { return 0 }
        return trimmed(answer[..<first]).count + trimmed(answer[last...]).count
    }

    private static func ranges(of tag: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while let range = text.range(of: tag, options: .caseInsensitive, range: from..<text.endIndex) {
            found.append(range)
            from = range.upperBound
        }
        return found
    }

    private static func trimmed(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// How a 400 says the request is too large to take (lowercased).
    static let tooLargePhrases = ["payload size", "request entity too large", "request too large"]

    /// How providers say they serve no requests from the user's country (lowercased): Google's "User location is
    /// not supported for the API use.", OpenAI's `unsupported_country_region_territory`.
    static let regionBlockPhrases = ["user location is not supported", "location is not supported for the api",
                                     "unsupported_country_region_territory",
                                     "country, region, or territory not supported",
                                     "not available in your region", "not available in your country",
                                     "not supported in your region", "not supported in your country"]

    static func isRegionBlock(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return regionBlockPhrases.contains(where: lowered.contains)
    }

    /// OpenRouter's Cloudflare turning the connection away before OpenRouter sees it: its JSON (`{"success": false,
    /// "error": "Access denied by security policy."}`) or a 403 block page.
    static func isFirewallBlock(status: Int, text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("access denied by security policy") { return true }
        let isPage = lowered.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
        return status == 403 && isPage && lowered.contains("cloudflare")
    }

    /// A readable sentence from an error body that isn't OpenRouter's: a JSON object's `error`, `message` or
    /// `detail` (or `error.message`), plain text as it is, and nothing from HTML or other JSON.
    static func plainMessage(from data: Data) -> String {
        let text = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let nested = (object["error"] as? [String: Any])?["message"]
            for value in [object["error"], object["message"], object["detail"], nested] {
                if let message = value as? String, !message.isEmpty { return message }
            }
            return ""
        }
        if text.hasPrefix("<") || text.hasPrefix("{") || text.hasPrefix("[") { return "" }
        return String(text.prefix(300))
    }

    /// Maps a non-200 response (body may be JSON, HTML or empty).
    static func httpError(status: Int, data: Data, retryAfter: Double?, engine: EngineID) -> AppError {
        // Wherever in the body it says so (the provider's error is JSON inside a string), in any status.
        let text = String(decoding: data.prefix(16 * 1024), as: UTF8.self)
        if isRegionBlock(text) { return .regionBlocked }
        if isFirewallBlock(status: status, text: text) { return .connectionBlocked }
        if let envelope = try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: data) {
            return map(envelope.error, status: status, retryAfter: retryAfter, engine: engine)
        }
        return map(status: status, message: plainMessage(from: data), errorType: nil, retryAfter: retryAfter, engine: engine)
    }

    /// Maps an error object (top level or inside a choice). `status` is the HTTP status, used when the object
    /// carries no numeric code.
    static func map(_ body: OpenRouterAPIError, status: Int, retryAfter: Double?, engine: EngineID) -> AppError {
        if isRegionBlock([body.message, body.metadata?.raw].compactMap { $0 }.joined(separator: " ")) {
            return .regionBlocked
        }
        return map(status: body.code?.intValue ?? status, message: body.message ?? "",
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

        // A request too large to take, reported as a bad request. Only these phrases: a text request's errors come
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

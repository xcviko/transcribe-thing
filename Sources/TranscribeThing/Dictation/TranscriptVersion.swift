import Foundation

/// What wrote a transcript of a recording: an engine hearing the audio, or a clean-up model tidying the text an
/// engine wrote. An entry has at most one version of each kind, so the same model never runs twice on a recording
/// (each clean-up model can tidy the same text once).
enum TranscriptVersionKind: Hashable, Sendable, Codable {
    case transcription(EngineID)
    /// `model` over the text of `.transcription(engine)`. Versions from before the choice of clean-up model are
    /// Flash Lite's, hence the default.
    case cleanup(of: EngineID, by: CleanupModel = .geminiFlashLite)

    /// The engine that heard the audio (for a clean-up, the one whose text was tidied).
    var engine: EngineID {
        switch self {
        case .transcription(let engine), .cleanup(let engine, _): engine
        }
    }

    var isCleanup: Bool {
        if case .cleanup = self { true } else { false }
    }

    /// Builds from before the choice of clean-up model read it: a transcription, or a clean-up by Flash Lite. A
    /// clean-up by another model has the model in its raw value, which they can't read.
    var isReadableByOlderBuilds: Bool {
        cleanupModel.map { $0 == .geminiFlashLite } ?? true
    }

    /// The model that tidied the text; nil for a transcription.
    var cleanupModel: CleanupModel? {
        if case .cleanup(_, let model) = self { model } else { nil }
    }

    /// "Parakeet v3", "Parakeet v3 + Clean-up by GPT-6 Luna".
    var displayName: String {
        switch self {
        case .transcription(let engine): engine.displayName
        case .cleanup(let engine, let model): "\(engine.displayName) + Clean-up by \(model.shortName)"
        }
    }

    /// "Gemini Flash", "Parakeet v3 + Clean-up".
    var shortName: String {
        switch self {
        case .transcription(let engine): engine.shortName
        case .cleanup(let engine, _): "\(engine.shortName) + Clean-up"
        }
    }

    /// What is under way while it's being made: "Transcribing with Gemini Flash…", "Cleaning up with Flash Lite…".
    var progressTitle: String {
        switch self {
        case .transcription(let engine): "Transcribing with \(engine.shortName)…"
        case .cleanup(_, let model): "Cleaning up with \(model.shortName)…"
        }
    }

    /// Persisted: "parakeet", "cleanup:parakeet" (Flash Lite's, as older builds wrote it),
    /// "cleanup:parakeet:gpt6Luna". Never rename. An older build can't read a kind with a model and drops that
    /// version, not the entry (`TranscriptEntry.encode(to:)` keeps the text it tidied intact for them).
    var rawValue: String {
        switch self {
        case .transcription(let engine): engine.rawValue
        case .cleanup(let engine, .geminiFlashLite): "cleanup:\(engine.rawValue)"
        case .cleanup(let engine, let model): "cleanup:\(engine.rawValue):\(model.rawValue)"
        }
    }

    /// Retired engines read as their successors (`TranscriptEntry.retiredEngines`); nil for an engine or a
    /// clean-up model this build doesn't know.
    init?(rawValue: String) {
        func engine(_ raw: Substring) -> EngineID? {
            EngineID(rawValue: String(raw)) ?? TranscriptEntry.retiredEngines[String(raw)]
        }
        if rawValue.hasPrefix("cleanup:") {
            let parts = rawValue.dropFirst("cleanup:".count).split(separator: ":", maxSplits: 1,
                                                                   omittingEmptySubsequences: false)
            guard let source = engine(parts[0]) else { return nil }
            if parts.count == 1 {
                self = .cleanup(of: source, by: .geminiFlashLite)
            } else {
                guard let model = CleanupModel(rawValue: String(parts[1])) else { return nil }
                self = .cleanup(of: source, by: model)
            }
        } else {
            guard let source = engine(Substring(rawValue)) else { return nil }
            self = .transcription(source)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let kind = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown version \(raw)")
        }
        self = kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How a transcript came about: which model and provider, what it cost, how long it took and how much it thought.
/// Every field but `createdAt` is optional: local transcripts have no tokens or cost, and older history files
/// recorded only cost, provider and processing time.
struct TranscriptMetadata: Codable, Equatable, Sendable {
    /// When this version was made.
    var createdAt: Date
    /// The OpenRouter model slug ("google/gemini-3.8-flash"); nil for the local model.
    var modelID: String?
    /// The OpenRouter provider that served it ("Google AI Studio", "Together").
    var provider: String?
    var generationID: String?
    /// The level the model was asked to think at; nil for models that don't reason.
    var reasoningEffort: ReasoningEffort?
    var usage: TokenUsage?
    var costUSD: Double?
    /// Wall clock on this Mac: for a transcription from the end of recording to the text (encoding and any wait
    /// for the model included), for a clean-up the request alone.
    var processingTime: TimeInterval?
    /// Until the first word of the answer. Only a streamed request can tell, and none is streamed today.
    var timeToFirstToken: TimeInterval?
    /// Seconds OpenRouter measured for the generation itself.
    var generationTime: TimeInterval?
    /// OpenRouter's `latency` for the generation, in seconds (its meaning is unverified; see
    /// `OpenRouterGeneration.latency`).
    var latency: TimeInterval?
    /// A system prompt went with the request (Gemini's own prompt, the clean-up prompt).
    var usedSystemPrompt: Bool?
    var finishReason: String?
    /// Seconds of audio billed by OpenRouter's speech endpoint.
    var audioSeconds: Double?

    init(createdAt: Date = Date(), modelID: String? = nil, provider: String? = nil, generationID: String? = nil,
         reasoningEffort: ReasoningEffort? = nil, usage: TokenUsage? = nil, costUSD: Double? = nil,
         processingTime: TimeInterval? = nil, timeToFirstToken: TimeInterval? = nil,
         generationTime: TimeInterval? = nil, latency: TimeInterval? = nil, usedSystemPrompt: Bool? = nil,
         finishReason: String? = nil, audioSeconds: Double? = nil) {
        self.createdAt = createdAt
        self.modelID = modelID
        self.provider = provider
        self.generationID = generationID
        self.reasoningEffort = reasoningEffort
        self.usage = usage
        self.costUSD = costUSD
        self.processingTime = processingTime
        self.timeToFirstToken = timeToFirstToken
        self.generationTime = generationTime
        self.latency = latency
        self.usedSystemPrompt = usedSystemPrompt
        self.finishReason = finishReason
        self.audioSeconds = audioSeconds
    }

    /// Lenient: a field this build can't read (a reasoning level from a newer build) is dropped, not the version.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        modelID = try? c.decodeIfPresent(String.self, forKey: .modelID)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        generationID = try? c.decodeIfPresent(String.self, forKey: .generationID)
        reasoningEffort = try? c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        usage = try? c.decodeIfPresent(TokenUsage.self, forKey: .usage)
        costUSD = try? c.decodeIfPresent(Double.self, forKey: .costUSD)
        processingTime = try? c.decodeIfPresent(TimeInterval.self, forKey: .processingTime)
        timeToFirstToken = try? c.decodeIfPresent(TimeInterval.self, forKey: .timeToFirstToken)
        generationTime = try? c.decodeIfPresent(TimeInterval.self, forKey: .generationTime)
        latency = try? c.decodeIfPresent(TimeInterval.self, forKey: .latency)
        usedSystemPrompt = try? c.decodeIfPresent(Bool.self, forKey: .usedSystemPrompt)
        finishReason = try? c.decodeIfPresent(String.self, forKey: .finishReason)
        audioSeconds = try? c.decodeIfPresent(Double.self, forKey: .audioSeconds)
    }

    /// A compact line for a menu item: "76 s · $0.07 · 17.7k thinking", "0.4 s". Empty when nothing is known.
    var summary: String {
        var parts: [String] = []
        if let processingTime { parts.append(Fmt.seconds(processingTime)) }
        if let costUSD, costUSD > 0 { parts.append(Fmt.usd(costUSD)) }
        if let reasoning = usage?.reasoningTokens, reasoning > 0 { parts.append("\(Fmt.tokens(reasoning)) thinking") }
        return parts.joined(separator: " · ")
    }
}

/// One transcript of an entry's recording: its text, what wrote it and how (`metadata`).
struct TranscriptVersion: Codable, Equatable, Identifiable, Sendable {
    var kind: TranscriptVersionKind
    var text: String
    var metadata: TranscriptMetadata

    var id: TranscriptVersionKind { kind }
    var engine: EngineID { kind.engine }
    var provider: String? { metadata.provider }
    var costUSD: Double? { metadata.costUSD }
    var processingTime: TimeInterval? { metadata.processingTime }

    init(kind: TranscriptVersionKind, text: String, metadata: TranscriptMetadata) {
        self.kind = kind
        self.text = text
        self.metadata = metadata
    }

    /// A transcription by `engine` with just the facts older builds recorded.
    init(text: String, engine: EngineID, provider: String? = nil, costUSD: Double? = nil,
         processingTime: TimeInterval? = nil, createdAt: Date = Date()) {
        self.init(kind: .transcription(engine), text: text,
                  metadata: TranscriptMetadata(createdAt: createdAt, provider: provider, costUSD: costUSD,
                                               processingTime: processingTime))
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, metadata
        // The shape older builds wrote as an entry's `previous`.
        case engine, provider, costUSD, processingTime
    }

    /// Reads both shapes: `{kind, text, metadata}`, and the `{text, engine, provider, costUSD, processingTime}` an
    /// older build wrote as `previous` (its date unknown: `legacyDate`, set by the entry decoding it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        if c.contains(.kind) {
            kind = try c.decode(TranscriptVersionKind.self, forKey: .kind)
            metadata = try c.decodeIfPresent(TranscriptMetadata.self, forKey: .metadata)
                ?? TranscriptMetadata(createdAt: Date(timeIntervalSince1970: 0))
        } else {
            kind = .transcription(try TranscriptEntry.decodeEngine(from: c, forKey: .engine))
            metadata = TranscriptMetadata(createdAt: Self.legacyDate,
                                          provider: try c.decodeIfPresent(String.self, forKey: .provider),
                                          costUSD: try c.decodeIfPresent(Double.self, forKey: .costUSD),
                                          processingTime: try c.decodeIfPresent(TimeInterval.self, forKey: .processingTime))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encode(metadata, forKey: .metadata)
    }

    /// Stands in for the unknown date of a version read in the old shape; the entry replaces it with its own.
    static let legacyDate = Date(timeIntervalSince1970: 0)
}

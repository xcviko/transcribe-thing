import Foundation

struct TranscriptResult: Sendable, Equatable {
    /// Trimmed. Empty when the engine heard no speech: silence, not a failure.
    var text: String
    var engine: EngineID
    var processingTime: TimeInterval
    var costUSD: Double?
    /// The OpenRouter provider that served it, when the response said so. Otherwise look it up with
    /// `TranscriptionService.servedProvider(generationID:)` once the result is delivered.
    var provider: String? = nil
    /// OpenRouter generation id of the request behind this result.
    var generationID: String? = nil
    /// The OpenRouter model slug; nil for the local model.
    var modelID: String? = nil
    /// The level Gemini was asked to think at; nil for models that don't reason.
    var reasoningEffort: ReasoningEffort? = nil
    var usage: TokenUsage? = nil
    /// A system prompt went with the request; nil for the local model.
    var usedSystemPrompt: Bool? = nil
    var finishReason: String? = nil
    /// Seconds OpenRouter measured for the generation.
    var generationTime: TimeInterval? = nil
    /// Seconds of audio the speech endpoint billed.
    var audioSeconds: Double? = nil
    /// The chat response's `service_tier`, when it names one (set by clean-up only; not kept in history).
    var serviceTier: String? = nil

    /// Everything known about how this result came about, for its history version.
    func metadata(createdAt: Date = Date()) -> TranscriptMetadata {
        TranscriptMetadata(createdAt: createdAt, modelID: modelID, provider: provider, generationID: generationID,
                           reasoningEffort: reasoningEffort, usage: usage, costUSD: costUSD,
                           processingTime: processingTime, generationTime: generationTime,
                           usedSystemPrompt: usedSystemPrompt, finishReason: finishReason, audioSeconds: audioSeconds)
    }

    /// This result as a history version of `kind` (a transcription by its engine unless said otherwise).
    func version(_ kind: TranscriptVersionKind? = nil, text: String? = nil, createdAt: Date = Date()) -> TranscriptVersion {
        TranscriptVersion(kind: kind ?? .transcription(engine), text: text ?? self.text,
                          metadata: metadata(createdAt: createdAt))
    }
}

/// Routes a recording to the local model, Gemini, or OpenRouter speech-to-text, and returns trimmed text. An engine
/// that answers with no text heard no speech, so that comes back as an empty result, never as an error.
@MainActor
final class TranscriptionService {
    private let models: ModelStore
    private let account: OpenRouterAccount
    private let client: OpenRouterClient
    private let settings: AppSettings
    private let providerLookupDelay: Duration

    init(models: ModelStore, account: OpenRouterAccount, client: OpenRouterClient, settings: AppSettings,
         providerLookupDelay: Duration = .milliseconds(1500)) {
        self.models = models
        self.account = account
        self.client = client
        self.settings = settings
        self.providerLookupDelay = providerLookupDelay
    }

    /// Throws `AppError` only, or `CancellationError` when the calling task is cancelled.
    /// `processingTime` covers everything after the recording ended, including any wait for the model.
    func transcribe(_ recording: Recording, engine: EngineID) async throws -> TranscriptResult {
        let started = ContinuousClock.now
        do {
            var result = TranscriptResult(text: "", engine: engine, processingTime: 0)
            if engine.isLocal {
                result.text = try await models.transcribeLocal(engine, samples: recording.samples)
            } else {
                // Read now: the request uses these, whatever Settings says by the time it's answered.
                let effort = settings.reasoningEffort(for: engine)
                let prompt = engine.cloudAPI == .chatCompletions ? settings.geminiSystemPrompt : ""
                let cloud = try await transcribeCloud(recording.samples, engine: engine, effort: effort, prompt: prompt)
                result.text = cloud.text
                result.costUSD = cloud.costUSD
                result.provider = cloud.provider
                result.generationID = cloud.generationID
                result.modelID = cloud.model ?? engine.openRouterModelID
                result.reasoningEffort = effort
                result.usage = cloud.usage
                result.usedSystemPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                result.finishReason = cloud.finishReason
                result.generationTime = cloud.generationTime
                result.audioSeconds = cloud.audioSeconds
            }
            result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.processingTime = Self.seconds(started.duration(to: .now))
            return result
        } catch let error as AppError {
            Log.engine.error("\(engine.rawValue, privacy: .public) failed: \(error.code, privacy: .public)")
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Log.engine.error("\(engine.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw AppError.engineFailed(engine, ModelStore.oneLine(error))
        }
    }

    private func transcribeCloud(_ samples: [Float], engine: EngineID, effort: ReasoningEffort?,
                                 prompt: String) async throws -> CloudResult {
        guard let model = engine.openRouterModelID, let api = engine.cloudAPI else {
            throw AppError.engineFailed(engine, "No cloud model for \(engine.displayName).")
        }
        guard let key = account.apiKey() else {
            throw account.isKeyUnreadable ? AppError.openRouterKeyUnreadable : AppError.openRouterMissingKey
        }
        do {
            let result: CloudResult
            switch api {
            case .chatCompletions:
                result = try await transcribeWithChat(samples, engine: engine, model: model, key: key,
                                                      effort: effort ?? .high, prompt: prompt)
            case .transcriptions:
                result = try await transcribeSpeech(samples, engine: engine, model: model, key: key)
            }
            account.noteCloudSuccess()
            return result
        } catch let error as AppError {
            account.noteCloudFailure(error)
            throw error
        }
    }

    /// Gemini: the whole recording in one request, with the user's system prompt.
    private func transcribeWithChat(_ samples: [Float], engine: EngineID, model: String, key: String,
                                    effort: ReasoningEffort, prompt: String) async throws -> CloudResult {
        // Refuse before spending time encoding a recording that can't be sent (the recording limit for Gemini
        // normally stops it well before this).
        let wavBytes = 44 + samples.count * 2
        guard OpenRouterClient.base64Length(ofByteCount: wavBytes) <= OpenRouterClient.maxBase64Bytes else {
            throw AppError.recordingTooLarge
        }
        let wav = await Task.detached(priority: .userInitiated) { WAVEncoder.pcm16(samples) }.value
        return try await client.transcribe(wav: wav, model: model, systemPrompt: prompt, effort: effort,
                                           apiKey: key, timeout: engine.cloudTimeout)
    }

    /// Parakeet over the speech-to-text endpoint: the whole recording in one request. The Gemini system prompt
    /// doesn't apply, and no language is sent: Parakeet v3 detects it.
    private func transcribeSpeech(_ samples: [Float], engine: EngineID, model: String,
                                  key: String) async throws -> CloudResult {
        let wav = await Task.detached(priority: .userInitiated) { WAVEncoder.pcm16(samples) }.value
        try Task.checkCancellation()
        return try await client.transcribeSpeech(wav: wav, model: model, apiKey: key, timeout: engine.cloudTimeout)
    }

    // MARK: Clean-up

    /// Tidies `transcript` (written by `source`) with the clean-up model `model` (by default the selected one),
    /// following the clean-up prompt at that model's reasoning level. The result is a version of kind
    /// `.cleanup(of: source, by: model)`; its text is empty when the model returned nothing. Gives up after
    /// `timeout` (by default `CleanupModel.timeout(forCharacterCount:)`) with `AppError.timeout`. Throws `AppError`
    /// only, or `CancellationError`.
    /// `route` sends it to any other model instead, at the route's effort (`EngineCLI --cleanup-bench`); the app
    /// never passes one.
    func cleanUp(_ transcript: String, of source: EngineID, by model: CleanupModel? = nil, timeout: TimeInterval? = nil,
                 route: CleanupRoute? = nil) async throws -> TranscriptResult {
        let prompt = settings.cleanupSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // With no instruction the model would reply to the transcript instead of tidying it.
        guard !prompt.isEmpty else { throw AppError.engineFailed(source, "The clean-up prompt is empty.") }
        guard let key = account.apiKey() else {
            throw account.isKeyUnreadable ? AppError.openRouterKeyUnreadable : AppError.openRouterMissingKey
        }
        let model = model ?? settings.cleanupModel
        let route = route ?? model.route(effort: settings.cleanupReasoningEffort(for: model))
        let effort = route.level
        let limit = timeout ?? CleanupModel.timeout(forCharacterCount: transcript.count)
        let client = client
        let started = ContinuousClock.now
        do {
            let cloud = try await Self.withTimeout(limit, source: source) {
                try await client.cleanUp(transcript: transcript, route: route, systemPrompt: prompt, apiKey: key,
                                         timeout: limit)
            }
            account.noteCloudSuccess()
            var result = TranscriptResult(text: cloud.text, engine: source,
                                          processingTime: Self.seconds(started.duration(to: .now)))
            result.costUSD = cloud.costUSD
            result.provider = cloud.provider
            result.generationID = cloud.generationID
            result.modelID = cloud.model ?? route.model
            result.reasoningEffort = effort
            result.usage = cloud.usage
            result.usedSystemPrompt = true
            result.finishReason = cloud.finishReason
            result.generationTime = cloud.generationTime
            result.serviceTier = cloud.serviceTier
            return result
        } catch let error as AppError {
            account.noteCloudFailure(error)
            Log.engine.error("Clean-up failed: \(error.code, privacy: .public)")
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AppError.engineFailed(source, ModelStore.oneLine(error))
        }
    }

    /// `work`, or `AppError.timeout(source)` once `seconds` pass (the request is cancelled then).
    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, source: EngineID,
                                                 _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw AppError.timeout(source) }
            return value
        }
    }

    // MARK: Generation record

    /// Who served a delivered cloud result, from OpenRouter's generation record ("Together"). A generation OpenRouter
    /// hasn't recorded yet is asked for once more after a short wait. nil when nothing could be learned; never
    /// throws.
    func servedProvider(generationID: String) async -> String? {
        await generationDetails(generationID: generationID)?.provider
    }

    /// OpenRouter's record of a delivered cloud result: provider, cost, timing. A generation OpenRouter hasn't
    /// recorded yet (or that names no provider yet) is asked for once more after a short wait. nil when nothing
    /// could be learned; never throws.
    func generationDetails(generationID: String) async -> GenerationDetails? {
        guard let key = account.apiKey() else { return nil }
        var found: GenerationDetails?
        for attempt in 0..<2 {
            if attempt > 0 {
                do { try await Task.sleep(for: providerLookupDelay) } catch { return found }
            }
            do {
                if let details = try await client.generationDetails(id: generationID, apiKey: key) {
                    found = details
                    if details.provider != nil { return details }
                }
            } catch {
                if !(error is CancellationError) {
                    Log.net.info("Generation lookup failed: \(String(describing: error), privacy: .public)")
                }
                return found
            }
        }
        return found
    }

    nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

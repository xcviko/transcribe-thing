import Foundation
import os

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
    /// The level the model was asked to think at (Gemini, the clean-up model); nil for models that don't reason.
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
    /// Characters of reasoning the answer streamed (for Gemini, the summaries of its thoughts).
    var reasoningCharacters: Int? = nil
    /// Seconds from sending a streamed request until the first character of the answer.
    var timeToFirstToken: TimeInterval? = nil

    /// Everything known about how this result came about, for its history version.
    func metadata(createdAt: Date = Date()) -> TranscriptMetadata {
        TranscriptMetadata(createdAt: createdAt, modelID: modelID, provider: provider, generationID: generationID,
                           reasoningEffort: reasoningEffort, usage: usage, costUSD: costUSD,
                           processingTime: processingTime, timeToFirstToken: timeToFirstToken,
                           generationTime: generationTime, usedSystemPrompt: usedSystemPrompt,
                           finishReason: finishReason, audioSeconds: audioSeconds,
                           reasoningCharacters: reasoningCharacters)
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
    private let providerLookupDelay: Duration

    init(models: ModelStore, account: OpenRouterAccount, client: OpenRouterClient,
         providerLookupDelay: Duration = .milliseconds(1500)) {
        self.models = models
        self.account = account
        self.client = client
        self.providerLookupDelay = providerLookupDelay
    }

    /// Throws `AppError` only, or `CancellationError` when the calling task is cancelled. A retired model never runs.
    /// `processingTime` covers everything after the recording ended, including any wait for the model.
    /// `effort` has Gemini think at another level than its own (`EngineCLI --effort`), and `prompt` replaces its
    /// fixed `EngineID.geminiSystemPrompt` (`--prompt`; empty sends only the audio); the app never passes either.
    /// `background`: Home's work, which lets dictations have the local model first.
    /// `progress` hears how much of a streamed answer has come (Gemini's reasoning and text); Parakeet has none.
    func transcribe(_ recording: Recording, engine: EngineID, effort: ReasoningEffort? = nil,
                    prompt: String? = nil, background: Bool = false,
                    progress: (@Sendable (ChatStreamProgress) -> Void)? = nil) async throws -> TranscriptResult {
        guard !engine.isRetired else {
            throw AppError.engineFailed(engine, "\(engine.displayName) is no longer offered.")
        }
        let started = ContinuousClock.now
        do {
            var result = TranscriptResult(text: "", engine: engine, processingTime: 0)
            if engine.isLocal {
                result.text = try await models.transcribeLocal(engine, samples: recording.samples, background: background)
            } else {
                let effort = effort ?? engine.reasoningEffort
                let prompt = engine.cloudAPI == .chatCompletions ? (prompt ?? EngineID.geminiSystemPrompt) : ""
                let cloud = try await transcribeCloud(recording.samples, engine: engine, effort: effort, prompt: prompt,
                                                      progress: progress)
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
                result.reasoningCharacters = cloud.reasoningCharacters
                result.timeToFirstToken = cloud.timeToFirstToken
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

    private func transcribeCloud(_ samples: [Float], engine: EngineID, effort: ReasoningEffort?, prompt: String,
                                 progress: (@Sendable (ChatStreamProgress) -> Void)?) async throws -> CloudResult {
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
                                                      effort: effort ?? .medium, prompt: prompt, progress: progress)
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

    /// Gemini: the whole recording in one request, with its system prompt, whatever its length. Past what its WAV can
    /// carry it goes as AAC (`CloudAudio.forChat`); the answer's token budget grows with the audio, and it streams, so
    /// no wait for it has to.
    private func transcribeWithChat(_ samples: [Float], engine: EngineID, model: String, key: String,
                                    effort: ReasoningEffort, prompt: String,
                                    progress: (@Sendable (ChatStreamProgress) -> Void)?) async throws -> CloudResult {
        let encoded = await Task.detached(priority: .userInitiated) { try? CloudAudio.forChat(samples) }.value
        guard let encoded else { throw AppError.engineFailed(engine, "Couldn’t compress the recording.") }
        try Task.checkCancellation()
        let seconds = Double(samples.count) / Recording.sampleRate
        return try await client.transcribe(audio: encoded.data, format: encoded.format, model: model,
                                           systemPrompt: prompt, effort: effort,
                                           maxTokens: OpenRouterClient.transcriptionMaxTokens(audioSeconds: seconds),
                                           apiKey: key, timeout: engine.cloudTimeout, progress: progress)
    }

    /// Parakeet over the speech-to-text endpoint: a request per segment of at most 5 minutes, cut in pauses
    /// (`CloudAudio.speechSegments`; a shorter recording is one), one after another. The texts join with a space;
    /// the billed seconds and the costs add up, and the first segment's generation stands for the whole. The
    /// Gemini system prompt doesn't apply, and no language is sent: Parakeet v3 detects it.
    private func transcribeSpeech(_ samples: [Float], engine: EngineID, model: String,
                                  key: String) async throws -> CloudResult {
        let ranges = await Task.detached(priority: .userInitiated) { CloudAudio.speechSegments(samples) }.value
        var results: [CloudResult] = []
        for range in ranges {
            try Task.checkCancellation()
            let wav = await Task.detached(priority: .userInitiated) { WAVEncoder.pcm16(Array(samples[range])) }.value
            results.append(try await client.transcribeSpeech(wav: wav, model: model, apiKey: key,
                                                             timeout: engine.cloudTimeout))
        }
        return Self.joined(results)
    }

    /// Parakeet's segments as one result: the first's, with every text (trimmed, empty ones left out) joined by a
    /// space, the billed seconds and costs summed (nil when none said), and the first provider any of them named.
    private nonisolated static func joined(_ results: [CloudResult]) -> CloudResult {
        guard var combined = results.first else { return CloudResult(text: "") }
        combined.text = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        combined.audioSeconds = Self.sum(results.map(\.audioSeconds))
        combined.costUSD = Self.sum(results.map(\.costUSD))
        combined.provider = results.lazy.compactMap(\.provider).first
        return combined
    }

    private nonisolated static func sum(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    // MARK: Clean-up

    /// Tidies `transcript` (written by `source`) with the clean-up model `model`, following
    /// `CleanupModel.systemPrompt` at that model's fixed reasoning level (`CleanupModel.route`). The result is a
    /// version of kind `.cleanup(of: source, by: model)`; its text is empty when the model returned nothing. Gives up
    /// with `AppError.timeout` when the answer hasn't started within `timeout` (by default
    /// `CleanupModel.timeout(forCharacterCount:)`); once it streams, it may take as long as it keeps coming, and the
    /// same `timeout` without a byte ends it. Throws `AppError` only, or `CancellationError`. A retired model never
    /// runs.
    /// `route` sends it to any other model or level instead (`EngineCLI --cleanup-bench`, `--clean-up-effort`), and
    /// `prompt` replaces the fixed prompt (`--clean-up-prompt`); the app never passes either. `progress` hears how
    /// much of the answer has streamed in.
    func cleanUp(_ transcript: String, of source: EngineID, by model: CleanupModel = .default,
                 timeout: TimeInterval? = nil, route: CleanupRoute? = nil, prompt: String? = nil,
                 progress: (@Sendable (ChatStreamProgress) -> Void)? = nil) async throws -> TranscriptResult {
        guard let route = route ?? model.route else {
            throw AppError.engineFailed(source, "\(model.modelName) no longer cleans up.")
        }
        let prompt = (prompt ?? CleanupModel.systemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        // A replacement with no instruction would have the model reply to the transcript instead of tidying it.
        guard !prompt.isEmpty else { throw AppError.engineFailed(source, "The clean-up prompt is empty.") }
        guard let key = account.apiKey() else {
            throw account.isKeyUnreadable ? AppError.openRouterKeyUnreadable : AppError.openRouterMissingKey
        }
        let effort = ReasoningEffort(rawValue: route.effort)
        let limit = timeout ?? CleanupModel.timeout(forCharacterCount: transcript.count)
        let client = client
        let started = ContinuousClock.now
        let answer = AnswerStart()
        do {
            let cloud = try await Self.untilAnswerStarts(limit, answer, source: source) {
                try await client.cleanUp(transcript: transcript, route: route, systemPrompt: prompt, apiKey: key,
                                         timeout: limit) { streamed in
                    if streamed.outputCharacters > 0 || streamed.reasoningCharacters > 0 { answer.mark() }
                    progress?(streamed)
                }
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
            result.reasoningCharacters = cloud.reasoningCharacters
            result.timeToFirstToken = cloud.timeToFirstToken
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

    /// `work`, or `AppError.timeout(source)` when `answer` hasn't started once `seconds` pass (the request is cancelled
    /// then). An answer that has started runs to its end: a long clean-up writes for minutes, and cutting it off
    /// would pay for the tokens and paste the original anyway.
    private static func untilAnswerStarts<T: Sendable>(_ seconds: TimeInterval, _ answer: AnswerStart, source: EngineID,
                                                       _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let value = next { return value }
                guard answer.hasStarted else { throw AppError.timeout(source) }
            }
            throw AppError.timeout(source)
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

/// Whether a streamed answer has shown its first character: set from the stream's thread, read by the deadline that
/// waits for it (`TranscriptionService.untilAnswerStarts`).
final class AnswerStart: Sendable {
    private let started = OSAllocatedUnfairLock(initialState: false)

    var hasStarted: Bool { started.withLock { $0 } }

    func mark() { started.withLock { $0 = true } }
}

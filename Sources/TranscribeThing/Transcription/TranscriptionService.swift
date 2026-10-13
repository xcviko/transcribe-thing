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
    /// The level the model was asked to think at (Gemini); nil for models that don't reason.
    var reasoningEffort: ReasoningEffort? = nil
    var usage: TokenUsage? = nil
    /// A system prompt went with the request; nil for the local model.
    var usedSystemPrompt: Bool? = nil
    var finishReason: String? = nil
    /// Seconds OpenRouter measured for the generation.
    var generationTime: TimeInterval? = nil
    /// The chat response's `service_tier`, when it names one (set by text requests only; not kept in history).
    var serviceTier: String? = nil
    /// Characters of reasoning the answer streamed (for Gemini, the summaries of its thoughts).
    var reasoningCharacters: Int? = nil
    /// Seconds from sending a streamed request until the first character of the answer.
    var timeToFirstToken: TimeInterval? = nil
    /// The file the audio went to the cloud as; empty for the local model. Not kept in history.
    var uploads: [AudioUpload] = []
    /// How Gemini's answer held its transcript (`TaggedTranscript`). Not kept in history.
    var answerTags: TaggedTranscript.Tags? = nil
    /// The other request of the pair, cancelled when this one answered (`CloudHedge.race`): its generations, whose
    /// cost is added to this one's once OpenRouter has it (`TranscriptMetadata.pendingGenerationIDs`).
    var otherGenerationIDs: [String] = []

    /// Everything known about how this result came about, for its history version.
    func metadata(createdAt: Date = Date()) -> TranscriptMetadata {
        TranscriptMetadata(createdAt: createdAt, modelID: modelID, provider: provider, generationID: generationID,
                           reasoningEffort: reasoningEffort, usage: usage, costUSD: costUSD,
                           processingTime: processingTime, timeToFirstToken: timeToFirstToken,
                           generationTime: generationTime, usedSystemPrompt: usedSystemPrompt,
                           finishReason: finishReason,
                           reasoningCharacters: reasoningCharacters,
                           pendingGenerationIDs: otherGenerationIDs.isEmpty ? nil : otherGenerationIDs)
    }

    /// This result as a history version of `kind` (a transcription by its engine unless said otherwise).
    func version(_ kind: TranscriptVersionKind? = nil, text: String? = nil, createdAt: Date = Date()) -> TranscriptVersion {
        TranscriptVersion(kind: kind ?? .transcription(engine), text: text ?? self.text,
                          metadata: metadata(createdAt: createdAt))
    }
}

/// Routes a recording to the local model or Gemini, and returns trimmed text. An engine
/// that answers with no text heard no speech, so that comes back as an empty result, never as an error.
/// Gemini (its transcripts, Polish, Translate, Polish Selection) goes to the user's OpenAI-compatible endpoint instead
/// of OpenRouter while the endpoint routes it (`VertexProxyAccount.routesGemini`), with no fallback to OpenRouter.
@MainActor
final class TranscriptionService {
    private let models: ModelStore
    private let account: OpenRouterAccount
    private let client: OpenRouterClient
    /// The custom endpoint, when the app has one to offer (nil: Gemini always goes through OpenRouter).
    let proxy: VertexProxyAccount?
    private let providerLookupDelay: Duration
    /// `hedgeMeasured`, from any thread.
    private var measuredReporter: @Sendable (CloudHedge.Measurement) -> Void {
        let report = hedgeMeasured
        return { measurement in Task { @MainActor in report(measurement) } }
    }
    /// The level each Gemini model thinks at (`AppSettings.reasoningEfforts`), read as each request goes: every
    /// request to the model, but one given its own `effort`. The CLI keeps each model's default.
    var reasoningEffort: @MainActor (EngineID) -> ReasoningEffort? = { $0.defaultReasoningEffort }
    /// The user's dictionary (`UserDictionary`), at the moment each request goes: after Gemini's prompt and Polish
    /// Selection's, whichever prompt they get. The app reads it from its settings; the CLI sends none.
    var vocabulary: @MainActor () -> [String] = { [] }
    /// A request sent twice to measure (`CloudHedge.measure`) has both its answers: the app says how much sooner the
    /// first one came.
    var hedgeMeasured: @MainActor (CloudHedge.Measurement) -> Void = { _ in }

    init(models: ModelStore, account: OpenRouterAccount, client: OpenRouterClient,
         proxy: VertexProxyAccount? = nil, providerLookupDelay: Duration = .milliseconds(1500)) {
        self.models = models
        self.account = account
        self.client = client
        self.proxy = proxy
        self.providerLookupDelay = providerLookupDelay
    }

    /// Where a Gemini request goes right now: the client, its key, and who hears how it went.
    private struct ChatAccess {
        var client: OpenRouterClient
        var key: String
        var provider: CloudProvider
        var noteFailure: @MainActor (AppError) -> Void
        var noteSuccess: @MainActor () -> Void
    }

    /// The custom endpoint while it routes Gemini, else OpenRouter. Throws the missing or unreadable key of whichever
    /// it is: a proxy that's set up never hands its requests to OpenRouter.
    private func chatAccess() throws -> ChatAccess {
        if let proxy, proxy.routesGemini {
            guard let key = proxy.apiKey(), let client = proxy.client() else {
                throw AppError.vertexProxy(.keyUnreadable)
            }
            return ChatAccess(client: client, key: key, provider: .vertexProxy,
                              noteFailure: { proxy.noteCloudFailure($0) }, noteSuccess: { proxy.noteCloudSuccess() })
        }
        guard let key = account.apiKey() else {
            throw account.isKeyUnreadable ? AppError.openRouterKeyUnreadable : AppError.openRouterMissingKey
        }
        let account = account
        return ChatAccess(client: client, key: key, provider: .openRouter,
                          noteFailure: { account.noteCloudFailure($0) }, noteSuccess: { account.noteCloudSuccess() })
    }

    /// Where `engine`'s requests go now: nil for the local model.
    func provider(for engine: EngineID) -> CloudProvider? {
        CloudRoute.provider(for: engine, proxy: proxy)
    }

    /// Throws `AppError` only, or `CancellationError` when the calling task is cancelled. A retired model never runs.
    /// `processingTime` covers everything after the recording ended, including any wait for the model.
    /// `effort` has Gemini think at another level than the one picked for it (`EngineCLI --effort`), and `prompt` replaces its
    /// fixed `EngineID.geminiSystemPrompt`: Polish's (`Polish.prompt`, for a polished dictation and Home's Polish), or
    /// any (`--prompt`; empty sends only the audio). `upload` sends Gemini the audio in that format instead of
    /// an .m4a (`--upload`). The app passes only `prompt`.
    /// `background`: Home's work, which lets dictations have the local model first.
    /// `progress` hears how much of a streamed answer has come (Gemini's reasoning and text); Parakeet has none.
    /// `hedge`: Gemini's request goes twice at once (`CloudHedge`).
    func transcribe(_ recording: Recording, engine: EngineID, effort: ReasoningEffort? = nil,
                    prompt: String? = nil, upload: UploadFormat? = nil, hedge: CloudHedge? = nil, provider: OpenRouterChatRequest.Provider? = nil, background: Bool = false,
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
                let effort = effort ?? reasoningEffort(engine) ?? engine.defaultReasoningEffort ?? .medium
                let prompt = UserDictionary.prompt(prompt ?? EngineID.geminiSystemPrompt, with: vocabulary(), heard: true)
                let cloud = try await transcribeCloud(recording, engine: engine, effort: effort, prompt: prompt,
                                                      upload: upload, hedge: hedge, provider: provider,
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
                result.reasoningCharacters = cloud.reasoningCharacters
                result.timeToFirstToken = cloud.timeToFirstToken
                result.answerTags = cloud.answerTags
                result.otherGenerationIDs = cloud.otherGenerationIDs
                result.uploads = cloud.uploads
            }
            result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.processingTime = Self.seconds(started.duration(to: .now))
            return result
        } catch let error as AppError {
            Log.engine.error("\(engine.rawValue, privacy: .public) failed: \(error.code, privacy: .public)")
            DiagnosticLog.shared.event(.engine, "transcription.failed", [
                "engine": engine, "code": error, "seconds": Self.seconds(started.duration(to: .now))])
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Log.engine.error("\(engine.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            DiagnosticLog.shared.event(.engine, "transcription.failed", [
                "engine": engine, "error": DiagnosticErrorCode(error),
                "seconds": Self.seconds(started.duration(to: .now))])
            throw AppError.engineFailed(engine, ModelStore.oneLine(error))
        }
    }

    private func transcribeCloud(_ recording: Recording, engine: EngineID, effort: ReasoningEffort, prompt: String,
                                 upload: UploadFormat?, hedge: CloudHedge? = nil,
                                 provider: OpenRouterChatRequest.Provider? = nil,
                                 progress: (@Sendable (ChatStreamProgress) -> Void)?) async throws -> CloudResult {
        guard engine.isGemini, let model = engine.openRouterModelID else {
            throw AppError.engineFailed(engine, "No cloud model for \(engine.displayName).")
        }
        let access = try chatAccess()
        do {
            let result = try await transcribeWithChat(recording, engine: engine, model: model, access: access,
                                                      effort: effort, prompt: prompt, upload: upload,
                                                      hedge: hedge, provider: provider, progress: progress)
            access.noteSuccess()
            return result
        } catch let error as AppError {
            access.noteFailure(error)
            throw error
        }
    }

    /// Gemini: the whole recording in one request, with its system prompt, whatever its length, as AAC in an .m4a
    /// (`CloudAudio.forChat`: History's own file as it is, when it has one that fits, otherwise encoded off the main
    /// actor); the answer's token budget grows with the audio, and it streams, so no wait for it has to.
    private func transcribeWithChat(_ recording: Recording, engine: EngineID, model: String, access: ChatAccess,
                                    effort: ReasoningEffort, prompt: String, upload: UploadFormat?,
                                    hedge: CloudHedge? = nil, provider: OpenRouterChatRequest.Provider? = nil,
                                    progress: (@Sendable (ChatStreamProgress) -> Void)?) async throws -> CloudResult {
        let samples = recording.samples, stored = recording.aacFile, format = upload ?? .m4a
        let audio = await Task.detached(priority: .userInitiated) {
            try? CloudAudio.forChat(samples, stored: stored, format: format)
        }.value
        guard let audio else { throw AppError.engineFailed(engine, "Couldn’t compress the recording.") }
        try Task.checkCancellation()
        let maxTokens = OpenRouterClient.transcriptionMaxTokens(audioSeconds: Double(samples.count) / Recording.sampleRate,
                                                                effort: effort)
        let client = access.client, key = access.key, timeout = engine.cloudTimeout
        let send: @Sendable (CloudHedge.Hooks) async throws -> CloudResult = { hooks in
            try await client.transcribe(audio: audio, format: format.rawValue, model: model, systemPrompt: prompt,
                                        effort: effort, maxTokens: maxTokens, apiKey: key, timeout: timeout,
                                        progress: hooks.progress, generation: hooks.generation,
                                        provider: provider ?? .googleAIStudio)
        }
        var result = if let hedge {
            try await CloudHedge.run(hedge, .transcription, engine: engine, modelName: engine.modelName,
                                     progress: progress, measured: measuredReporter, send)
        } else {
            try await send(CloudHedge.Hooks(progress: progress) { _ in })
        }
        result.uploads = [AudioUpload(format: format, bytes: audio.count, generationID: result.generationID)]
        return result
    }

    // MARK: Text

    /// Polish Selection: `text` to the model of `route` (at the level it carries), with `prompt` (`Polish.textPrompt`)
    /// as its instructions. Gives
    /// up with `AppError.timeout` when the answer hasn't started within `TextRoute.timeout(forCharacterCount:)`; once it
    /// streams, it may take as long as it keeps coming, and the same time without a byte ends it. Throws `AppError`
    /// only, or `CancellationError`. `progress` hears how much of the answer has streamed in. Errors are Gemini's.
    /// `timeout` replaces that deadline (tests).
    func polishText(_ text: String, route: TextRoute, prompt: String, timeout: TimeInterval? = nil,
                    progress: (@Sendable (ChatStreamProgress) -> Void)? = nil) async throws -> TranscriptResult {
        let source = OpenRouterClient.engine(forModel: route.model)
        let prompt = UserDictionary.prompt(prompt, with: vocabulary(), heard: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A request with no instruction would have the model reply to the text instead of working on it.
        guard !prompt.isEmpty else { throw AppError.engineFailed(source, "The prompt is empty.") }
        let access = try chatAccess()
        let key = access.key
        let effort = ReasoningEffort(rawValue: route.effort)
        let limit = timeout ?? TextRoute.timeout(forCharacterCount: text.count)
        let client = access.client
        let started = ContinuousClock.now
        let answer = AnswerStart()
        do {
            let cloud = try await Self.untilAnswerStarts(limit, answer, source: source) {
                try await client.sendText(text, route: route, systemPrompt: prompt, apiKey: key, timeout: limit,
                                          progress: { streamed in
                    if streamed.outputCharacters > 0 || streamed.reasoningCharacters > 0 { answer.mark() }
                    progress?(streamed)
                })
            }
            access.noteSuccess()
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
            result.otherGenerationIDs = cloud.otherGenerationIDs
            return result
        } catch let error as AppError {
            access.noteFailure(error)
            Log.engine.error("Text request failed: \(error.code, privacy: .public)")
            DiagnosticLog.shared.event(.engine, "text.failed", [
                "code": error, "seconds": Self.seconds(started.duration(to: .now))])
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AppError.engineFailed(source, ModelStore.oneLine(error))
        }
    }

    /// `work`, or `AppError.timeout(source)` when `answer` hasn't started once `seconds` pass (the request is cancelled
    /// then). An answer that has started runs to its end: a long polish writes for minutes, and cutting it off would
    /// pay for the tokens and leave nothing.
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

    /// Who served a delivered cloud result, from OpenRouter's generation record ("Google AI Studio"). A generation OpenRouter
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

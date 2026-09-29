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
    /// The files the audio went to OpenRouter as, one per request that answered (each of Parakeet's segments); empty
    /// for the local model. Not kept in history.
    var uploads: [AudioUpload] = []

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
    /// The format Parakeet's segments go in: FLAC, the WAV's samples in a little over half its bytes, until OpenRouter
    /// refuses it; WAV from then on, for as long as the app runs.
    private(set) var speechFormat: UploadFormat = .flac

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
    /// fixed `EngineID.geminiSystemPrompt` (`--prompt`; empty sends only the audio), and `upload` sends a cloud model
    /// the audio in that format instead of its own, a refusal of it failing rather than going again as WAV
    /// (`--upload`); the app never passes any of them.
    /// `background`: Home's work, which lets dictations have the local model first.
    /// `progress` hears how much of a streamed answer has come (Gemini's reasoning and text); Parakeet has none.
    func transcribe(_ recording: Recording, engine: EngineID, effort: ReasoningEffort? = nil,
                    prompt: String? = nil, upload: UploadFormat? = nil, background: Bool = false,
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
                let cloud = try await transcribeCloud(recording, engine: engine, effort: effort, prompt: prompt,
                                                      upload: upload, progress: progress)
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
                result.uploads = cloud.uploads
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

    private func transcribeCloud(_ recording: Recording, engine: EngineID, effort: ReasoningEffort?, prompt: String,
                                 upload: UploadFormat?,
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
                result = try await transcribeWithChat(recording, engine: engine, model: model, key: key,
                                                      effort: effort ?? .medium, prompt: prompt, upload: upload,
                                                      progress: progress)
            case .transcriptions:
                result = try await transcribeSpeech(recording.samples, engine: engine, model: model, key: key,
                                                    upload: upload)
            }
            account.noteCloudSuccess()
            return result
        } catch let error as AppError {
            account.noteCloudFailure(error)
            throw error
        } catch let refused as OpenRouterClient.AudioFormatRefused {
            // A refusal with nothing left to fall back from: a WAV's, or a format `upload` forced.
            account.noteCloudFailure(refused.error)
            throw refused.error
        }
    }

    /// Gemini: the whole recording in one request, with its system prompt, whatever its length, as AAC in an .m4a
    /// (`CloudAudio.forChat`: History's own file as it is, when it has one that fits, otherwise encoded off the main
    /// actor); the answer's token budget grows with the audio, and it streams, so no wait for it has to.
    private func transcribeWithChat(_ recording: Recording, engine: EngineID, model: String, key: String,
                                    effort: ReasoningEffort, prompt: String, upload: UploadFormat?,
                                    progress: (@Sendable (ChatStreamProgress) -> Void)?) async throws -> CloudResult {
        let samples = recording.samples, stored = recording.aacFile, format = upload ?? .m4a
        let audio = await Task.detached(priority: .userInitiated) {
            try? CloudAudio.forChat(samples, stored: stored, format: format)
        }.value
        guard let audio else { throw AppError.engineFailed(engine, "Couldn’t compress the recording.") }
        try Task.checkCancellation()
        let maxTokens = OpenRouterClient.transcriptionMaxTokens(audioSeconds: Double(samples.count) / Recording.sampleRate)
        var result = try await client.transcribe(audio: audio, format: format.rawValue, model: model,
                                                 systemPrompt: prompt, effort: effort, maxTokens: maxTokens,
                                                 apiKey: key, timeout: engine.cloudTimeout, progress: progress)
        result.uploads = [AudioUpload(format: format, bytes: audio.count)]
        return result
    }

    /// Parakeet over the speech-to-text endpoint: a request per segment of at most 5 minutes, cut in pauses
    /// (`CloudAudio.speechSegments`; a shorter recording is one), one after another, each as FLAC (`speechFormat`,
    /// or `upload`). A segment whose FLAC OpenRouter refuses goes again as WAV at once, and so does every later one,
    /// in this and every dictation after it. The texts join with a space; the billed seconds and the costs add up, and
    /// the first segment's generation stands for the whole. The Gemini system prompt doesn't apply, and no language is
    /// sent: Parakeet v3 detects it.
    private func transcribeSpeech(_ samples: [Float], engine: EngineID, model: String, key: String,
                                  upload: UploadFormat?) async throws -> CloudResult {
        let ranges = await Task.detached(priority: .userInitiated) { CloudAudio.speechSegments(samples) }.value
        var results: [CloudResult] = []
        for range in ranges {
            try Task.checkCancellation()
            do {
                results.append(try await transcribeSegment(samples, range, format: upload ?? speechFormat,
                                                           engine: engine, model: model, key: key))
            } catch let refused as OpenRouterClient.AudioFormatRefused
                        where upload == nil && refused.format != UploadFormat.wav.rawValue {
                Log.net.warning("OpenRouter refused \(refused.format, privacy: .public) for \(engine.rawValue, privacy: .public): sending WAV from now on")
                speechFormat = .wav
                results.append(try await transcribeSegment(samples, range, format: .wav, engine: engine,
                                                           model: model, key: key))
            }
        }
        return Self.joined(results)
    }

    /// One of Parakeet's segments in `format` (`CloudAudio.forSpeech`: WAV when that encoder fails).
    private func transcribeSegment(_ samples: [Float], _ range: Range<Int>, format: UploadFormat, engine: EngineID,
                                   model: String, key: String) async throws -> CloudResult {
        let file = await Task.detached(priority: .userInitiated) {
            CloudAudio.forSpeech(Array(samples[range]), format: format)
        }.value
        var result = try await client.transcribeSpeech(audio: file.data, format: file.format.rawValue, model: model,
                                                       apiKey: key, timeout: engine.cloudTimeout)
        result.uploads = [AudioUpload(format: file.format, bytes: file.data.count)]
        return result
    }

    /// Parakeet's segments as one result: the first's, with every text (trimmed, empty ones left out) joined by a
    /// space, the billed seconds and costs summed (nil when none said), the first provider any of them named, and
    /// every segment's file.
    private nonisolated static func joined(_ results: [CloudResult]) -> CloudResult {
        guard var combined = results.first else { return CloudResult(text: "") }
        combined.text = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        combined.audioSeconds = Self.sum(results.map(\.audioSeconds))
        combined.costUSD = Self.sum(results.map(\.costUSD))
        combined.provider = results.lazy.compactMap(\.provider).first
        combined.uploads = results.flatMap(\.uploads)
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

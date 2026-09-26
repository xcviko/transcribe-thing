import Foundation

struct TranscriptResult: Sendable, Equatable {
    var text: String
    var engine: EngineID
    var processingTime: TimeInterval
    var costUSD: Double?
    /// The OpenRouter provider that served it, when the response said so. Otherwise look it up with
    /// `TranscriptionService.servedProvider(generationID:)` once the result is delivered.
    var provider: String? = nil
    /// OpenRouter generation id of the request behind this result.
    var generationID: String? = nil
}

/// Routes a recording to the local model, Gemini, or OpenRouter speech-to-text, and returns non-empty, trimmed text.
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
                let cloud = try await transcribeCloud(recording.samples, engine: engine)
                result.text = cloud.text
                result.costUSD = cloud.costUSD
                result.provider = cloud.provider
                result.generationID = cloud.generationID
            }
            result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.text.isEmpty else { throw await emptyResultError(for: recording.samples, engine: engine) }
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

    private func transcribeCloud(_ samples: [Float], engine: EngineID) async throws -> CloudResult {
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
                result = try await transcribeWithChat(samples, engine: engine, model: model, key: key)
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
    private func transcribeWithChat(_ samples: [Float], engine: EngineID, model: String,
                                    key: String) async throws -> CloudResult {
        // Refuse before spending time encoding a recording that can't be sent (the recording limit for Gemini
        // normally stops it well before this).
        let wavBytes = 44 + samples.count * 2
        guard OpenRouterClient.base64Length(ofByteCount: wavBytes) <= OpenRouterClient.maxBase64Bytes else {
            throw AppError.recordingTooLarge
        }
        let wav = await Task.detached(priority: .userInitiated) { WAVEncoder.pcm16(samples) }.value
        return try await client.transcribe(wav: wav, model: model, systemPrompt: settings.geminiSystemPrompt,
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

    /// Who served a delivered cloud result, from OpenRouter's generation record ("Together"). A generation OpenRouter
    /// hasn't recorded yet is asked for once more after a short wait. nil when nothing could be learned; never
    /// throws.
    func servedProvider(generationID: String) async -> String? {
        guard let key = account.apiKey() else { return nil }
        for attempt in 0..<2 {
            if attempt > 0 {
                do { try await Task.sleep(for: providerLookupDelay) } catch { return nil }
            }
            do {
                if let name = try await client.generationProvider(id: generationID, apiKey: key) { return name }
            } catch {
                if !(error is CancellationError) {
                    Log.net.info("Generation lookup failed: \(String(describing: error), privacy: .public)")
                }
                return nil
            }
        }
        return nil
    }

    nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// Silence that slipped past the recorder's gate reads as "no speech"; voice that produced no text is an
    /// engine problem worth retrying elsewhere.
    private func emptyResultError(for samples: [Float], engine: EngineID) async -> AppError {
        let voiced = await Task.detached(priority: .userInitiated) { SilenceGuard.voicedSeconds(samples) }.value
        return voiced < SilenceGuard.minimumVoicedSeconds ? .noSpeech : .emptyResult(engine)
    }
}

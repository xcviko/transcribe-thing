import Foundation

struct TranscriptResult: Sendable, Equatable {
    var text: String
    var engine: EngineID
    var processingTime: TimeInterval
    var costUSD: Double?
}

/// Routes a recording to the local model or to Gemini and returns non-empty, trimmed text.
@MainActor
final class TranscriptionService {
    private let models: ModelStore
    private let account: OpenRouterAccount
    private let client: OpenRouterClient
    private let settings: AppSettings

    init(models: ModelStore, account: OpenRouterAccount, client: OpenRouterClient, settings: AppSettings) {
        self.models = models
        self.account = account
        self.client = client
        self.settings = settings
    }

    /// Throws `AppError` only, or `CancellationError` when the calling task is cancelled.
    /// `processingTime` covers everything after the recording ended, including any wait for the model.
    func transcribe(_ recording: Recording, engine: EngineID) async throws -> TranscriptResult {
        let started = ContinuousClock.now
        do {
            let text: String
            var cost: Double?
            if engine.isLocal {
                text = try await models.transcribeLocal(engine, samples: recording.samples)
            } else {
                let result = try await transcribeCloud(recording.samples, engine: engine)
                text = result.text
                cost = result.costUSD
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw await emptyResultError(for: recording.samples, engine: engine) }
            return TranscriptResult(text: trimmed, engine: engine,
                                    processingTime: Self.seconds(started.duration(to: .now)), costUSD: cost)
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
        guard let model = engine.openRouterModelID else {
            throw AppError.engineFailed(engine, "No cloud model for \(engine.displayName).")
        }
        guard let key = account.apiKey() else {
            throw account.isKeyUnreadable ? AppError.openRouterKeyUnreadable : AppError.openRouterMissingKey
        }
        // Refuse before spending time encoding a recording that can't be sent (the recording limit for Gemini
        // normally stops it well before this).
        let wavBytes = 44 + samples.count * 2
        guard OpenRouterClient.base64Length(ofByteCount: wavBytes) <= OpenRouterClient.maxBase64Bytes else {
            throw AppError.recordingTooLarge
        }
        let wav = await Task.detached(priority: .userInitiated) { WAVEncoder.pcm16(samples) }.value
        do {
            let result = try await client.transcribe(wav: wav, model: model, systemPrompt: settings.geminiSystemPrompt,
                                                     apiKey: key, timeout: engine.cloudTimeout)
            account.noteCloudSuccess()
            return result
        } catch let error as AppError {
            account.noteCloudFailure(error)
            throw error
        }
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

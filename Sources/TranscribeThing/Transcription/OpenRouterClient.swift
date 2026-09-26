import Foundation

extension URLSession {
    /// Shared session for OpenRouter calls: no cookies or disk cache, fail fast when offline.
    /// Non-streaming requests receive no bytes until the answer is ready, so the per-request (idle)
    /// timeout is set per call to the engine's full budget; the resource timeout caps one attempt.
    static let openRouterCloud: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 330
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}

struct CloudResult: Sendable, Equatable {
    var text: String
    /// Who served the request, when the response says (Gemini's body, an `X-Provider-Name` header).
    var provider: String?
    var costUSD: Double?
    var reasoningTokens: Int?
    /// `X-Generation-Id`, for `generationProvider(id:apiKey:)`.
    var generationID: String?
}

/// Transcription through OpenRouter: Gemini over chat completions, Parakeet and Whisper over the speech-to-text
/// endpoint. Every failure surfaces as `AppError` (or `CancellationError` when the calling task is cancelled).
final class OpenRouterClient: Sendable {
    static let referer = "http://localhost/transcribe-thing"
    static let title = "transcribe-thing"
    /// Gemini accepts about 20 MB of inline data; stay under it (about 7.4 minutes of 16 kHz WAV).
    static let maxBase64Bytes = 19_000_000
    /// Recording limit with a Gemini engine selected: a margin under what `maxBase64Bytes` can carry.
    static let maxRecordingDuration: TimeInterval = 7 * 60
    static let keyCheckTimeout: TimeInterval = 15
    /// Longest server-requested wait worth sitting through during a dictation.
    static let maxRetryWait: TimeInterval = 8

    private let session: URLSession
    private let baseURL: URL
    private let retryDelay: TimeInterval

    init(session: URLSession = .openRouterCloud) {
        self.session = session
        self.baseURL = URL(string: "https://openrouter.ai/api/v1")!
        self.retryDelay = 1.5
    }

    init(session: URLSession, baseURL: URL, retryDelay: TimeInterval) {
        self.session = session
        self.baseURL = baseURL
        self.retryDelay = retryDelay
    }

    static func base64Length(ofByteCount count: Int) -> Int { (count + 2) / 3 * 4 }

    static func engine(forModel model: String) -> EngineID {
        EngineID.allCases.first { $0.openRouterModelID == model } ?? .geminiFlash
    }

    // MARK: Transcribe

    /// Gemini over chat completions. `wav` is a complete WAV file. Retries once, only for a transient failure
    /// (429/500/502/503/529, a 402 from the in-flight budget, a dropped connection, or the same failures reported
    /// quickly inside a 200) and only when the wait is at most 8 s; never after a timeout (the user already waited).
    func transcribe(wav: Data, model: String, systemPrompt: String?, apiKey: String,
                    timeout: TimeInterval) async throws -> CloudResult {
        let engine = Self.engine(forModel: model)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.openRouterMissingKey }
        guard Self.base64Length(ofByteCount: wav.count) <= Self.maxBase64Bytes else { throw AppError.recordingTooLarge }

        let body: Data
        do {
            body = try OpenRouterChatRequest.transcription(model: model, audioBase64: wav.base64EncodedString(),
                                                           systemPrompt: systemPrompt).encoded()
        } catch {
            throw AppError.openRouterBadRequest("Couldn’t build the request.")
        }
        let request = makeTranscriptionRequest(body: body, apiKey: key, timeout: timeout)
        let result = try await sendWithRetry(request, engine: engine) { data in
            try OpenRouterErrorMapper.success(data: data, engine: engine)
        }
        if let provider = result.provider, provider != "Google AI Studio" {
            Log.net.warning("Unexpected OpenRouter provider: \(provider, privacy: .public)")
        }
        return result
    }

    /// Parakeet or Whisper over `POST /audio/transcriptions`. `wav` is the whole recording as one WAV file, in
    /// one request: the providers behind it transcribe many times faster than real time, and a size OpenRouter
    /// refuses comes back as a 413 (`recordingTooLarge`). `language` is an ISO 639-1 hint, omitted when nil.
    /// Same retry policy as `transcribe(wav:model:systemPrompt:apiKey:timeout:)`.
    func transcribeSpeech(wav: Data, model: String, language: String?, apiKey: String,
                          timeout: TimeInterval) async throws -> CloudResult {
        let engine = Self.engine(forModel: model)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.openRouterMissingKey }

        let body: Data
        do {
            body = try OpenRouterSpeechRequest.wav(model: model, audioBase64: wav.base64EncodedString(),
                                                   language: language).encoded()
        } catch {
            throw AppError.openRouterBadRequest("Couldn’t build the request.")
        }
        let request = makeRequest(path: "audio/transcriptions", body: body, apiKey: key, timeout: timeout)
        return try await sendWithRetry(request, engine: engine) { data in
            try OpenRouterErrorMapper.speechSuccess(data: data, engine: engine)
        }
    }

    /// Sends `request`, retrying once per the policy above. `interpret` reads a 200 body and throws `AppError`
    /// for a failure reported inside it.
    private func sendWithRetry(_ request: URLRequest, engine: EngineID,
                               interpret: (Data) throws -> CloudResult) async throws -> CloudResult {
        var attempt = 1
        while true {
            let started = ContinuousClock.now
            do {
                let (data, http) = try await send(request, engine: engine)
                guard http.statusCode == 200 else {
                    let retryAfter = OpenRouterErrorMapper.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                    let error = OpenRouterErrorMapper.httpError(status: http.statusCode, data: data,
                                                                retryAfter: retryAfter, engine: engine)
                    // The mapped error decides, not the status alone: a 503 "No endpoints found" fails the same
                    // way every time, and a 402 is worth another go only when it's the in-flight budget.
                    let retryable = Self.retryableStatuses.contains(http.statusCode) && error.isTransientCloudFailure
                    throw AttemptFailure(error: error, retryable: retryable, retryAfter: retryAfter)
                }
                var result: CloudResult
                do {
                    result = try interpret(data)
                } catch let error as AppError {
                    // An upstream failure reported after OpenRouter committed a 200. Retried like its HTTP twin,
                    // but only when it came back quickly: after a long wait the user already waited once.
                    let quick = started.duration(to: .now) < Self.quickFailureWindow
                    throw AttemptFailure(error: error, retryable: quick && error.isTransientCloudFailure,
                                         retryAfter: nil)
                }
                if result.provider == nil { result.provider = Self.header("X-Provider-Name", in: http) }
                if result.generationID == nil { result.generationID = Self.header("X-Generation-Id", in: http) }
                return result
            } catch let failure as AttemptFailure {
                let wait = failure.retryAfter ?? retryDelay
                guard failure.retryable, attempt < 2, wait <= Self.maxRetryWait else { throw failure.error }
                Log.net.info("OpenRouter attempt \(attempt) failed (\(failure.error.code, privacy: .public)); retrying in \(wait, format: .fixed(precision: 1)) s")
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
            }
        }
    }

    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        return value
    }

    private static let retryableStatuses: Set<Int> = [402, 429, 500, 502, 503, 529]
    /// A failure inside a 200 that arrives sooner than this is retried like the same HTTP status.
    static let quickFailureWindow: Duration = .seconds(10)

    /// The Gemini request (chat completions).
    func makeTranscriptionRequest(body: Data, apiKey: String, timeout: TimeInterval) -> URLRequest {
        makeRequest(path: "chat/completions", body: body, apiKey: apiKey, timeout: timeout)
    }

    func makeRequest(path: String, body: Data, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout > 0 ? timeout : 120
        addHeaders(to: &request, apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    // MARK: Key

    /// `GET /api/v1/key`: label, spending limit and usage of this key. A 200 proves the key works, not that
    /// the account has credit or that Google AI Studio is allowed for it.
    func keyInfo(apiKey: String) async throws -> KeyInfo {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.openRouterMissingKey }
        var request = URLRequest(url: baseURL.appendingPathComponent("key"))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.keyCheckTimeout
        addHeaders(to: &request, apiKey: key)
        do {
            let (data, http) = try await send(request, engine: .geminiFlash)
            guard http.statusCode == 200 else {
                throw OpenRouterErrorMapper.httpError(
                    status: http.statusCode, data: data,
                    retryAfter: OpenRouterErrorMapper.retryAfter(http.value(forHTTPHeaderField: "Retry-After")),
                    engine: .geminiFlash)
            }
            do {
                return try JSONDecoder().decode(OpenRouterDataEnvelope<OpenRouterKeyInfo>.self, from: data).data.keyInfo
            } catch {
                throw AppError.openRouterServer("OpenRouter sent key details \(Brand.name) couldn’t read.")
            }
        } catch let failure as AttemptFailure {
            throw failure.error
        }
    }

    // MARK: Generation

    /// `GET /api/v1/generation?id=`: the provider that served a finished request. nil while OpenRouter hasn't
    /// recorded the generation yet (a 404 shortly after the response) or when it names no provider; other
    /// failures throw `AppError`.
    func generationProvider(id: String, apiKey: String) async throws -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.openRouterMissingKey }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("generation"),
                                              resolvingAgainstBaseURL: false) else {
            throw AppError.openRouterBadRequest("Couldn’t build the request.")
        }
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { throw AppError.openRouterBadRequest("Couldn’t build the request.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.keyCheckTimeout
        addHeaders(to: &request, apiKey: key)
        do {
            let (data, http) = try await send(request, engine: .geminiFlash)
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else {
                throw OpenRouterErrorMapper.httpError(
                    status: http.statusCode, data: data,
                    retryAfter: OpenRouterErrorMapper.retryAfter(http.value(forHTTPHeaderField: "Retry-After")),
                    engine: .geminiFlash)
            }
            let generation: OpenRouterGeneration
            do {
                generation = try JSONDecoder().decode(OpenRouterDataEnvelope<OpenRouterGeneration>.self, from: data).data
            } catch {
                throw AppError.openRouterServer("OpenRouter sent generation details \(Brand.name) couldn’t read.")
            }
            let name = generation.providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        } catch let failure as AttemptFailure {
            throw failure.error
        }
    }

    // MARK: Transport

    private struct AttemptFailure: Error {
        let error: AppError
        let retryable: Bool
        let retryAfter: Double?
    }

    private func addHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(Self.title, forHTTPHeaderField: "X-OpenRouter-Title")
    }

    private func send(_ request: URLRequest, engine: EngineID) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AttemptFailure(error: .openRouterServer("OpenRouter sent a response \(Brand.name) couldn’t read."),
                                     retryable: false, retryAfter: nil)
            }
            return (data, http)
        } catch let error as AttemptFailure {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw Self.transportFailure(error, engine: engine)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AttemptFailure(error: .openRouterServer(error.localizedDescription), retryable: false, retryAfter: nil)
        }
    }

    private static func transportFailure(_ error: URLError, engine: EngineID) -> AttemptFailure {
        switch error.code {
        case .timedOut:
            AttemptFailure(error: .timeout(engine), retryable: false, retryAfter: nil)
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed:
            AttemptFailure(error: .offline, retryable: false, retryAfter: nil)
        case .networkConnectionLost:
            AttemptFailure(error: .openRouterServer("The connection to OpenRouter was lost."), retryable: true, retryAfter: nil)
        case .cannotConnectToHost:
            AttemptFailure(error: .openRouterServer("Couldn’t connect to OpenRouter."), retryable: false, retryAfter: nil)
        default:
            AttemptFailure(error: .openRouterServer(error.localizedDescription), retryable: false, retryAfter: nil)
        }
    }
}

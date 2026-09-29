import Foundation

extension URLSession {
    /// Shared session for OpenRouter calls: no cookies or disk cache, fail fast when offline.
    /// The per-request timeout is an idle one, set per call (`EngineID.cloudTimeout`): a streamed answer keeps bytes
    /// coming (its text, and OpenRouter's comments while the model is busy), so there it only catches a stalled
    /// connection, and a speech-to-text segment answers within it. The resource timeout, 3 hours, caps a whole
    /// request, upload included, however long its answer streams.
    static let openRouterCloud: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 10_800
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}

struct CloudResult: Sendable, Equatable {
    var text: String
    /// Who served the request, when the response says (a chat stream's chunks, an `X-Provider-Name` header).
    var provider: String?
    var costUSD: Double?
    /// Token counts from the chat stream's `usage`; nil from the speech endpoint, which reports seconds.
    var usage: TokenUsage?
    /// The chunks' `id`, else `X-Generation-Id`: for `generationDetails(id:apiKey:)`.
    var generationID: String?
    /// The model that answered, as the response names it.
    var model: String?
    var finishReason: String?
    /// Seconds OpenRouter measured for the generation (`openrouter_metadata.generation_time`).
    var generationTime: TimeInterval?
    /// Seconds of audio the speech endpoint billed.
    var audioSeconds: Double?
    /// The chat response's `service_tier` ("flex", "standard"…), when it names one.
    var serviceTier: String?
    /// Characters of reasoning the stream showed (for Gemini, the summaries of its thoughts); nil when none came.
    var reasoningCharacters: Int?
    /// Seconds from sending the request until the first character of the answer streamed in.
    var timeToFirstToken: TimeInterval?

    var reasoningTokens: Int? { usage?.reasoningTokens }
}

/// Token counts of one OpenRouter chat completion. `completionTokens` includes `reasoningTokens`.
struct TokenUsage: Codable, Equatable, Sendable {
    var promptTokens: Int?
    /// The part of `promptTokens` that was audio, when reported.
    var audioTokens: Int?
    var cachedTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var totalTokens: Int?

    /// Visible output: completion minus reasoning.
    var outputTokens: Int? {
        guard let completionTokens else { return nil }
        return max(0, completionTokens - (reasoningTokens ?? 0))
    }
}

/// Transcription through OpenRouter: Gemini over chat completions, Parakeet over the speech-to-text endpoint.
/// Every failure surfaces as `AppError` (or `CancellationError` when the calling task is cancelled).
final class OpenRouterClient: Sendable {
    static let referer = "http://localhost/transcribe-thing"
    static let title = "transcribe-thing"
    /// The inline-audio budget of one Gemini request, as base64: Gemini accepts about 20 MB of inline data. A 16 kHz
    /// WAV fits up to about 7.4 minutes; a longer recording goes compressed (`CloudAudio.forChat`).
    static let maxBase64Bytes = 19_000_000
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

    /// `max_tokens` of a Gemini transcription. Its floor, 32,768, covers the first minute, so short dictations
    /// ask for what they always have (a 1:48 recording already thought for about 18k tokens at high, and less
    /// would cut them short); every further minute started adds 600 tokens to write it out, up to 65,536.
    static func transcriptionMaxTokens(audioSeconds: TimeInterval) -> Int {
        let minutes = Int((max(0, audioSeconds) / 60).rounded(.up))
        return min(65_536, 32_768 + 600 * max(0, minutes - 1))
    }

    static func engine(forModel model: String) -> EngineID {
        EngineID.offered.first { $0.openRouterModelID == model } ?? .geminiFlash
    }

    // MARK: Transcribe

    /// Gemini over chat completions, streamed. `audio` is a complete file in `format` ("wav", "m4a":
    /// `CloudAudio.forChat`), sent whatever its size: a size OpenRouter refuses comes back as `recordingTooLarge`.
    /// `progress` hears how much reasoning and text has streamed in (`streamWithRetry`). Retries once, only for a
    /// transient failure (429/500/502/503/529, a 402 from the in-flight budget, a dropped connection, or the same
    /// failures reported quickly inside the stream before any of the answer) and only when the wait is at most 8 s;
    /// never after a timeout (the user already waited). Cancelling stops the stream, though not the bill: Google AI
    /// Studio doesn't support stream cancellation, so the model finishes and is paid for in full.
    func transcribe(audio: Data, format: String, model: String, systemPrompt: String?, effort: ReasoningEffort,
                    maxTokens: Int, apiKey: String, timeout: TimeInterval,
                    progress: (@Sendable (ChatStreamProgress) -> Void)? = nil) async throws -> CloudResult {
        let engine = Self.engine(forModel: model)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.openRouterMissingKey }

        let body: Data
        do {
            body = try OpenRouterChatRequest.transcription(model: model, audioBase64: audio.base64EncodedString(),
                                                           format: format, systemPrompt: systemPrompt, effort: effort,
                                                           maxTokens: maxTokens).encoded()
        } catch {
            throw AppError.openRouterBadRequest("Couldn’t build the request.")
        }
        let request = makeTranscriptionRequest(body: body, apiKey: key, timeout: timeout)
        let result = try await streamWithRetry(request, engine: engine, progress: progress)
        if let provider = result.provider, provider != "Google AI Studio" {
            Log.net.warning("Unexpected OpenRouter provider: \(provider, privacy: .public)")
        }
        return result
    }

    /// Clean-up of `transcript` over chat completions by the model, provider and effort of `route`: text in, text
    /// out, with `systemPrompt` as the instructions, streamed to `progress` like transcription. Same retry policy; a
    /// failure is mapped as a Gemini one. Cancelling stops OpenAI's generation and its bill. The returned text is the
    /// model's reply without any tags or quotes it put around it.
    func cleanUp(transcript: String, route: CleanupRoute, systemPrompt: String, apiKey: String,
                 timeout: TimeInterval, progress: (@Sendable (ChatStreamProgress) -> Void)? = nil) async throws -> CloudResult {
        let engine = EngineID.geminiFlash
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.openRouterMissingKey }
        let body: Data
        do {
            body = try OpenRouterChatRequest.cleanup(route: route, systemPrompt: systemPrompt,
                                                     transcript: transcript).encoded()
        } catch {
            throw AppError.openRouterBadRequest("Couldn’t build the request.")
        }
        let request = makeTranscriptionRequest(body: body, apiKey: key, timeout: timeout)
        var result = try await streamWithRetry(request, engine: engine, progress: progress)
        result.text = CleanupModel.cleanedText(from: result.text)
        return result
    }

    /// Parakeet over `POST /audio/transcriptions`. `wav` is one WAV file in one request: a whole recording up to 5
    /// minutes, or one segment of a longer one (`CloudAudio.speechSegments`). The provider behind it transcribes many
    /// times faster than real time, and a size OpenRouter refuses comes back as a 413 (`recordingTooLarge`). Not
    /// streamed (the endpoint can't), with the same retry policy as `transcribe(audio:format:model:…)`.
    func transcribeSpeech(wav: Data, model: String, apiKey: String, timeout: TimeInterval) async throws -> CloudResult {
        let engine = Self.engine(forModel: model)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.openRouterMissingKey }

        let body: Data
        do {
            body = try OpenRouterSpeechRequest.wav(model: model, audioBase64: wav.base64EncodedString()).encoded()
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
        try await withRetry {
            let started = ContinuousClock.now
            let (data, http) = try await send(request, engine: engine)
            guard http.statusCode == 200 else { throw Self.statusFailure(http, body: data, engine: engine) }
            var result: CloudResult
            do {
                result = try interpret(data)
            } catch let error as AppError {
                // An upstream failure reported after OpenRouter committed a 200. Retried like its HTTP twin,
                // but only when it came back quickly: after a long wait the user already waited once.
                let quick = started.duration(to: .now) < Self.quickFailureWindow
                throw AttemptFailure(error: error, retryable: quick && error.isTransientCloudFailure, retryAfter: nil)
            }
            if result.provider == nil { result.provider = Self.header("X-Provider-Name", in: http) }
            if result.generationID == nil { result.generationID = Self.header("X-Generation-Id", in: http) }
            return result
        }
    }

    /// Sends a chat `request` and reads its answer as it streams in, retrying once per the policy above. Its
    /// `timeoutInterval` is a stall timeout: seconds with no byte at all, OpenRouter's comments included.
    /// `progress` hears at once of the first reasoning and the first text, then at most every 250 ms (a change held
    /// back goes out with the next line of any kind once that's due).
    private func streamWithRetry(_ request: URLRequest, engine: EngineID,
                                 progress: (@Sendable (ChatStreamProgress) -> Void)?) async throws -> CloudResult {
        try await withRetry {
            try await stream(request, engine: engine, progress: progress)
        }
    }

    /// One attempt of `streamWithRetry`. A failure before the 200 is retried like any request's; one inside the
    /// stream only when it came quickly and before any of the answer: the model's work is never thrown away.
    private func stream(_ request: URLRequest, engine: EngineID,
                        progress: (@Sendable (ChatStreamProgress) -> Void)?) async throws -> CloudResult {
        let started = ContinuousClock.now
        let (bytes, http) = try await open(request, engine: engine)
        guard http.statusCode == 200 else {
            let body = try await Self.prefix(of: bytes, limit: 64 * 1024)
            throw Self.statusFailure(http, body: body, engine: engine)
        }
        var stream = OpenRouterChatStream()
        var firstToken: TimeInterval?
        var reported = ChatStreamProgress()
        var reportedAt = started
        func report(force: Bool) {
            guard let progress, stream.progress != reported else { return }
            let now = ContinuousClock.now
            guard force || now - reportedAt >= Self.progressInterval else { return }
            reported = stream.progress
            reportedAt = now
            progress(reported)
        }
        /// One line into the stream; true once it has said it's done.
        func take(_ line: String) -> Bool {
            let before = stream.progress
            if stream.consume(line) {
                let firstReasoning = before.reasoningCharacters == 0 && stream.progress.reasoningCharacters > 0
                let firstText = before.outputCharacters == 0 && stream.progress.outputCharacters > 0
                if firstText { firstToken = TranscriptionService.seconds(started.duration(to: .now)) }
                report(force: firstReasoning || firstText)
            } else {
                // A comment while the model is busy, say: a change the interval held back goes out once it's due, so
                // the count never sits on an older value than the stream has reached.
                report(force: false)
            }
            return stream.isDone
        }
        var lines = ServerSentEventLines()
        do {
            var done = false
            for try await byte in bytes {
                guard let line = lines.take(byte) else { continue }
                done = take(line)
                if done { break }
            }
            if !done, let line = lines.finish() { _ = take(line) }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            guard let error = error as? URLError else {
                throw AttemptFailure(error: .openRouterServer(error.localizedDescription), retryable: false,
                                     retryAfter: nil)
            }
            if error.code == .cancelled { throw CancellationError() }
            var failure = Self.transportFailure(error, engine: engine)
            // A connection lost mid-answer isn't sent again: what the model already did would be paid for twice.
            if stream.hasOutput || started.duration(to: .now) >= Self.quickFailureWindow { failure.retryable = false }
            throw failure
        }
        try Task.checkCancellation()
        report(force: true)
        var result: CloudResult
        do {
            result = try stream.result(engine: engine)
        } catch let error as AppError {
            // A failure OpenRouter reported inside the stream (or a stream that just stopped): retried like its HTTP
            // twin only when it came back quickly, before any of the answer.
            let quick = started.duration(to: .now) < Self.quickFailureWindow
            throw AttemptFailure(error: error, retryable: quick && !stream.hasOutput && error.isTransientCloudFailure,
                                 retryAfter: nil)
        }
        if result.provider == nil { result.provider = Self.header("X-Provider-Name", in: http) }
        if result.generationID == nil { result.generationID = Self.header("X-Generation-Id", in: http) }
        result.timeToFirstToken = firstToken
        return result
    }

    /// Runs `attempt`, and once more after a pause when it fails with a retryable `AttemptFailure` whose wait is
    /// short enough.
    private func withRetry(_ attempt: () async throws -> CloudResult) async throws -> CloudResult {
        var number = 1
        while true {
            do {
                return try await attempt()
            } catch let failure as AttemptFailure {
                let wait = failure.retryAfter ?? retryDelay
                guard failure.retryable, number < 2, wait <= Self.maxRetryWait else { throw failure.error }
                Log.net.info("OpenRouter attempt \(number) failed (\(failure.error.code, privacy: .public)); retrying in \(wait, format: .fixed(precision: 1)) s")
                try await Task.sleep(for: .seconds(wait))
                number += 1
            }
        }
    }

    /// A non-200 answer as an attempt's failure. The mapped error decides whether it's worth another go, not the
    /// status alone: a 503 "No endpoints found" fails the same way every time, and a 402 is worth another go only
    /// when it's the in-flight budget.
    private static func statusFailure(_ http: HTTPURLResponse, body: Data, engine: EngineID) -> AttemptFailure {
        let retryAfter = OpenRouterErrorMapper.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
        let error = OpenRouterErrorMapper.httpError(status: http.statusCode, data: body, retryAfter: retryAfter,
                                                    engine: engine)
        return AttemptFailure(error: error, retryable: retryableStatuses.contains(http.statusCode)
                                  && error.isTransientCloudFailure, retryAfter: retryAfter)
    }

    /// The start of an error body (enough for its JSON), read off a stream.
    private static func prefix(of bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // The status already says what went wrong; a body cut short only says less.
        }
        return data
    }

    /// How often the stream's progress is passed on, past its first reasoning and its first text.
    static let progressInterval: Duration = .milliseconds(250)

    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        return value
    }

    private static let retryableStatuses: Set<Int> = [402, 429, 500, 502, 503, 529]
    /// A failure inside a 200 that arrives sooner than this (and, streamed, before any of the answer) is retried like
    /// the same HTTP status.
    static let quickFailureWindow: Duration = .seconds(10)

    /// A chat completions request (Gemini, clean-up). Asks for `openrouter_metadata`, which carries the generation
    /// time. `timeout` is how long the stream may go without a byte.
    func makeTranscriptionRequest(body: Data, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = makeRequest(path: "chat/completions", body: body, apiKey: apiKey, timeout: timeout)
        request.setValue("enabled", forHTTPHeaderField: "X-OpenRouter-Metadata")
        return request
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
        try await generationDetails(id: id, apiKey: apiKey)?.provider
    }

    /// `GET /api/v1/generation?id=`: who served a finished request, what it cost and how long it took. nil while
    /// OpenRouter hasn't recorded the generation yet (a 404 shortly after the response); other failures throw
    /// `AppError`.
    func generationDetails(id: String, apiKey: String) async throws -> GenerationDetails? {
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
            do {
                return try JSONDecoder().decode(OpenRouterDataEnvelope<OpenRouterGeneration>.self, from: data).data.details
            } catch {
                throw AppError.openRouterServer("OpenRouter sent generation details \(Brand.name) couldn’t read.")
            }
        } catch let failure as AttemptFailure {
            throw failure.error
        }
    }

    // MARK: Transport

    private struct AttemptFailure: Error {
        let error: AppError
        var retryable: Bool
        let retryAfter: Double?
    }

    private func addHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(Self.title, forHTTPHeaderField: "X-OpenRouter-Title")
    }

    private func send(_ request: URLRequest, engine: EngineID) async throws -> (Data, HTTPURLResponse) {
        try await transport(engine: engine) { try await session.data(for: request) }
    }

    /// The response of a streamed request, its body still to come.
    private func open(_ request: URLRequest, engine: EngineID) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await transport(engine: engine) { try await session.bytes(for: request) }
    }

    /// Runs one URLSession call, mapping what it throws to an `AttemptFailure` (or `CancellationError`).
    private func transport<Body>(engine: EngineID,
                                 _ call: () async throws -> (Body, URLResponse)) async throws -> (Body, HTTPURLResponse) {
        do {
            let (body, response) = try await call()
            guard let http = response as? HTTPURLResponse else {
                throw AttemptFailure(error: .openRouterServer("OpenRouter sent a response \(Brand.name) couldn’t read."),
                                     retryable: false, retryAfter: nil)
            }
            return (body, http)
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

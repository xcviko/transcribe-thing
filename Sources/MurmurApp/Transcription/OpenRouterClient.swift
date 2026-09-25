import Foundation

extension URLSession {
    /// Shared session for OpenRouter calls: no cookies or disk cache, fail fast when offline.
    /// Non-streaming requests receive no bytes until the answer is ready, so the per-request (idle)
    /// timeout is set per call to the engine's full budget; the resource timeout caps one attempt.
    static let murmurCloud: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 330
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}

struct CloudResult: Sendable {
    var text: String
    var provider: String?
    var costUSD: Double?
    var reasoningTokens: Int?
}

/// Gemini transcription through OpenRouter's chat completions endpoint. Every failure surfaces as
/// `MurmurError` (or `CancellationError` when the calling task is cancelled).
final class OpenRouterClient: Sendable {
    static let referer = "https://github.com/murmur-dictation/murmur"
    static let title = "Murmur"
    /// Gemini accepts about 20 MB of inline data; stay under it (about 7.4 minutes of 16 kHz WAV).
    static let maxBase64Bytes = 19_000_000
    static let keyCheckTimeout: TimeInterval = 15
    /// Longest server-requested wait worth sitting through during a dictation.
    static let maxRetryWait: TimeInterval = 8

    private let session: URLSession
    private let baseURL: URL
    private let retryDelay: TimeInterval

    init(session: URLSession = .murmurCloud) {
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

    /// `wav` is a complete WAV file. Retries once, only for 429/500/502/503/529 or a dropped connection, and
    /// only when the wait is at most 8 s; never after a timeout (the user already waited).
    func transcribe(wav: Data, model: String, systemPrompt: String?, apiKey: String,
                    timeout: TimeInterval) async throws -> CloudResult {
        let engine = Self.engine(forModel: model)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MurmurError.openRouterMissingKey }
        guard Self.base64Length(ofByteCount: wav.count) <= Self.maxBase64Bytes else { throw MurmurError.recordingTooLarge }

        let body: Data
        do {
            body = try OpenRouterChatRequest.transcription(model: model, audioBase64: wav.base64EncodedString(),
                                                           systemPrompt: systemPrompt).encoded()
        } catch {
            throw MurmurError.openRouterBadRequest("Couldn’t build the request.")
        }
        let request = makeTranscriptionRequest(body: body, apiKey: key, timeout: timeout)

        var attempt = 1
        while true {
            do {
                let (data, http) = try await send(request, engine: engine)
                guard http.statusCode == 200 else {
                    let retryAfter = OpenRouterErrorMapper.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                    let error = OpenRouterErrorMapper.httpError(status: http.statusCode, data: data,
                                                                retryAfter: retryAfter, engine: engine)
                    throw AttemptFailure(error: error, retryable: Self.retryableStatuses.contains(http.statusCode),
                                         retryAfter: retryAfter)
                }
                var result = try OpenRouterErrorMapper.success(data: data, engine: engine)
                if result.provider == nil { result.provider = http.value(forHTTPHeaderField: "X-Provider-Name") }
                if let provider = result.provider, provider != "Google AI Studio" {
                    Log.net.warning("Unexpected OpenRouter provider: \(provider, privacy: .public)")
                }
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

    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 529]

    func makeTranscriptionRequest(body: Data, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
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
        guard !key.isEmpty else { throw MurmurError.openRouterMissingKey }
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
                throw MurmurError.openRouterServer("OpenRouter sent key details Murmur couldn’t read.")
            }
        } catch let failure as AttemptFailure {
            throw failure.error
        }
    }

    // MARK: Transport

    private struct AttemptFailure: Error {
        let error: MurmurError
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
                throw AttemptFailure(error: .openRouterServer("OpenRouter sent a response Murmur couldn’t read."),
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

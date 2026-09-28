import Foundation
import Observation
import Testing
@testable import TranscribeThing

// MARK: - OpenRouter request

@Suite struct OpenRouterRequestTests {
    private func object(_ body: OpenRouterChatRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: body.encoded()) as? [String: Any])
    }

    @Test func emptyPromptSendsOnlyTheAudio() throws {
        let body = OpenRouterChatRequest.transcription(model: "google/gemini-3.8-flash", audioBase64: "UklG+/==",
                                                       systemPrompt: "", effort: .high)
        let json = try object(body)
        #expect(Set(json.keys) == ["model", "messages", "reasoning", "provider", "max_tokens", "stream"])
        #expect(json["model"] as? String == "google/gemini-3.8-flash")
        #expect(json["temperature"] == nil)
        #expect(json["max_tokens"] as? Int == 32_768)
        #expect(json["stream"] as? Bool == false)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 1, "no text part next to the audio")
        #expect(Set(content[0].keys) == ["type", "input_audio"])
        #expect(content[0]["type"] as? String == "input_audio")
        let audio = try #require(content[0]["input_audio"] as? [String: Any])
        #expect(audio["data"] as? String == "UklG+/==")
        #expect(audio["format"] as? String == "wav")

        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "high")
        #expect(reasoning["exclude"] as? Bool == true)
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["google-ai-studio"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
        #expect(provider.count == 2)
    }

    @Test(arguments: [nil, "", "   \n\t "] as [String?])
    func blankPromptsAddNoSystemMessage(_ prompt: String?) throws {
        let body = OpenRouterChatRequest.transcription(model: "m", audioBase64: "AA==", systemPrompt: prompt, effort: .high)
        #expect(body.messages == [.userAudio(base64: "AA==", format: "wav")])
    }

    @Test func systemPromptComesFirstTrimmed() throws {
        let body = OpenRouterChatRequest.transcription(model: "google/gemini-3.1-pro-preview", audioBase64: "AA==",
                                                       systemPrompt: "  Transcribe verbatim.\n", effort: .high)
        let json = try object(body)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "Transcribe verbatim.")
        #expect(messages[1]["role"] as? String == "user")
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "input_audio")
    }

    @Test func slashesInBase64AreNotEscaped() throws {
        let raw = String(decoding: try OpenRouterChatRequest.transcription(
            model: "google/gemini-3.8-flash", audioBase64: "ab/cd+/ef==", systemPrompt: nil, effort: .high).encoded(), as: UTF8.self)
        #expect(raw.contains("ab/cd+/ef=="))
        #expect(raw.contains("google/gemini-3.8-flash"))
        #expect(!raw.contains("\\/"))
    }

    @Test func requestHasEndpointHeadersAndTimeout() {
        let client = OpenRouterClient()
        let request = client.makeTranscriptionRequest(body: Data("{}".utf8), apiKey: "sk-or-v1-abc", timeout: 180)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 180)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-abc")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "http://localhost/transcribe-thing")
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "transcribe-thing")
    }

    @Test func payloadLimitMatchesBase64Size() {
        #expect(OpenRouterClient.base64Length(ofByteCount: 3) == 4)
        #expect(OpenRouterClient.base64Length(ofByteCount: 4) == 8)
        // 7 minutes of 16 kHz WAV fits; 8 minutes doesn't.
        #expect(OpenRouterClient.base64Length(ofByteCount: 44 + 7 * 60 * 16_000 * 2) <= OpenRouterClient.maxBase64Bytes)
        #expect(OpenRouterClient.base64Length(ofByteCount: 44 + 8 * 60 * 16_000 * 2) > OpenRouterClient.maxBase64Bytes)
    }
}

// MARK: - OpenRouter response and error mapping

struct HTTPErrorCase: Sendable, CustomTestStringConvertible {
    let status: Int
    let body: String
    let retryAfter: Double?
    let expected: AppError

    init(_ status: Int, _ body: String, retryAfter: Double? = nil, _ expected: AppError) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
        self.expected = expected
    }

    var testDescription: String { "HTTP \(status) \(body.prefix(50))" }
}

struct OKBodyCase: Sendable, CustomTestStringConvertible {
    let name: String
    let body: String
    let expected: AppError

    var testDescription: String { name }
}

@Suite struct OpenRouterMappingTests {
    static let hint = OpenRouterErrorMapper.noRouteHint

    static let httpCases: [HTTPErrorCase] = [
        .init(400, #"{"error":{"code":400,"message":"Invalid audio format"}}"#, .openRouterBadRequest("Invalid audio format")),
        .init(400, #"{"error":{"code":400,"message":"Too long","metadata":{"error_type":"context_length_exceeded"}}}"#,
              .openRouterBadRequest("Too long")),
        .init(401, #"{"error":{"message":"User not found.","code":401}}"#, .openRouterInvalidKey("User not found.")),
        .init(401, #"{"error":{"message":"Missing Authentication header","code":401}}"#,
              .openRouterInvalidKey("Missing Authentication header")),
        .init(402, #"{"error":{"code":402,"message":"Insufficient credits","metadata":{"error_type":"payment_required","limit_source":"openrouter_credits"}}}"#,
              .openRouterNoCredits("Insufficient credits")),
        .init(402, #"{"error":{"code":402,"message":"Key limit exceeded","metadata":{"error_type":"payment_required","limit_source":"openrouter_key_limit"}}}"#,
              .openRouterKeyLimit("Key limit exceeded")),
        .init(402, #"{"error":{"code":402,"message":"Too many requests in flight","metadata":{"error_type":"payment_required","limit_source":"openrouter_in_flight_budget"}}}"#,
              retryAfter: 2, .openRouterRateLimited(retryAfter: 2)),
        .init(403, #"{"error":{"code":403,"message":"Input was flagged","metadata":{"error_type":"content_policy_violation"}}}"#,
              .openRouterRefused("Input was flagged")),
        .init(403, #"{"error":{"code":403,"message":"Key is disabled"}}"#, .openRouterRefused("Key is disabled")),
        .init(404, #"{"error":{"code":404,"message":"No endpoints found matching your data policy (Zero data retention)."}}"#,
              .openRouterNoRoute("No endpoints found matching your data policy (Zero data retention). \(hint)")),
        .init(404, #"{"error":{"code":404,"message":"Model not found"}}"#, .openRouterNoRoute("Model not found \(hint)")),
        .init(408, #"{"error":{"code":408,"message":"Request timed out"}}"#, .timeout(.geminiPro)),
        .init(413, "", .recordingTooLarge),
        .init(413, #"{"error":{"code":413,"message":"Payload too large","metadata":{"error_type":"payload_too_large"}}}"#,
              .recordingTooLarge),
        .init(422, #"{"error":{"code":422,"message":"Unprocessable audio"}}"#, .openRouterBadRequest("Unprocessable audio")),
        .init(429, #"{"error":{"code":429,"message":"Rate limit exceeded"}}"#, retryAfter: 3,
              .openRouterRateLimited(retryAfter: 3)),
        .init(429, #"{"error":{"code":429,"message":"Rate limit exceeded"}}"#, .openRouterRateLimited(retryAfter: nil)),
        .init(500, #"{"error":{"code":500,"message":"Internal Server Error"}}"#, .openRouterServer("Internal Server Error")),
        .init(500, "", .openRouterServer("HTTP 500")),
        .init(502, #"{"error":{"code":502,"message":"Provider returned error","metadata":{"provider_name":"Google AI Studio"}}}"#,
              .openRouterProviderUnavailable("Provider returned error")),
        .init(503, #"{"error":{"code":503,"message":"No endpoints found that support input audio"}}"#,
              .openRouterNoRoute("No endpoints found that support input audio \(hint)")),
        .init(503, #"{"error":{"code":503,"message":"No allowed providers are available for the selected model."}}"#,
              .openRouterNoRoute("No allowed providers are available for the selected model. \(hint)")),
        .init(503, #"{"error":{"code":503,"message":"Service overloaded","metadata":{"error_type":"provider_overloaded"}}}"#,
              .openRouterProviderUnavailable("Service overloaded")),
        .init(504, "<html><body>Gateway timeout</body></html>", .timeout(.geminiPro)),
        .init(524, "", .timeout(.geminiPro)),
        .init(529, #"{"error":{"code":529,"message":"Overloaded"}}"#, .openRouterProviderUnavailable("Overloaded")),
    ]

    @Test(arguments: httpCases)
    func httpStatusMapsToAppError(_ testCase: HTTPErrorCase) {
        let error = OpenRouterErrorMapper.httpError(status: testCase.status, data: Data(testCase.body.utf8),
                                                    retryAfter: testCase.retryAfter, engine: .geminiPro)
        #expect(error == testCase.expected)
    }

    static let okCases: [OKBodyCase] = [
        OKBodyCase(name: "top-level error, no choices",
                   body: #"{"id":"gen-1","error":{"code":502,"message":"Upstream error"}}"#,
                   expected: .openRouterProviderUnavailable("Upstream error")),
        OKBodyCase(name: "top-level rate limit",
                   body: #"{"error":{"code":429,"message":"Resource exhausted","metadata":{"error_type":"rate_limit_exceeded"}}}"#,
                   expected: .openRouterRateLimited(retryAfter: nil)),
        OKBodyCase(name: "choice error with a string code",
                   body: #"{"choices":[{"finish_reason":"error","message":{"content":"partial"},"error":{"code":"server_error","message":"Stream broke"}}]}"#,
                   expected: .openRouterProviderUnavailable("Stream broke")),
        OKBodyCase(name: "finish_reason error without details",
                   body: #"{"choices":[{"finish_reason":"error","message":{"content":"partial text"}}]}"#,
                   expected: .openRouterProviderUnavailable("Gemini stopped with an error before finishing.")),
        OKBodyCase(name: "content filter",
                   body: #"{"choices":[{"finish_reason":"content_filter","native_finish_reason":"SAFETY","message":{"content":null}}]}"#,
                   expected: .openRouterRefused("Stopped by the safety filter (SAFETY).")),
        OKBodyCase(name: "refusal with empty content",
                   body: #"{"choices":[{"finish_reason":"stop","message":{"content":"","refusal":"I can't help with that."}}]}"#,
                   expected: .openRouterRefused("I can't help with that.")),
        OKBodyCase(name: "reasoning used every token",
                   body: #"{"choices":[{"finish_reason":"length","message":{"content":""}}]}"#,
                   expected: .openRouterTruncated("")),
        OKBodyCase(name: "no choices", body: #"{"id":"gen-2"}"#,
                   expected: .openRouterServer("OpenRouter sent no transcript.")),
        OKBodyCase(name: "not JSON", body: "<html>oops</html>",
                   expected: .openRouterServer("OpenRouter sent a response \(Brand.name) couldn’t read.")),
    ]

    @Test(arguments: okCases)
    func failuresInsideHTTP200(_ testCase: OKBodyCase) {
        #expect(throws: testCase.expected) {
            try OpenRouterErrorMapper.success(data: Data(testCase.body.utf8), engine: .geminiPro)
        }
    }

    @Test func successIsTrimmedWithCostProviderAndReasoning() throws {
        let body = #"""
        {"id":"gen-9","model":"google/gemini-3.8-flash","provider":"Google AI Studio","service_tier":"default",
         "choices":[{"index":0,"finish_reason":"stop","native_finish_reason":"STOP",
                     "message":{"role":"assistant","content":"  Привет, это проверка.\n","refusal":null,"reasoning":null}}],
         "usage":{"prompt_tokens":1925,"completion_tokens":820,"cost":0.0045,
                  "completion_tokens_details":{"reasoning_tokens":800}}}
        """#
        let result = try OpenRouterErrorMapper.success(data: Data(body.utf8), engine: .geminiFlash)
        #expect(result.text == "Привет, это проверка.")
        #expect(result.provider == "Google AI Studio")
        #expect(result.costUSD == 0.0045)
        #expect(result.reasoningTokens == 800)
    }

    @Test func emptyTranscriptFromStopReadsAsEmpty() throws {
        for content in [#""   ""#, "null"] {
            let body = #"{"choices":[{"finish_reason":"stop","message":{"content":"# + content + "}}]}"
            let result = try OpenRouterErrorMapper.success(data: Data(body.utf8), engine: .geminiFlash)
            #expect(result.text.isEmpty, "Gemini finished normally and heard no speech: silence, not a failure")
        }
    }

    @Test func contentAsPartsIsJoined() throws {
        let body = #"{"choices":[{"finish_reason":"stop","message":{"content":[{"type":"text","text":"Hello "},{"type":"text","text":"world."}]}}]}"#
        #expect(try OpenRouterErrorMapper.success(data: Data(body.utf8), engine: .geminiFlash).text == "Hello world.")
    }

    @Test func truncatedTextIsNeverTakenForAWholeTranscript() throws {
        // Out of tokens: a repetition loop or a cut-off ending. The text is kept for the notice, not pasted.
        let body = #"{"choices":[{"finish_reason":"length","message":{"content":" A long transcript "}}]}"#
        #expect(throws: AppError.openRouterTruncated("A long transcript")) {
            try OpenRouterErrorMapper.success(data: Data(body.utf8), engine: .geminiFlash)
        }
    }

    @Test func retryAfterAcceptsSecondsAndDates() {
        #expect(OpenRouterErrorMapper.retryAfter("7") == 7)
        #expect(OpenRouterErrorMapper.retryAfter(" 2.5 ") == 2.5)
        #expect(OpenRouterErrorMapper.retryAfter(nil) == nil)
        #expect(OpenRouterErrorMapper.retryAfter("soon") == nil)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: now.addingTimeInterval(12))
        #expect(OpenRouterErrorMapper.retryAfter(header, now: now) == 12)
    }
}

// MARK: - OpenRouter client over a stubbed network

final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
        var error: URLError.Code?
    }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: [Reply]] = [:]
        private var requests: [String: [URLRequest]] = [:]
        private var bodies: [String: [Data]] = [:]

        func enqueue(_ reply: [Reply], host: String) { lock.withLock { replies[host, default: []] += reply } }
        func requests(for host: String) -> [URLRequest] { lock.withLock { requests[host] ?? [] } }
        /// Request bodies in arrival order (URLSession hands them to the protocol as a stream).
        func bodies(for host: String) -> [Data] { lock.withLock { bodies[host] ?? [] } }
        func next(for request: URLRequest) -> Reply? {
            let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
            return lock.withLock {
                let host = request.url?.host ?? ""
                requests[host, default: []].append(request)
                bodies[host, default: []].append(body)
                guard var queue = replies[host], !queue.isEmpty else { return nil }
                let reply = queue.removeFirst()
                replies[host] = queue
                return reply
            }
        }

        private static func drain(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = Self.registry.next(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let code = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A client whose requests go to a host unique to the calling test.
    static func client(_ replies: [Reply]) -> (OpenRouterClient, String) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        registry.enqueue(replies, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = OpenRouterClient(session: URLSession(configuration: config),
                                      baseURL: URL(string: "https://\(host)/api/v1")!, retryDelay: 0.01)
        return (client, host)
    }
}

enum Fixtures {
    static let success = StubURLProtocol.Reply(body: #"{"provider":"Google AI Studio","choices":[{"finish_reason":"stop","message":{"content":"Hello there."}}],"usage":{"cost":0.001}}"#)
    static let keyInfo = #"""
    {"data":{"label":"sk-or-v1-au7...890","limit":100,"limit_remaining":74.5,"limit_reset":"monthly",
     "include_byok_in_limit":false,"usage":25.5,"usage_daily":25.5,"usage_weekly":25.5,"usage_monthly":25.5,
     "byok_usage":17.38,"is_free_tier":false,"is_management_key":false,"is_provisioning_key":false,
     "expires_at":"2027-12-31T23:59:59Z","creator_user_id":"user_1","organization_id":null,
     "allowed_data_regions":["global","europe","us"],
     "rate_limit":{"requests":1000,"interval":"1h","note":"deprecated"}}}
    """#
    static let wav = WAVEncoder.pcm16([Float](repeating: 0.1, count: 1_600))
}

@Suite struct OpenRouterClientTests {
    @Test func invalidKeyIsNotRetried() async throws {
        let (client, host) = StubURLProtocol.client([.init(status: 401, body: #"{"error":{"message":"User not found.","code":401}}"#)])
        await #expect(throws: AppError.openRouterInvalidKey("User not found.")) {
            try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                        apiKey: "sk-or-v1-invalid", timeout: 120)
        }
        let requests = StubURLProtocol.registry.requests(for: host)
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-invalid")
        #expect(requests.first?.url?.path == "/api/v1/chat/completions")
    }

    @Test func overloadedProviderIsRetriedOnce() async throws {
        let (client, host) = StubURLProtocol.client([
            .init(status: 503, body: #"{"error":{"code":503,"message":"Overloaded"}}"#), Fixtures.success,
        ])
        let result = try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash",
                                                 systemPrompt: "", effort: .high, apiKey: "k", timeout: 120)
        #expect(result.text == "Hello there.")
        #expect(result.costUSD == 0.001)
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
    }

    @Test func onlyOneRetry() async throws {
        let failure = StubURLProtocol.Reply(status: 500, body: #"{"error":{"code":500,"message":"Internal Server Error"}}"#)
        let (client, host) = StubURLProtocol.client([failure, failure, Fixtures.success])
        await #expect(throws: AppError.openRouterServer("Internal Server Error")) {
            try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                        apiKey: "k", timeout: 120)
        }
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
    }

    @Test func noRouteBehindA503IsNotRetried() async throws {
        let noRoute = StubURLProtocol.Reply(status: 503, body: #"{"error":{"code":503,"message":"No endpoints found matching your data policy."}}"#)
        let (client, host) = StubURLProtocol.client([noRoute, Fixtures.success])
        await #expect(throws: AppError.openRouterNoRoute("No endpoints found matching your data policy. \(OpenRouterErrorMapper.noRouteHint)")) {
            try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                        apiKey: "k", timeout: 120)
        }
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
    }

    @Test func upstreamFailureInsideA200IsRetriedOnce() async throws {
        let upstream = StubURLProtocol.Reply(body: #"{"id":"gen-1","error":{"code":502,"message":"Upstream error"}}"#)
        let (client, host) = StubURLProtocol.client([upstream, Fixtures.success])
        let result = try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                                 apiKey: "k", timeout: 120)
        #expect(result.text == "Hello there.")
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
    }

    @Test func inFlightBudgetIsRetriedButNoCreditIsNot() async throws {
        let inFlight = StubURLProtocol.Reply(
            status: 402, headers: ["Retry-After": "0"],
            body: #"{"error":{"code":402,"message":"In flight","metadata":{"limit_source":"openrouter_in_flight_budget"}}}"#)
        let (client, host) = StubURLProtocol.client([inFlight, Fixtures.success])
        #expect(try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                            apiKey: "k", timeout: 120).text == "Hello there.")
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)

        let broke = StubURLProtocol.Reply(status: 402, body: #"{"error":{"code":402,"message":"Insufficient credits"}}"#)
        let (second, secondHost) = StubURLProtocol.client([broke, Fixtures.success])
        await #expect(throws: AppError.openRouterNoCredits("Insufficient credits")) {
            try await second.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                        apiKey: "k", timeout: 120)
        }
        #expect(StubURLProtocol.registry.requests(for: secondHost).count == 1)
    }

    @Test func longRetryAfterIsNotAwaited() async throws {
        let (client, host) = StubURLProtocol.client([
            .init(status: 429, headers: ["Retry-After": "30"], body: #"{"error":{"code":429,"message":"Slow down"}}"#),
            Fixtures.success,
        ])
        await #expect(throws: AppError.openRouterRateLimited(retryAfter: 30)) {
            try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                        apiKey: "k", timeout: 120)
        }
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
    }

    @Test func droppedConnectionIsRetried() async throws {
        let (client, host) = StubURLProtocol.client([.init(error: .networkConnectionLost), Fixtures.success])
        let result = try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.1-pro-preview",
                                                 systemPrompt: nil, effort: .high, apiKey: "k", timeout: 180)
        #expect(result.text == "Hello there.")
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
    }

    @Test func timeoutIsNotRetried() async throws {
        let (client, host) = StubURLProtocol.client([.init(error: .timedOut), Fixtures.success])
        await #expect(throws: AppError.timeout(.geminiPro)) {
            try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.1-pro-preview", systemPrompt: nil, effort: .high,
                                        apiKey: "k", timeout: 180)
        }
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
    }

    @Test func offline() async throws {
        let (client, _) = StubURLProtocol.client([.init(error: .notConnectedToInternet)])
        await #expect(throws: AppError.offline) {
            try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                        apiKey: "k", timeout: 120)
        }
    }

    @Test func oversizedPayloadNeverLeavesTheMac() async throws {
        let (client, host) = StubURLProtocol.client([Fixtures.success])
        let wav = Data(count: 15_000_000)
        await #expect(throws: AppError.recordingTooLarge) {
            try await client.transcribe(wav: wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                        apiKey: "k", timeout: 120)
        }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }

    @Test func missingKey() async throws {
        let (client, _) = StubURLProtocol.client([])
        await #expect(throws: AppError.openRouterMissingKey) {
            try await client.transcribe(wav: Fixtures.wav, model: "google/gemini-3.8-flash", systemPrompt: nil, effort: .high,
                                        apiKey: "  ", timeout: 120)
        }
    }

    @Test func keyInfoDecodes() async throws {
        let (client, host) = StubURLProtocol.client([.init(body: Fixtures.keyInfo)])
        let info = try await client.keyInfo(apiKey: "sk-or-v1-abc")
        #expect(info.label == "sk-or-v1-au7...890")
        #expect(info.limit == 100)
        #expect(info.limitRemaining == 74.5)
        #expect(info.usage == 25.5)
        #expect(info.isFreeTier == false)
        #expect(info.expiresAt == ISO8601DateFormatter().date(from: "2027-12-31T23:59:59Z"))
        #expect(StubURLProtocol.registry.requests(for: host).first?.url?.path == "/api/v1/key")
    }

    @Test func keyInfoRejectsInvalidKey() async throws {
        let (client, _) = StubURLProtocol.client([.init(status: 401, body: #"{"error":{"message":"User not found.","code":401}}"#)])
        await #expect(throws: AppError.openRouterInvalidKey("User not found.")) {
            try await client.keyInfo(apiKey: "sk-or-v1-invalid")
        }
    }
}

// MARK: - Key info and account

@Suite struct KeyInfoTests {
    @Test func unlimitedKeyWithNullsAndFractionalDate() throws {
        let json = #"{"data":{"label":"transcribe-thing","limit":null,"limit_remaining":null,"usage":1.23,"is_free_tier":true,"expires_at":"2027-01-02T03:04:05.678Z"}}"#
        let info = try JSONDecoder().decode(OpenRouterDataEnvelope<OpenRouterKeyInfo>.self, from: Data(json.utf8)).data.keyInfo
        #expect(info.label == "transcribe-thing")
        #expect(info.limit == nil)
        #expect(info.limitRemaining == nil)
        #expect(info.usage == 1.23)
        #expect(info.isFreeTier)
        let expires = try #require(info.expiresAt)
        #expect(abs(expires.timeIntervalSince1970 - 1_798_859_045.678) < 0.01)
    }

    @Test func statusFromLimits() {
        #expect(OpenRouterAccount.status(for: KeyInfo(limit: 10, limitRemaining: 0)) == .noCredit(KeyInfo(limit: 10, limitRemaining: 0)))
        #expect(OpenRouterAccount.status(for: KeyInfo(limit: 10, limitRemaining: -0.5)) == .noCredit(KeyInfo(limit: 10, limitRemaining: -0.5)))
        #expect(OpenRouterAccount.status(for: KeyInfo(limit: 10, limitRemaining: 4)) == .valid(KeyInfo(limit: 10, limitRemaining: 4)))
        #expect(OpenRouterAccount.status(for: KeyInfo(usage: 3)) == .valid(KeyInfo(usage: 3)))
    }

    @Test func statusFromErrors() {
        #expect(OpenRouterAccount.status(for: AppError.openRouterInvalidKey("User not found."), lastInfo: nil) == .invalid("User not found."))
        #expect(OpenRouterAccount.status(for: AppError.offline, lastInfo: nil) == .offline)
        #expect(OpenRouterAccount.status(for: AppError.openRouterNoCredits("x"), lastInfo: nil) == .noCredit(nil))
    }

    @Test func maskingAndSanitizing() {
        #expect(OpenRouterAccount.mask("sk-or-v1-0123456789abcdef3f9a") == "sk-or-v1-••••3f9a")
        #expect(OpenRouterAccount.mask("abc") == "••••")
        #expect(OpenRouterAccount.sanitize("  Bearer sk-or-v1-abc\n") == "sk-or-v1-abc")
        #expect(OpenRouterAccount.sanitize("sk-or-v1-a b\tc") == "sk-or-v1-abc")
    }
}

@MainActor
@Suite struct OpenRouterAccountTests {
    private func account(_ replies: [StubURLProtocol.Reply], keychain: KeychainStore = .inMemory()) -> OpenRouterAccount {
        OpenRouterAccount(keychain: keychain, client: StubURLProtocol.client(replies).0, debounce: .zero)
    }

    @Test func setKeyStoresMasksAndValidates() async {
        let keychain = KeychainStore.inMemory()
        let account = account([.init(body: Fixtures.keyInfo)], keychain: keychain)
        await account.setKey("  sk-or-v1-0123456789abcdef3f9a \n")
        #expect(keychain.read(KeychainStore.openRouterAccount) == "sk-or-v1-0123456789abcdef3f9a")
        #expect(account.apiKey() == "sk-or-v1-0123456789abcdef3f9a")
        #expect(account.maskedKey == "sk-or-v1-••••3f9a")
        guard case .valid(let info) = account.status else {
            Issue.record("expected valid, got \(account.status)")
            return
        }
        #expect(info.limitRemaining == 74.5)
    }

    @Test func exhaustedLimitIsNoCredit() async {
        let body = #"{"data":{"label":"k","limit":5,"limit_remaining":0,"usage":5,"is_free_tier":false}}"#
        let account = account([.init(body: body)])
        await account.setKey("sk-or-v1-abcdef")
        #expect(account.status == .noCredit(KeyInfo(label: "k", limit: 5, limitRemaining: 0, usage: 5)))
    }

    @Test func rejectedKey() async {
        let account = account([.init(status: 401, body: #"{"error":{"message":"User not found.","code":401}}"#)])
        await account.setKey("sk-or-v1-invalid")
        #expect(account.status == .invalid("User not found."))
    }

    @Test func offlineKeepsTheKey() async {
        let account = account([.init(error: .notConnectedToInternet)])
        await account.setKey("sk-or-v1-abcdef")
        #expect(account.status == .offline)
        #expect(account.apiKey() == "sk-or-v1-abcdef")
    }

    @Test func removeKeyClearsEverything() async {
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-abcdef"])
        let account = account([], keychain: keychain)
        #expect(account.apiKey() == "sk-or-v1-abcdef")
        account.removeKey()
        #expect(account.status == .missing)
        #expect(account.maskedKey == nil)
        #expect(account.apiKey() == nil)
        #expect(keychain.read(KeychainStore.openRouterAccount) == nil)
    }

    @Test func cancellingTheCallerDoesntStrandTheCheck() async throws {
        // Onboarding's key field: the next keystroke cancels the debounce task that is saving the key.
        let account = OpenRouterAccount(keychain: .inMemory(), client: StubURLProtocol.client([.init(body: Fixtures.keyInfo)]).0,
                                        debounce: .milliseconds(150))
        let caller = Task { await account.setKey("sk-or-v1-abcdef") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(account.status == .checking)
        caller.cancel()
        try await waitUntil { account.status != .checking }
        guard case .valid = account.status else {
            Issue.record("expected valid, got \(account.status)")
            return
        }
    }

    @Test func validateWithoutKeyIsMissing() async {
        let account = account([])
        await account.validate()
        #expect(account.status == .missing)
    }

    @Test func cloudFailuresUpdateStatus() {
        let account = account([])
        account.noteCloudFailure(.openRouterInvalidKey("revoked"))
        #expect(account.status == .invalid("revoked"))
        account.noteCloudFailure(.openRouterNoCredits("empty"))
        #expect(account.status == .noCredit(nil))
    }

    @Test func aWorkingDictationClearsAStaleNoCredit() async throws {
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-abcdef"])
        let account = account([.init(body: Fixtures.keyInfo)], keychain: keychain)
        account.noteCloudFailure(.openRouterNoCredits("empty"))
        #expect(account.status == .noCredit(nil))
        // The user topped up; the next Gemini dictation goes through.
        account.noteCloudSuccess()
        try await waitUntil { if case .valid = account.status { true } else { false } }
    }

    @Test func aRefusedDictationRechecksARejectedKeyAtMostSoOften() async throws {
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-abcdef"])
        let account = account([.init(body: Fixtures.keyInfo)], keychain: keychain)
        // One request's 401 during a brief OpenRouter outage.
        account.noteCloudFailure(.openRouterInvalidKey("User not found."))
        account.refreshIfStale(maxAge: 30)
        try await waitUntil { if case .valid = account.status { true } else { false } }
        let checked = try #require(account.lastCheckedAt)
        account.noteCloudFailure(.openRouterInvalidKey("User not found."))
        account.refreshIfStale(maxAge: 30, now: checked.addingTimeInterval(5))
        #expect(account.status == .invalid("User not found."), "checked 5 s ago: no new request")
    }

    @Test func keyLimitFetchesTheKeyToSayWhatRanOut() async throws {
        let body = #"{"data":{"label":"k","limit":5,"limit_remaining":0,"usage":5,"is_free_tier":false}}"#
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-abcdef"])
        let account = account([.init(body: body)], keychain: keychain)
        account.noteCloudFailure(.openRouterKeyLimit("Key limit exceeded"))
        try await waitUntil { if case .noCredit = account.status { true } else { false } }
        #expect(account.status.isKeyLimitReached)
        #expect(!KeyStatus.noCredit(nil).isKeyLimitReached)
    }

    @Test func aRefusedKeychainReadIsNotAMissingKey() async throws {
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-abcdef"])
        keychain.simulateReadFailure(-128) // errSecUserCanceled: the prompt was dismissed
        let account = account([.init(body: Fixtures.keyInfo)], keychain: keychain)
        await account.validate()
        #expect(account.status == .failed(OpenRouterAccount.keychainReadFailedMessage))
        #expect(account.isKeyUnreadable)
        // Dictations don't raise the prompt again...
        keychain.simulateReadFailure(nil)
        #expect(account.apiKey() == nil)
        // ..."Check again" does.
        await account.validate()
        #expect(account.apiKey() == "sk-or-v1-abcdef")
        #expect(!account.isKeyUnreadable)
        guard case .valid = account.status else {
            Issue.record("expected valid, got \(account.status)")
            return
        }
    }
}

// MARK: - Download progress

@Suite struct DownloadRateEstimatorTests {
    private let total: Int64 = 600_000_000

    @Test func nothingIsReportedDuringWarmUp() {
        var estimator = DownloadRateEstimator(totalBytes: total)
        let first = estimator.progress(fraction: 0.10, at: 100)
        #expect(first.bytesReceived == 60_000_000)
        #expect(first.totalBytes == total)
        #expect(first.bytesPerSecond == nil)
        let early = estimator.progress(fraction: 0.11, at: 101)
        #expect(early.bytesPerSecond == nil)
        #expect(early.secondsRemaining == nil)
    }

    @Test func steadyRateGivesExactSpeedAndETA() throws {
        var estimator = DownloadRateEstimator(totalBytes: total)
        var progress = estimator.progress(fraction: 0, at: 0)
        // 10 MB/s, sampled every 0.5 s for 20 s.
        for step in 1...40 {
            let t = Double(step) * 0.5
            progress = estimator.progress(fraction: t * 10_000_000 / Double(total), at: t)
        }
        let rate = try #require(progress.bytesPerSecond)
        #expect(abs(rate - 10_000_000) < 10_000)
        let eta = try #require(progress.secondsRemaining)
        #expect(abs(eta - 40) < 1.5, "400 MB left at 10 MB/s")
        #expect(progress.percent == 33)
    }

    @Test func rateFollowsASlowdownSmoothly() throws {
        var estimator = DownloadRateEstimator(totalBytes: total)
        var bytes = 0.0
        var t = 0.0
        _ = estimator.progress(fraction: 0, at: 0)
        for _ in 0..<20 { t += 0.5; bytes += 5_000_000; _ = estimator.progress(fraction: bytes / Double(total), at: t) }
        t += 0.5; bytes += 2_500_000
        let right = try #require(estimator.progress(fraction: bytes / Double(total), at: t).bytesPerSecond)
        #expect(right > 7_000_000, "one slow sample must not halve the displayed rate")
        var settled = 0.0
        for _ in 0..<30 { t += 0.5; bytes += 2_500_000; settled = estimator.progress(fraction: bytes / Double(total), at: t).bytesPerSecond ?? 0 }
        #expect(abs(settled - 5_000_000) < 250_000)
    }

    @Test func resumedDownloadDoesNotCountExistingBytesAsSpeed() throws {
        var estimator = DownloadRateEstimator(totalBytes: total)
        _ = estimator.progress(fraction: 0.5, at: 0)
        var last = DownloadProgress.zero
        for step in 1...10 {
            let t = Double(step) * 0.5
            last = estimator.progress(fraction: 0.5 + t * 2_000_000 / Double(total), at: t)
        }
        let rate = try #require(last.bytesPerSecond)
        #expect(abs(rate - 2_000_000) < 20_000)
    }

    @Test func completionReportsZeroRemaining() {
        var estimator = DownloadRateEstimator(totalBytes: total)
        _ = estimator.progress(fraction: 0.9, at: 0)
        let done = estimator.progress(fraction: 1, at: 0.1)
        #expect(done.secondsRemaining == 0)
        #expect(done.percent == 100)
        #expect(done.bytesReceived == total)
    }
}

// MARK: - Install detection on disk

@Suite struct InstallDetectionTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-thing-engines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, bytes: Int = 4) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func fakeParakeet(in root: URL) throws -> URL {
        let repo = root.appendingPathComponent("parakeet-tdt-0.6b-v3")
        for bundle in ["Preprocessor.mlmodelc", "Encoder_v2.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
            for inner in ["coremldata.bin", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"] {
                try write(repo.appendingPathComponent(bundle).appendingPathComponent(inner))
            }
        }
        try write(repo.appendingPathComponent("parakeet_vocab.json"))
        try write(repo.appendingPathComponent("parakeet_v3_vocab.json"))
        try write(repo.appendingPathComponent("config.json"))
        return repo
    }

    @Test func parakeetNeedsEveryCompiledFileAndNoPartials() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ParakeetEngine(modelsRoot: root)
        #expect(engine.repoDirectory.lastPathComponent == "parakeet-tdt-0.6b-v3")
        #expect(!engine.isInstalled())

        let repo = try fakeParakeet(in: root)
        #expect(engine.isInstalled())

        let partial = repo.appendingPathComponent("Encoder_v2.mlmodelc/weights/weight.bin.partial")
        try write(partial)
        #expect(!engine.isInstalled(), "an interrupted download leaves *.partial files")
        try FileManager.default.removeItem(at: partial)
        #expect(engine.isInstalled())

        try FileManager.default.removeItem(at: repo.appendingPathComponent("Encoder_v2.mlmodelc/weights/weight.bin"))
        #expect(!engine.isInstalled(), "bundle folders alone don't make an install")
    }

    @Test func parakeetWithTheOtherEncoderIsNotInstalled() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try fakeParakeet(in: root)
        try FileManager.default.moveItem(at: repo.appendingPathComponent("Encoder_v2.mlmodelc"),
                                         to: repo.appendingPathComponent("Encoder.mlmodelc"))
        #expect(!ParakeetEngine(modelsRoot: root).isInstalled())
    }

    @Test func treeListingParsesFilesAndLFSSizes() throws {
        let json = #"""
        [{"type":"directory","oid":"a","size":0,"path":"Encoder_v2.mlmodelc"},
         {"type":"file","oid":"b","size":135,"path":"Encoder_v2.mlmodelc/weights/weight.bin","lfs":{"oid":"c","size":594211328,"pointerSize":135}},
         {"type":"file","oid":"d","size":475,"path":"config.json"}]
        """#
        let files = try HuggingFaceTree.parse(Data(json.utf8))
        #expect(files == [.init(path: "Encoder_v2.mlmodelc/weights/weight.bin", size: 594_211_328),
                          .init(path: "config.json", size: 475)])
        let link = #"<https://huggingface.co/api/models/x/tree/main?recursive=1&cursor=abc>; rel="next""#
        #expect(HuggingFaceTree.nextPage(fromLinkHeader: link)?.absoluteString
                == "https://huggingface.co/api/models/x/tree/main?recursive=1&cursor=abc")
    }
}

// MARK: - Inference gate

actor ConcurrencyProbe {
    private(set) var running = 0
    private(set) var peak = 0
    private(set) var finished: [Int] = []

    func enter() { running += 1; peak = max(peak, running) }
    func leave(_ id: Int) { running -= 1; finished.append(id) }
}

@Suite struct InferenceGateTests {
    @Test func neverRunsTwoOperationsAtOnce() async throws {
        let gate = InferenceGate()
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<16 {
                group.addTask {
                    try await gate.run {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(3))
                        await probe.leave(id)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.peak == 1)
        #expect(await probe.finished.count == 16)
    }

    @Test func cancelledWaiterLeavesTheQueueWithoutRunning() async throws {
        let gate = InferenceGate()
        let probe = ConcurrencyProbe()
        let holder = Task {
            try await gate.run { try await Task.sleep(for: .milliseconds(300)) }
        }
        try await Task.sleep(for: .milliseconds(30))
        let waiter = Task {
            try await gate.run { await probe.enter() }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await gate.queueLength == 1)
        let cancelledAt = ContinuousClock.now
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(cancelledAt.duration(to: .now) < .milliseconds(200), "didn't wait for the holder")
        #expect(await probe.peak == 0)
        try await holder.value
        let after = try await gate.run { 42 }
        #expect(after == 42, "the gate still works")
    }

    @Test func errorsReleaseTheGate() async throws {
        struct Boom: Error {}
        let gate = InferenceGate()
        await #expect(throws: Boom.self) { try await gate.run { throw Boom() } }
        #expect(try await gate.run { "ok" } == "ok")
    }
}

// MARK: - ModelStore with fake engines

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}

/// Lets a test drive a fake operation step by step instead of racing it against the clock. The fake calls
/// `pass()` before each step and is held there until the test opens the gate; cancelling the fake's task
/// makes a held (or arriving) `pass()` throw `CancellationError`.
final class StepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var permits = 0
    private var isOpen = false
    private var held: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var arrivals = 0
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelled = 0

    /// How many `pass()` calls ended in `CancellationError`.
    var cancellations: Int { lock.withLock { cancelled } }

    func pass() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (arrived, outcome) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Result<Void, Error>?) in
                    arrivals += 1
                    let arrived = arrivalWaiters.filter { $0.count <= arrivals }.map(\.continuation)
                    arrivalWaiters.removeAll { $0.count <= arrivals }
                    // The cancelled flag is set before `onCancel` runs, and `onCancel` takes the lock: a
                    // cancellation is either seen here or finds this call in `held`.
                    if Task.isCancelled {
                        cancelled += 1
                        return (arrived, .failure(CancellationError()))
                    }
                    if isOpen { return (arrived, .success(())) }
                    if permits > 0 {
                        permits -= 1
                        return (arrived, .success(()))
                    }
                    held.append((id, continuation))
                    return (arrived, nil)
                }
                arrived.forEach { $0.resume() }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = held.firstIndex(where: { $0.id == id }) else { return nil }
                cancelled += 1
                return held.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Lets `steps` more `pass()` calls through, releasing held ones first.
    func open(_ steps: Int = 1) {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let count = min(steps, held.count)
            let released = held.prefix(count).map(\.continuation)
            held.removeFirst(count)
            permits += steps - count
            return released
        }
        released.forEach { $0.resume() }
    }

    /// Lets every current and future `pass()` through.
    func openForGood() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            isOpen = true
            defer { held.removeAll() }
            return held.map(\.continuation)
        }
        released.forEach { $0.resume() }
    }

    /// Returns once `pass()` has been called `count` times in total (held or not).
    func arrival(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = lock.withLock {
                if arrivals >= count { return true }
                arrivalWaiters.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }
}

actor FakeEngine: LocalEngine {
    nonisolated let engineID: EngineID
    nonisolated let storageURLs: [URL] = []
    nonisolated let installed: Flag
    var loadDelay: Duration = .milliseconds(10)
    var loadError: Error?
    var transcript: String
    var downloadSteps: [Double] = [0.25, 0.5, 0.75]
    var downloadError: Error?
    /// When set, `download` waits at this gate before each progress step (otherwise it runs straight through).
    private(set) var downloadGate: StepGate?
    /// When set, `load` waits at this gate instead of sleeping for `loadDelay`.
    private(set) var loadGate: StepGate?
    private(set) var loaded = false
    private(set) var loadCount = 0
    private(set) var transcribeCount = 0

    init(_ id: EngineID, installed: Bool, transcript: String = "hello from the fake") {
        engineID = id
        self.installed = Flag(installed)
        self.transcript = transcript
    }

    func configure(loadDelay: Duration? = nil, loadError: Error? = nil, downloadError: Error? = nil) {
        if let loadDelay { self.loadDelay = loadDelay }
        self.loadError = loadError
        self.downloadError = downloadError
    }

    /// From now on every download waits for the test to open the returned gate before each step.
    func gateDownloads() -> StepGate {
        let gate = StepGate()
        downloadGate = gate
        return gate
    }

    /// From now on every load waits for the test to open the returned gate.
    func gateLoads() -> StepGate {
        let gate = StepGate()
        loadGate = gate
        return gate
    }

    nonisolated func isInstalled() -> Bool { installed.get() }
    func remoteDownloadBytes() async -> Int64 { 1_000_000 }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        for step in downloadSteps {
            if let downloadGate { try await downloadGate.pass() } else { await Task.yield() }
            progress(step)
        }
        if let downloadError { throw downloadError }
        installed.set(true)
        progress(1)
    }

    var isLoaded: Bool { loaded }

    func load() async throws {
        loadCount += 1
        if let loadGate { try await loadGate.pass() } else { try await Task.sleep(for: loadDelay) }
        if let loadError { throw loadError }
        loaded = true
    }

    func unload() async { loaded = false }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard loaded else { throw LocalEngineError.notLoaded }
        transcribeCount += 1
        return transcript
    }

    func deleteFiles() async throws {
        loaded = false
        installed.set(false)
    }
}

struct FakeFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Resumes a continuation at most once, whichever of several racing events comes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func resume(_ value: Value) {
        lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }?.resume(returning: value)
    }
}

/// Waits until `condition` holds, re-evaluating it each time an observable property it read changes, so no
/// state it passes through is sampled or missed by a timer. Records an issue after `timeout`.
@MainActor
func waitForObserved(timeout: Duration = .seconds(30), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while true {
        var timer: Task<Void, Never>?
        let met = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let met = withObservationTracking(condition, onChange: { once.resume(false) })
            if met { return once.resume(true) }
            timer = Task {
                try? await Task.sleep(until: deadline)
                once.resume(false)
            }
        }
        timer?.cancel()
        if met { return }
        if ContinuousClock.now >= deadline {
            Issue.record("timed out waiting")
            return
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ModelStoreTests {
    private func makeStore(installed: Bool = true, freeBytes: Int64 = 50_000_000_000, selected: EngineID = .parakeet)
        -> (ModelStore, FakeEngine, AppSettings) {
        let settings = AppSettings.inMemory()
        settings.selectedEngine = selected
        let parakeet = FakeEngine(.parakeet, installed: installed)
        let store = ModelStore(paths: .temporary(), settings: settings, engines: [.parakeet: parakeet],
                               gate: InferenceGate(), freeDiskBytes: { freeBytes })
        return (store, parakeet, settings)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        await waitForObserved(condition)
    }

    @Test func startScansAndPreparesTheSelectedModel() async throws {
        let (store, parakeet, _) = makeStore()
        store.start()
        await waitUntil { store.state(of: .parakeet) == .ready }
        #expect(await parakeet.isLoaded)
    }

    @Test func downloadReportsProgressThenInstallsAndPreparesWhenSelected() async throws {
        let (store, parakeet, _) = makeStore(installed: false)
        var finished: [EngineID] = []
        store.onDownloadFinished = { finished.append($0) }
        await store.refreshFromDisk()
        #expect(store.state(of: .parakeet) == .notInstalled)
        let gate = await parakeet.gateDownloads()
        store.download(.parakeet)
        #expect(store.state(of: .parakeet).isDownloading)
        // The fake holds each step until the gate opens, so every fraction stays on screen until it's seen.
        for fraction in [0.25, 0.5, 0.75] {
            gate.open()
            await waitUntil { store.state(of: .parakeet).downloadProgress?.fraction == fraction }
            #expect(store.state(of: .parakeet).downloadProgress?.totalBytes == 1_000_000)
            #expect(finished.isEmpty)
        }
        await waitUntil { store.state(of: .parakeet) == .ready }
        #expect(finished == [.parakeet])
        #expect(await parakeet.isLoaded)
    }

    @Test func downloadOfAnUnselectedModelStopsAtInstalled() async throws {
        let (store, _, _) = makeStore(installed: false, selected: .parakeetCloud)
        store.download(.parakeet)
        await waitUntil { store.state(of: .parakeet) == .installed }
    }

    @Test func notEnoughDiskFailsBeforeDownloading() async throws {
        let (store, parakeet, _) = makeStore(installed: false, freeBytes: 100_000_000)
        var failures: [AppError] = []
        store.onFailure = { _, error in failures.append(error) }
        store.download(.parakeet)
        await waitUntil { if case .failed = store.state(of: .parakeet) { true } else { false } }
        let needed = Int64((Double(EngineID.parakeet.approxDownloadBytes!) * 1.25).rounded(.up))
        #expect(store.lastErrors[.parakeet] == .notEnoughDisk(needed: needed, available: 100_000_000))
        #expect(failures == [.notEnoughDisk(needed: needed, available: 100_000_000)])
        #expect(!parakeet.isInstalled())
    }

    @Test func downloadFailureIsReported() async throws {
        let (store, parakeet, _) = makeStore(installed: false)
        await parakeet.configure(downloadError: URLError(.notConnectedToInternet))
        store.download(.parakeet)
        await waitUntil { if case .failed = store.state(of: .parakeet) { true } else { false } }
        #expect(store.state(of: .parakeet) == .failed("Download didn’t finish. No internet connection."))
        #expect(store.lastErrors[.parakeet] == .downloadFailed(.parakeet, "No internet connection."))
    }

    @Test func cancelledDownloadReturnsQuietly() async throws {
        let (store, parakeet, _) = makeStore(installed: false)
        let gate = await parakeet.gateDownloads()
        var failures = 0
        store.onFailure = { _, _ in failures += 1 }
        store.download(.parakeet)
        gate.open()
        await waitUntil { store.state(of: .parakeet).downloadProgress?.fraction == 0.25 }
        // Mid-download: the fake has reported a step and is held before the next one.
        store.cancelDownload(.parakeet)
        #expect(store.state(of: .parakeet) == .notInstalled)
        await store.waitForDownloadToSettle(.parakeet)
        #expect(gate.cancellations == 1, "the engine's download saw the cancellation")
        #expect(store.state(of: .parakeet) == .notInstalled)
        #expect(store.lastErrors[.parakeet] == nil)
        #expect(failures == 0)
        #expect(!parakeet.isInstalled())
    }

    @Test func downloadRestartedRightAfterCancelFinishes() async throws {
        let (store, parakeet, _) = makeStore(installed: false, selected: .parakeetCloud)
        let gate = await parakeet.gateDownloads()
        store.download(.parakeet)
        await gate.arrival(1)
        // The first run is inside the engine's download, held before its first step.
        store.cancelDownload(.parakeet)
        store.download(.parakeet)
        #expect(store.state(of: .parakeet).isDownloading)
        // The restart reaches the engine only after the cancelled run has fully unwound.
        await gate.arrival(2)
        #expect(gate.cancellations == 1)
        #expect(store.state(of: .parakeet).isDownloading, "the cancelled run must not reset the new one")
        gate.openForGood()
        await waitUntil { store.state(of: .parakeet) == .installed }
        await store.waitForDownloadToSettle(.parakeet)
        #expect(store.state(of: .parakeet) == .installed)
    }

    @Test func transcribeWaitsForPreparing() async throws {
        let (store, parakeet, _) = makeStore()
        await parakeet.configure(loadDelay: .milliseconds(250))
        await store.refreshFromDisk()
        store.prepare(.parakeet)
        #expect(store.state(of: .parakeet).isPreparing)
        let text = try await store.transcribeLocal(.parakeet, samples: [0, 0.1])
        #expect(text == "hello from the fake")
        #expect(store.state(of: .parakeet) == .ready)
    }

    @Test func transcribeLoadsAnInstalledModelOnDemand() async throws {
        let (store, _, _) = makeStore()
        await store.refreshFromDisk()
        #expect(store.state(of: .parakeet) == .installed)
        #expect(try await store.transcribeLocal(.parakeet, samples: [0]) == "hello from the fake")
    }

    @Test func missingModelThrowsNotDownloaded() async throws {
        let (store, _, _) = makeStore(installed: false)
        await store.refreshFromDisk()
        await #expect(throws: AppError.modelNotDownloaded(.parakeet)) {
            try await store.transcribeLocal(.parakeet, samples: [0])
        }
    }

    @Test func loadFailureSurfacesAsModelLoadFailed() async throws {
        let (store, parakeet, _) = makeStore()
        await parakeet.configure(loadError: FakeFailure(message: "corrupt weights"))
        await store.refreshFromDisk()
        store.prepare(.parakeet)
        await waitUntil { if case .failed = store.state(of: .parakeet) { true } else { false } }
        #expect(store.lastErrors[.parakeet] == .modelLoadFailed(.parakeet, "corrupt weights"))
        await #expect(throws: AppError.modelLoadFailed(.parakeet, "corrupt weights")) {
            try await store.transcribeLocal(.parakeet, samples: [0])
        }
        #expect(store.state(of: .parakeet) == .failed("Couldn’t load the model. Retry, or download it again."))
        #expect(await parakeet.loadCount == 2, "one retry per dictation")
    }

    @Test func retryAfterAFailedLoadLoadsAgainInsteadOfDownloading() async throws {
        let (store, parakeet, _) = makeStore()
        await parakeet.configure(loadError: FakeFailure(message: "boom"))
        await store.refreshFromDisk()
        store.prepare(.parakeet)
        await waitUntil { if case .failed = store.state(of: .parakeet) { true } else { false } }
        await parakeet.configure()
        store.download(.parakeet)
        #expect(store.state(of: .parakeet).isPreparing)
        await waitUntil { store.state(of: .parakeet) == .ready }
        #expect(store.lastErrors[.parakeet] == nil)
    }

    @Test func reinstallReplacesAModelThatWontLoad() async throws {
        let (store, parakeet, _) = makeStore()
        await parakeet.configure(loadError: FakeFailure(message: "corrupt weights"))
        store.start()
        await waitUntil { if case .failed = store.state(of: .parakeet) { true } else { false } }
        await parakeet.configure()
        await store.reinstall(.parakeet)
        #expect(store.state(of: .parakeet).isDownloading)
        await waitUntil { store.state(of: .parakeet) == .ready }
        #expect(store.lastErrors[.parakeet] == nil)
        #expect(await parakeet.loadCount == 2)
    }

    @Test func selectingACloudEngineKeepsTheLocalModelLoaded() async throws {
        let (store, parakeet, settings) = makeStore()
        store.start()
        await waitUntil { store.state(of: .parakeet) == .ready }
        store.select(.parakeetCloud)
        #expect(settings.selectedEngine == .parakeetCloud)
        #expect(store.state(of: .parakeet) == .ready)
        #expect(await parakeet.isLoaded)
    }

    @Test func deleteUnloadsAndRemoves() async throws {
        let (store, parakeet, _) = makeStore()
        store.start()
        await waitUntil { store.state(of: .parakeet) == .ready }
        await store.delete(.parakeet)
        #expect(store.state(of: .parakeet) == .notInstalled)
        #expect(!parakeet.isInstalled())
        #expect(await !parakeet.isLoaded)
    }

    @Test func cancellingAWaitingJobThrowsCancellation() async throws {
        let (store, parakeet, _) = makeStore()
        let gate = await parakeet.gateLoads()
        await store.refreshFromDisk()
        store.prepare(.parakeet)
        let job = Task { try await store.transcribeLocal(.parakeet, samples: [0]) }
        await gate.arrival(1)
        // The load is held, so the job can only be waiting for it (or not started yet).
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(store.state(of: .parakeet).isPreparing)
        gate.openForGood()
        await waitUntil { store.state(of: .parakeet) == .ready }
    }

    @Test func previewStoreNeverTouchesEngines() {
        let ready = ModelStore.preview(states: [.parakeet: .ready])
        ready.start()
        ready.prepare(.parakeet)
        #expect(ready.state(of: .parakeet) == .ready)
        #expect(ready.diskUsageBytes == EngineID.parakeet.approxDownloadBytes)

        let downloading = ModelStore.preview(states: [.parakeet: .downloading(DownloadProgress(fraction: 0.4))])
        downloading.download(.parakeet)
        downloading.cancelDownload(.parakeet)
        #expect(downloading.state(of: .parakeet).downloadProgress?.fraction == 0.4)
        #expect(downloading.diskUsageBytes == 0)
    }
}

// MARK: - TranscriptionService

@MainActor
@Suite struct TranscriptionServiceTests {
    private func makeService(replies: [StubURLProtocol.Reply] = [], key: String? = "sk-or-v1-test",
                             prompt: String = "", keychainFailure: OSStatus? = nil) -> (TranscriptionService, ModelStore) {
        let made = makeServiceAndAccount(replies: replies, key: key, prompt: prompt, keychainFailure: keychainFailure)
        return (made.0, made.1)
    }

    private func makeServiceAndAccount(replies: [StubURLProtocol.Reply] = [], key: String? = "sk-or-v1-test",
                                       prompt: String = "", keychainFailure: OSStatus? = nil,
                                       localTranscript: String = "hello from the fake")
        -> (TranscriptionService, ModelStore, OpenRouterAccount) {
        let settings = AppSettings.inMemory()
        settings.geminiSystemPrompt = prompt
        let store = ModelStore(paths: .temporary(), settings: settings,
                               engines: [.parakeet: FakeEngine(.parakeet, installed: true, transcript: localTranscript)],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        let client = StubURLProtocol.client(replies).0
        let keychain = KeychainStore.inMemory(key.map { [KeychainStore.openRouterAccount: $0] } ?? [:])
        keychain.simulateReadFailure(keychainFailure)
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        return (TranscriptionService(models: store, account: account, client: client, settings: settings), store, account)
    }

    private func speech(seconds: Double = 1) -> Recording {
        Recording(samples: (0..<Int(seconds * 16_000)).map { 0.1 * sin(Float($0) * 0.09) })
    }

    @Test func localRoute() async throws {
        let (service, store) = makeService()
        await store.refreshFromDisk()
        let result = try await service.transcribe(speech(), engine: .parakeet)
        #expect(result.text == "hello from the fake")
        #expect(result.engine == .parakeet)
        #expect(result.processingTime > 0)
        #expect(result.costUSD == nil)
    }

    @Test func cloudRoute() async throws {
        let (service, _) = makeService(replies: [Fixtures.success])
        let result = try await service.transcribe(speech(), engine: .geminiFlash)
        #expect(result.text == "Hello there.")
        #expect(result.engine == .geminiFlash)
        #expect(result.costUSD == 0.001)
    }

    /// Settings that were never changed send the default prompt as the system message; cleared, only the audio.
    @Test func geminiGetsTheDefaultPromptUntilItIsCleared() async throws {
        for (clear, expected) in [(false, AppSettings.defaultGeminiSystemPrompt as String?), (true, nil)] {
            let settings = AppSettings.inMemory()
            if clear { settings.geminiSystemPrompt = "" }
            let store = ModelStore(paths: .temporary(), settings: settings, engines: [:], gate: InferenceGate(),
                                   freeDiskBytes: { 50_000_000_000 })
            let (client, host) = StubURLProtocol.client([Fixtures.success])
            let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-test"])
            let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
            let service = TranscriptionService(models: store, account: account, client: client, settings: settings)
            let result = try await service.transcribe(speech(), engine: .geminiFlash)
            #expect(result.usedSystemPrompt == (expected != nil))
            let body = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.registry.bodies(for: host)[0]) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            if let expected {
                #expect(messages.count == 2)
                #expect(messages[0]["role"] as? String == "system")
                #expect(messages[0]["content"] as? String == expected)
            } else {
                #expect(messages.count == 1)
                #expect(messages[0]["role"] as? String == "user")
            }
        }
    }

    @Test func cloudWithoutKey() async throws {
        let (service, _) = makeService(key: nil)
        await #expect(throws: AppError.openRouterMissingKey) {
            try await service.transcribe(speech(), engine: .geminiPro)
        }
    }

    /// Whatever the audio sounded like, an answer with no text means Gemini heard no speech: an empty result,
    /// never an error.
    @Test func emptyCloudTextIsAnEmptyResult() async throws {
        for recording in [Recording(samples: [Float](repeating: 0, count: 16_000)), speech()] {
            let empty = StubURLProtocol.Reply(body: #"{"choices":[{"finish_reason":"stop","message":{"content":" \n"}}],"usage":{"cost":0.0002}}"#)
            let (service, _) = makeService(replies: [empty])
            let result = try await service.transcribe(recording, engine: .geminiFlash)
            #expect(result.text.isEmpty)
            #expect(result.engine == .geminiFlash)
            #expect(result.costUSD == 0.0002)
        }
    }

    @Test func emptyLocalTextIsAnEmptyResult() async throws {
        let (service, store, _) = makeServiceAndAccount(localTranscript: "  \n ")
        await store.refreshFromDisk()
        let result = try await service.transcribe(speech(), engine: .parakeet)
        #expect(result.text.isEmpty)
        #expect(result.engine == .parakeet)
    }

    @Test func tooLongForGeminiIsRefusedBeforeEncoding() async throws {
        let (service, _) = makeService(replies: [Fixtures.success])
        let long = Recording(samples: [Float](repeating: 0.1, count: 8 * 60 * 16_000))
        await #expect(throws: AppError.recordingTooLarge) {
            try await service.transcribe(long, engine: .geminiPro)
        }
    }

    @Test func unreadableKeychainIsNotAMissingKey() async throws {
        let (service, _) = makeService(replies: [Fixtures.success], keychainFailure: -128)
        await #expect(throws: AppError.openRouterKeyUnreadable) {
            try await service.transcribe(speech(), engine: .geminiFlash)
        }
    }

    @Test func aWorkingDictationRechecksAKeyMarkedOutOfCredit() async throws {
        let (service, _, account) = makeServiceAndAccount(replies: [Fixtures.success, .init(body: Fixtures.keyInfo)])
        account.noteCloudFailure(.openRouterNoCredits("empty"))
        _ = try await service.transcribe(speech(), engine: .geminiFlash)
        try await waitUntil { if case .valid = account.status { true } else { false } }
    }

    @Test func rejectedKeyUpdatesTheAccount() async throws {
        let (service, _) = makeService(replies: [.init(status: 401, body: #"{"error":{"message":"User not found.","code":401}}"#)])
        await #expect(throws: AppError.openRouterInvalidKey("User not found.")) {
            try await service.transcribe(speech(), engine: .geminiFlash)
        }
    }
}

import Foundation
import Testing
@testable import TranscribeThing

// The user's OpenAI-compatible endpoint (once only their Vertex proxy, hence the type names): its base URL and key,
// the check that costs nothing, and Gemini's requests going to it (and only to it) while it's set up and on. No
// network: every request goes to `StubURLProtocol`.

@MainActor
enum ProxyFixture {
    static let key = "sk-vp-TestKey0123456789abcdefghijklmnopqrstu"
    static let openRouterKey = "sk-or-v1-test"

    /// A stubbed session, as `StubURLProtocol.client` makes one.
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// An endpoint at a host of its own whose requests get `replies`, with `key` saved (none for nil). `path` is the
    /// saved base URL's path: none by default, as the app saved the user's Vertex proxy (read as `/api/v1`).
    static func proxy(_ replies: [StubURLProtocol.Reply] = [], key: String? = key, enabled: Bool = true,
                      settings: AppSettings? = nil, keyReadFails: Bool = false,
                      path: String = "") -> (VertexProxyAccount, String) {
        let settings = settings ?? .inMemory()
        let host = "proxy-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.registry.enqueue(replies, host: host)
        settings.vertexProxyURL = "https://\(host)\(path)"
        settings.cloudProvider = enabled ? .vertexProxy : .openRouter
        let keyStore = KeyFileStore.inMemory(key)
        keyStore.simulateReadFailure(keyReadFails)
        let session = session
        let account = VertexProxyAccount(keyStore: keyStore, settings: settings, makeClient: { apiBase in
            OpenRouterClient(session: session, baseURL: apiBase, retryDelay: 0.01, service: .vertexProxy)
        }, debounce: .zero)
        return (account, host)
    }

    /// A client straight to an endpoint at its own host, its API at `path`.
    static func client(_ replies: [StubURLProtocol.Reply], path: String = "/api/v1") -> (OpenRouterClient, String) {
        let host = "proxy-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.registry.enqueue(replies, host: host)
        let client = OpenRouterClient(session: session, baseURL: URL(string: "https://\(host)\(path)")!,
                                      retryDelay: 0.01, service: .vertexProxy)
        return (client, host)
    }

    /// The service with OpenRouter at one stub host (`openRouterReplies`, `openRouterKey` saved unless nil) and the
    /// proxy (when given) at another.
    static func service(openRouterReplies: [StubURLProtocol.Reply] = [], openRouterKey: String? = openRouterKey,
                        proxy: VertexProxyAccount?) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(openRouterReplies)
        let account = OpenRouterAccount(keyStore: .inMemory(openRouterKey), client: client, debounce: .zero)
        let store = ModelStore(paths: .temporary(), settings: .inMemory(), engines: [:], gate: InferenceGate(),
                               freeDiskBytes: { 50_000_000_000 })
        return (TranscriptionService(models: store, account: account, client: client, proxy: proxy), host)
    }

    static func speech(seconds: Double = 1) -> Recording {
        Recording(samples: (0..<Int(seconds * 16_000)).map { 0.1 * sin(Float($0) * 0.09) })
    }

    /// Gemini's answer as the proxy streams it: OpenRouter's chunks, an id of its own, no provider, and `usage` with
    /// the cost it estimates for Vertex.
    static func answer(_ text: String, cost: Double = 0.0042) -> StubURLProtocol.Reply {
        .stream(SSE.answer("<transcript>\(text)</transcript>", reasoning: "Thinking it over.", id: "chatcmpl-vp1",
                           model: "google/gemini-3.8-flash",
                           usage: #"{"prompt_tokens":120,"completion_tokens":40,"total_tokens":160,"cost":\#(cost),"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":100},"completion_tokens_details":{"reasoning_tokens":12}}"#))
    }

    /// The proxy's error body: OpenAI's shape, `code` a Google status.
    static func error(_ status: Int, _ message: String, code: String) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(status: status, headers: ["Content-Type": "application/json"],
                              body: #"{"error":{"message":"\#(message)","type":"api_error","param":null,"code":"\#(code)"}}"#)
    }

    static let models = StubURLProtocol.Reply(
        headers: ["Content-Type": "application/json"],
        body: #"{"data":[{"id":"google/gemini-3.8-flash","name":"Gemini 3.8 Flash"}],"total_count":1,"links":{"next":null}}"#)

    static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Address and key

@Suite struct VertexProxyAddressTests {
    /// The address the app saved for the user's Vertex proxy before the endpoint was generic, host only, and every
    /// way of writing the same OpenRouter-style API under it: all mean `<host>/api/v1`.
    @Test(arguments: [
        "https://vertex-proxy-2pthtwqema-uc.a.run.app",
        "https://vertex-proxy-2pthtwqema-uc.a.run.app/",
        "https://vertex-proxy-2pthtwqema-uc.a.run.app/api/v1",
        "https://vertex-proxy-2pthtwqema-uc.a.run.app/api/v1/",
        "  https://Vertex-Proxy-2pthtwqema-uc.a.run.app/api/v1/chat/completions \n",
        "vertex-proxy-2pthtwqema-uc.a.run.app",
    ])
    func aHostOnlyURLStillMeansTheAPIUnderApiV1(_ raw: String) throws {
        let base = try VertexProxy.normalizedBaseURL(raw).get()
        #expect(base.absoluteString == "https://vertex-proxy-2pthtwqema-uc.a.run.app/api/v1")
    }

    @Test(arguments: [
        "https://api.example.com/v1",
        "https://api.example.com/v1/",
        "api.example.com/v1",
        " https://API.example.com/v1/chat/completions/ ",
    ])
    func aV1BaseIsKeptAsGiven(_ raw: String) throws {
        let base = try VertexProxy.normalizedBaseURL(raw).get()
        #expect(base.absoluteString == "https://api.example.com/v1")
        #expect(base.appendingPathComponent("chat/completions").absoluteString
                == "https://api.example.com/v1/chat/completions")
        #expect(VertexProxy.displayHost(base) == "api.example.com/v1")
    }

    @Test func anyPathIsKeptAsGiven() throws {
        #expect(try VertexProxy.normalizedBaseURL("https://example.com/proxy/api/v1/").get().absoluteString
                == "https://example.com/proxy/api/v1")
        #expect(try VertexProxy.normalizedBaseURL("https://example.com/openai/v1beta").get().absoluteString
                == "https://example.com/openai/v1beta")
        #expect(try VertexProxy.normalizedBaseURL("https://example.com/v1/chat/completions").get().absoluteString
                == "https://example.com/v1")
    }

    @Test func badAddressesAreRefusedWithAReason() {
        #expect(VertexProxy.normalizedBaseURL("   ") == .failure(.empty))
        #expect(VertexProxy.normalizedBaseURL("http://api.example.com/v1") == .failure(.notHTTPS))
        #expect(VertexProxy.normalizedBaseURL("http:api.example.com") == .failure(.notHTTPS))
        #expect(VertexProxy.normalizedBaseURL("ftp://api.example.com/v1") == .failure(.notHTTPS))
        #expect(VertexProxy.normalizedBaseURL("https://api.example.com/v1?key=sk-x") == .failure(.invalid))
        #expect(VertexProxy.normalizedBaseURL("https://user:pw@api.example.com/v1") == .failure(.invalid))
        #expect(VertexProxy.normalizedBaseURL("https://api.example.com/v1#x") == .failure(.invalid))
        #expect(VertexProxy.normalizedBaseURL("https://") == .failure(.invalid))
    }

    @Test func anyKeyThatIsntEmptyCanBeSaved() {
        #expect(VertexProxy.looksLikeKey(ProxyFixture.key))
        #expect(VertexProxy.looksLikeKey("sk-or-v1-0123456789abcdef"))
        #expect(VertexProxy.looksLikeKey("AIzaSyA-short"))
        #expect(VertexProxy.looksLikeKey("x"))
        #expect(!VertexProxy.looksLikeKey(""))
        #expect(!VertexProxy.looksLikeKey("  \n"))
    }

    @Test func theMaskShowsOnlyADashedPrefixAndTheLastFour() {
        let masked = VertexProxy.mask(ProxyFixture.key)
        #expect(masked == "sk-vp-••••rstu")
        #expect(!masked.contains("TestKey"))
        #expect(VertexProxy.mask("sk-proj-abcdefghijklmnop1234") == "sk-proj-••••1234")
        #expect(VertexProxy.mask("AIzaSyAbcdefghijklmnop9876") == "••••9876")
        #expect(VertexProxy.mask("sk-vp-ab") == "sk-vp-••••", "a short key shows no tail")
        #expect(VertexProxy.mask("abcdefgh") == "••••")
        #expect(VertexProxy.mask("AIzaSyA-bcdefghijklmnop9876") == "••••9876", "no prefix that isn't a kind")
    }

    @Test func messagesAboutOpenRouterAreReworded() {
        #expect(VertexProxy.reword("OpenRouter sent a response it couldn’t read.")
                == "Your endpoint sent a response it couldn’t read.")
        #expect(VertexProxy.reword("The connection to OpenRouter was lost.") == "The connection to your endpoint was lost.")
    }
}

// MARK: - Client

@MainActor
@Suite struct VertexProxyClientTests {
    @Test func geminiGoesToTheProxysChatCompletionsWithBearerKeyAndTheSameModel() async throws {
        let (client, host) = ProxyFixture.client([ProxyFixture.answer("Привет.")])
        let result = try await client.transcribe(audio: Data([1, 2, 3]), format: "m4a", model: "google/gemini-3.8-flash",
                                                 systemPrompt: "Transcribe.", effort: .medium, maxTokens: 32_768,
                                                 apiKey: ProxyFixture.key, timeout: 30)
        #expect(result.text == "Привет.")
        #expect(result.costUSD == 0.0042, "usage.cost, the proxy's estimate, is kept")
        #expect(result.usage?.reasoningTokens == 12)
        #expect(result.provider == host, "no provider in the stream: History names the endpoint by its host")
        #expect(result.generationID == nil, "no generation record to look up on the endpoint")

        let request = try #require(StubURLProtocol.registry.requests(for: host).first)
        #expect(request.url?.absoluteString == "https://\(host)/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(ProxyFixture.key)")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == nil)
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Metadata") == nil)
        let body = ProxyFixture.json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect(body["model"] as? String == "google/gemini-3.8-flash")
        #expect(body["provider"] == nil, "no OpenRouter routing")
        #expect(body["stream"] as? Bool == true)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        let content = (body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "input_audio")
    }

    /// A `/v1` base (the user's proxy serves the same chat completions there, with the same model ids and the same
    /// `reasoning` object): the same request goes to `<base>/chat/completions`, the check to `<base>/models`.
    @Test func aV1BaseGetsTheSameRequestUnderV1() async throws {
        let (client, host) = ProxyFixture.client([ProxyFixture.models, ProxyFixture.answer("Hi.")], path: "/v1")
        try await client.checkProxyKey(apiKey: ProxyFixture.key)
        let result = try await client.transcribe(audio: Data([1]), format: "m4a", model: "google/gemini-3.8-flash",
                                                 systemPrompt: "Transcribe.", effort: .low, maxTokens: 1000,
                                                 apiKey: ProxyFixture.key, timeout: 30)
        #expect(result.text == "Hi.")
        let urls = StubURLProtocol.registry.requests(for: host).map { $0.url?.absoluteString }
        #expect(urls == ["https://\(host)/v1/models", "https://\(host)/v1/chat/completions"])
        let body = ProxyFixture.json(try #require(StubURLProtocol.registry.bodies(for: host).last))
        #expect(body["model"] as? String == "google/gemini-3.8-flash")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func theProviderTheStreamNamesIsKept() async throws {
        let (client, _) = ProxyFixture.client([.stream(SSE.answer("<transcript>Hi.</transcript>",
                                                                  provider: "Google AI Studio", usage: #"{"cost":0.001}"#))])
        let result = try await client.transcribe(audio: Data([1]), format: "m4a", model: "google/gemini-3.8-flash",
                                                 systemPrompt: "Transcribe.", effort: .low, maxTokens: 1000,
                                                 apiKey: ProxyFixture.key, timeout: 30)
        #expect(result.provider == "Google AI Studio")
    }

    @Test func aTextRequestAsksForNoMoreTokensThanVertexAllows() async throws {
        let (client, host) = ProxyFixture.client([.stream(SSE.answer("Fixed.", usage: #"{"cost":0.01}"#))])
        let route = try #require(PolishSelectionModel.geminiFlash.route)
        #expect(TextRoute.maxTokens(forCharacterCount: 70_000, effort: route.budget) > VertexProxy.maxOutputTokens)
        let result = try await client.sendText(String(repeating: "a", count: 70_000), route: route,
                                               systemPrompt: "Fix it.", apiKey: ProxyFixture.key, timeout: 30)
        #expect(result.text == "Fixed.")
        let body = ProxyFixture.json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect(body["max_tokens"] as? Int == VertexProxy.maxOutputTokens)
        #expect(body["provider"] == nil)
    }

    private func failure(_ replies: [StubURLProtocol.Reply]) async -> (AppError?, Int) {
        let (client, host) = ProxyFixture.client(replies)
        do {
            _ = try await client.transcribe(audio: Data([1]), format: "m4a", model: "google/gemini-3.8-flash",
                                            systemPrompt: "x", effort: .medium, maxTokens: 1000,
                                            apiKey: ProxyFixture.key, timeout: 30)
            return (nil, StubURLProtocol.registry.requests(for: host).count)
        } catch {
            return (error as? AppError, StubURLProtocol.registry.requests(for: host).count)
        }
    }

    @Test func a401IsTheProxyRejectingTheKey() async {
        let (error, requests) = await failure([ProxyFixture.error(401, "API key not valid. Please pass a valid API key.",
                                                                  code: "UNAUTHENTICATED")])
        #expect(error == .vertexProxy(.keyRejected("API key not valid. Please pass a valid API key.")))
        #expect(requests == 1)
        #expect(error?.stopsEveryCloudModel == false, "cloud Parakeet still goes through OpenRouter")
    }

    @Test func theSpendLimitIsReportedAndNeverRetried() async {
        let message = "Proxy spend limit reached: estimated $250.10 >= SPEND_LIMIT_USD=$250.00. Raise SPEND_LIMIT_USD or reset the ledger to continue."
        let (error, requests) = await failure([ProxyFixture.error(429, message, code: "RESOURCE_EXHAUSTED"),
                                               ProxyFixture.answer("never")])
        #expect(error == .vertexProxy(.spendLimit(message)))
        #expect(requests == 1)
        let keyLimit = "Spend limit for key 'mac' reached: estimated $5.00 >= $5.00. Raise the key limit in the dashboard to continue."
        let (keyError, _) = await failure([ProxyFixture.error(429, keyLimit, code: "RESOURCE_EXHAUSTED")])
        #expect(keyError == .vertexProxy(.spendLimit(keyLimit)))
        // Other endpoints say it as a 402, or as a used-up quota.
        let (payment, paid) = await failure([ProxyFixture.error(402, "Insufficient credits", code: "402")])
        #expect(payment == .vertexProxy(.spendLimit("Insufficient credits")))
        #expect(paid == 1)
        let quota = "You exceeded your current quota, please check your plan and billing details."
        let (quotaError, _) = await failure([ProxyFixture.error(429, quota, code: "insufficient_quota")])
        #expect(quotaError == .vertexProxy(.spendLimit(quota)))
    }

    @Test func vertexOutOfCapacityIsRetriedOnceThenReported() async {
        let busy = ProxyFixture.error(429, "Resource exhausted. Please try again later.", code: "RESOURCE_EXHAUSTED")
        let (error, requests) = await failure([busy, busy])
        #expect(error == .vertexProxy(.rateLimited(retryAfter: nil)))
        #expect(requests == 2)
        let (recovered, again) = await failure([busy, ProxyFixture.answer("ok")])
        #expect(recovered == nil)
        #expect(again == 2)
    }

    @Test func serverErrorsAreTheProxysAndRetriedOnce() async {
        let down = ProxyFixture.error(503, "Key store is temporarily unavailable, try again.", code: "UNAVAILABLE")
        let (error, requests) = await failure([down, down])
        #expect(error == .vertexProxy(.unavailable("Key store is temporarily unavailable, try again.")))
        #expect(requests == 2)
        let (timeout, _) = await failure([ProxyFixture.error(504, "Upstream timeout", code: "DEADLINE_EXCEEDED")])
        #expect(timeout == .timeout(.geminiFlash))
        let (billing, _) = await failure([ProxyFixture.error(403, "Billing is disabled (proxy hint: billing is disabled)",
                                                             code: "PERMISSION_DENIED")])
        #expect(billing == .vertexProxy(.forbidden("Billing is disabled (proxy hint: billing is disabled)")))
        let (large, _) = await failure([ProxyFixture.error(413, "Request payload size exceeds the limit: 115343360 bytes.",
                                                           code: "INVALID_ARGUMENT")])
        #expect(large == .vertexProxy(.tooLarge))
        let (bad, _) = await failure([ProxyFixture.error(400, "Invalid 'messages'", code: "INVALID_ARGUMENT")])
        #expect(bad == .vertexProxy(.badRequest("Invalid 'messages'")))
    }

    @Test func anAddressThatDoesntAnswerIsUnreachable() async {
        for code in [URLError.Code.cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .secureConnectionFailed] {
            let (error, requests) = await failure([StubURLProtocol.Reply(error: code)])
            #expect(error == .vertexProxy(.unreachable), "\(code)")
            #expect(requests == 1)
        }
    }

    @Test func aFailureInsideTheStreamIsMappedByItsStatus() async {
        let chunk = #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"google/gemini-3.8-flash","error":{"code":429,"message":"Proxy spend limit reached: estimated $1.00 >= SPEND_LIMIT_USD=$1.00."},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error","native_finish_reason":null}]}"#
        let (error, _) = await failure([.stream(SSE.stream([chunk]))])
        #expect(error == .vertexProxy(.spendLimit("Proxy spend limit reached: estimated $1.00 >= SPEND_LIMIT_USD=$1.00.")))
        let broken = #"{"id":"chatcmpl-1","error":{"code":502,"message":"Upstream stream error"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#
        let (upstream, _) = await failure([.stream(SSE.stream([broken])), .stream(SSE.stream([broken]))])
        #expect(upstream == .vertexProxy(.unavailable("Upstream stream error")))
    }

    @Test func aStreamThatStopsIsTheProxysLostConnection() async {
        let cut = StubURLProtocol.Reply.stream(SSE.stream([SSE.chunk(content: "Hal")], done: false))
        let (error, _) = await failure([cut, cut])
        #expect(error == .vertexProxy(.unavailable("The connection to your endpoint was lost.")))
    }

    @Test func theKeyCheckListsModelsAndSpendsNothing() async throws {
        let (client, host) = ProxyFixture.client([ProxyFixture.models])
        try await client.checkProxyKey(apiKey: ProxyFixture.key)
        let request = try #require(StubURLProtocol.registry.requests(for: host).first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://\(host)/api/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(ProxyFixture.key)")
    }

    @Test func theKeyCheckTellsARejectedKeyFromSomethingElse() async {
        func check(_ reply: StubURLProtocol.Reply) async -> AppError? {
            let (client, _) = ProxyFixture.client([reply])
            do {
                try await client.checkProxyKey(apiKey: ProxyFixture.key)
                return nil
            } catch {
                return error as? AppError
            }
        }
        #expect(await check(ProxyFixture.error(401, "API key not valid.", code: "UNAUTHENTICATED"))
                == .vertexProxy(.keyRejected("API key not valid.")))
        #expect(await check(StubURLProtocol.Reply(body: "<html>hello</html>"))
                == .vertexProxy(.badRequest(VertexProxy.notAnAPIMessage)))
        #expect(await check(StubURLProtocol.Reply(error: .cannotFindHost)) == .vertexProxy(.unreachable))
    }
}

// MARK: - Account

@MainActor
@Suite struct VertexProxyAccountTests {
    @Test func aSavedAddressIsNormalizedAndChecked() async throws {
        let settings = AppSettings.inMemory()
        let (proxy, host) = ProxyFixture.proxy([ProxyFixture.models], settings: settings)
        settings.vertexProxyURL = nil
        #expect(!proxy.isConfigured)
        let problem = await proxy.setURL("  \(host)/v1/chat/completions ")
        #expect(problem == nil)
        #expect(settings.vertexProxyURL == "https://\(host)/v1")
        #expect(proxy.urlText == "https://\(host)/v1")
        #expect(proxy.status == .works)
        #expect(proxy.routesGemini)
        #expect(StubURLProtocol.registry.requests(for: host).map { $0.url?.path } == ["/v1/models"])
    }

    /// What the app saved for the user's Vertex proxy: the host alone. It still means `<host>/api/v1`, for the check
    /// and for Gemini's requests, with no migration; the field shows it as that.
    @Test func aSavedHostOnlyURLKeepsWorkingUnderApiV1() async throws {
        let settings = AppSettings.inMemory()
        let (proxy, host) = ProxyFixture.proxy([ProxyFixture.models, ProxyFixture.answer("Как раньше.")],
                                               settings: settings)
        #expect(settings.vertexProxyURL == "https://\(host)", "the saved value isn't rewritten")
        #expect(proxy.urlText == "https://\(host)/api/v1")
        #expect(proxy.baseURL.map(VertexProxy.displayHost) == "\(host)/api/v1")
        await proxy.validate()
        #expect(proxy.status == .works)
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(result.text == "Как раньше.")
        #expect(StubURLProtocol.registry.requests(for: host).map { $0.url?.path }
                == ["/api/v1/models", "/api/v1/chat/completions"])
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
        let body = ProxyFixture.json(try #require(StubURLProtocol.registry.bodies(for: host).last))
        #expect(body["model"] as? String == "google/gemini-3.8-flash", "the same model id as before")
    }

    @Test func aV1BaseSavedFromTheFieldRoutesGeminiThere() async throws {
        let (proxy, host) = ProxyFixture.proxy([ProxyFixture.answer("Через v1.")], path: "/v1")
        let (service, _) = ProxyFixture.service(proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(result.text == "Через v1.")
        #expect(StubURLProtocol.registry.requests(for: host).map { $0.url?.path } == ["/v1/chat/completions"])
    }

    @Test func aBadAddressIsNotSaved() async {
        let settings = AppSettings.inMemory()
        let (proxy, _) = ProxyFixture.proxy(settings: settings)
        let before = settings.vertexProxyURL
        #expect(await proxy.setURL("http://insecure.example") == .notHTTPS)
        #expect(settings.vertexProxyURL == before)
        #expect(await proxy.setURL("") == nil)
        #expect(settings.vertexProxyURL == nil)
        #expect(proxy.status == .notSet)
        #expect(proxy.routesGemini && !proxy.isConfigured, "still the provider, now not set up")
    }

    @Test func aKeyOfAnyShapeIsSavedAndChecked() async {
        let (proxy, host) = ProxyFixture.proxy([ProxyFixture.models], key: nil)
        let problem = await proxy.setKey("AIzaSyA0123456789abcdef")
        #expect(problem == nil)
        #expect(proxy.apiKey() == "AIzaSyA0123456789abcdef")
        #expect(proxy.maskedKey == "••••cdef")
        #expect(proxy.status == .works)
        #expect(proxy.routesGemini)
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
    }

    @Test func aSavedKeyIsCheckedAndOnlyItsMaskShows() async {
        let settings = AppSettings.inMemory()
        let (proxy, host) = ProxyFixture.proxy([ProxyFixture.models], key: nil, settings: settings)
        #expect(await proxy.setKey("Bearer \(ProxyFixture.key)\n") == nil)
        #expect(proxy.apiKey() == ProxyFixture.key)
        #expect(proxy.maskedKey == VertexProxy.mask(ProxyFixture.key))
        #expect(proxy.status == .works)
        #expect(settings.vertexProxyURL?.contains(ProxyFixture.key) == false)
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
        proxy.removeKey()
        #expect(proxy.apiKey() == nil)
        #expect(proxy.status == .notSet)
        #expect(proxy.routesGemini && !proxy.isConfigured, "still the provider, now not set up")
    }

    @Test func theCheckSaysWhatWentWrong() async {
        let cases: [(StubURLProtocol.Reply, VertexProxyStatus)] = [
            (ProxyFixture.error(401, "API key not valid.", code: "UNAUTHENTICATED"), .keyRejected("API key not valid.")),
            (StubURLProtocol.Reply(error: .cannotFindHost), .unreachable),
            (StubURLProtocol.Reply(status: 404, body: #"{"detail":"Not Found"}"#),
             .failed("No OpenAI-compatible API answers at this URL. Check that it’s the one that ends in /v1.")),
            (StubURLProtocol.Reply(body: "<html></html>"), .failed(VertexProxy.notAnAPIMessage)),
        ]
        for (reply, expected) in cases {
            let (proxy, _) = ProxyFixture.proxy([reply])
            await proxy.validate()
            #expect(proxy.status == expected)
        }
    }

    @Test func theProviderSwitchesRoutingWithoutForgetting() {
        let (proxy, _) = ProxyFixture.proxy()
        #expect(proxy.routesGemini)
        proxy.isEnabled = false
        #expect(!proxy.routesGemini)
        #expect(proxy.isConfigured)
        #expect(proxy.apiKey() == ProxyFixture.key)
        proxy.isEnabled = true
        #expect(proxy.routesGemini)
    }

    @Test func keyStatusFollowsTheProxy() async {
        let (proxy, _) = ProxyFixture.proxy()
        #expect(proxy.status == .checking, "set up: usable until the first check says otherwise")
        proxy.noteCloudFailure(.vertexProxy(.spendLimit("Proxy spend limit reached")))
        #expect(proxy.keyStatus.isProxySpendLimit)
        #expect(EngineReadiness.of(.geminiFlash, localState: .notInstalled, keyStatus: proxy.keyStatus)
                == .keyProblem("Spend limit reached"))
        proxy.noteCloudSuccess()
        #expect(proxy.status == .works)
        #expect(EngineSummary.make(engine: .geminiFlash, localState: .notInstalled, keyStatus: proxy.keyStatus).status
                == "Ready · Custom endpoint")
        proxy.noteCloudFailure(.vertexProxy(.keyRejected("no")))
        #expect(proxy.keyStatus == .invalid("no"))
        #expect(EngineReadiness.of(.geminiFlash, localState: .notInstalled, keyStatus: proxy.keyStatus)
                == .keyProblem("Key rejected"))
    }

    @Test func anUnreadableKeyStillRoutesGeminiToTheProxy() {
        let (proxy, _) = ProxyFixture.proxy(keyReadFails: true)
        #expect(proxy.isKeyUnreadable)
        #expect(proxy.routesGemini, "never quietly to OpenRouter")
        #expect(proxy.keyStatus == .failed(VertexProxyAccount.keyUnreadableMessage))
    }
}

// MARK: - Routing

@MainActor
@Suite struct VertexProxyRoutingTests {
    @Test func withTheProxyOnGeminiDictationGoesToItAndNotToOpenRouter() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([ProxyFixture.answer("Через прокси.")])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(result.text == "Через прокси.")
        #expect(result.provider == proxyHost, "History names the endpoint by its host")
        #expect(result.costUSD == 0.0042)
        #expect(result.modelID == "google/gemini-3.8-flash")
        #expect(StubURLProtocol.registry.requests(for: proxyHost).count == 1)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
        #expect(proxy.status == .works)
    }

    @Test func aDictationsTwoRequestsAtOnceBothGoToTheProxy() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([ProxyFixture.answer("one"), ProxyFixture.answer("one")])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash, hedge: .race(copies: 2))
        #expect(result.text == "one")
        #expect(result.otherGenerationIDs.isEmpty, "nothing to look up on OpenRouter")
        try await waitUntil { StubURLProtocol.registry.requests(for: proxyHost).count == 2 }
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func polishAndTranslateGoToTheProxyToo() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([
            .stream(SSE.answer("<message>Polished.</message>", usage: #"{"cost":0.002}"#)),
            ProxyFixture.answer("Translated."),
        ])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let polished = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash, prompt: Polish.prompt)
        #expect(polished.text == "Polished.")
        let translated = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash,
                                                      prompt: Translate.prompt(.default))
        #expect(translated.text == "Translated.")
        #expect(StubURLProtocol.registry.requests(for: proxyHost).count == 2)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func theSelectionsPolishGoesToTheProxy() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([.stream(SSE.answer("Better text.", usage: #"{"cost":0.001}"#))])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let route = try #require(PolishSelectionModel.geminiFlash.route)
        let result = try await service.polishText("some text", route: route, prompt: "Fix it.", timeout: 10)
        #expect(result.text == "Better text.")
        #expect(result.provider == proxyHost, "History names the endpoint by its host")
        #expect(result.costUSD == 0.001)
        #expect(StubURLProtocol.registry.requests(for: proxyHost).count == 1)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    /// Gemini goes to the endpoint with its model and the level picked for it.
    @Test func geminiGoesThroughTheProxyWithItsModelAndLevel() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([ProxyFixture.answer("Flash.")])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        service.reasoningEffort = { $0 == .geminiFlash ? .high : .low }
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(result.text == "Flash." && result.engine == .geminiFlash && result.reasoningEffort == .high)
        let body = ProxyFixture.json(try #require(StubURLProtocol.registry.bodies(for: proxyHost).first))
        #expect(body["model"] as? String == "google/gemini-3.8-flash")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(body["provider"] == nil)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func withTheProxyOffGeminiGoesThroughOpenRouter() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy(enabled: false)
        let (service, openRouterHost) = ProxyFixture.service(
            openRouterReplies: [.stream(SSE.answer("<transcript>OpenRouter.</transcript>", provider: "Google AI Studio",
                                                   usage: #"{"cost":0.001}"#))],
            proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(result.text == "OpenRouter.")
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).count == 1)
        #expect(StubURLProtocol.registry.requests(for: proxyHost).isEmpty)
        let body = ProxyFixture.json(try #require(StubURLProtocol.registry.bodies(for: openRouterHost).first))
        #expect(body["provider"] != nil, "OpenRouter's requests keep their routing")
    }

    @Test func withOnlyTheProxyGeminiWorks() async throws {
        let (proxy, _) = ProxyFixture.proxy([ProxyFixture.answer("Только прокси.")])
        let (service, openRouterHost) = ProxyFixture.service(openRouterKey: nil, proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(result.text == "Только прокси.")
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func aProxyFailureIsNeverRetriedOnOpenRouter() async throws {
        let down = ProxyFixture.error(503, "Upstream connection error", code: "UNAVAILABLE")
        let (proxy, proxyHost) = ProxyFixture.proxy([down, down])
        let (service, openRouterHost) = ProxyFixture.service(openRouterReplies: [ProxyFixture.answer("never")],
                                                             proxy: proxy)
        await #expect(throws: AppError.vertexProxy(.unavailable("Upstream connection error"))) {
            try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        }
        #expect(StubURLProtocol.registry.requests(for: proxyHost).count == 2)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func aRejectedKeyIsNotedOnTheProxy() async {
        let (proxy, _) = ProxyFixture.proxy([ProxyFixture.error(401, "API key not valid.", code: "UNAUTHENTICATED")])
        let (service, _) = ProxyFixture.service(proxy: proxy)
        _ = try? await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(proxy.status == .keyRejected("API key not valid."))
    }

    @Test func anUnreadableProxyKeyFailsAsTheProxys() async {
        let (proxy, _) = ProxyFixture.proxy(keyReadFails: true)
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        await #expect(throws: AppError.vertexProxy(.keyUnreadable)) {
            try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        }
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func aCallIsTranscribedThroughTheProxy() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([.stream(SSE.answer("[00:00-00:02] Anna: Hi.", usage: #"{"cost":0.03}"#))])
        let (client, openRouterHost) = StubURLProtocol.client([])
        let account = OpenRouterAccount(keyStore: .inMemory(nil), client: client, debounce: .zero)
        let send = CallTranscriber.openRouter(client: client, account: account, proxy: proxy)
        let result = try await send(Data([1, 2]), "Transcribe the call.", 2, nil)
        #expect(result.text == "[00:00-00:02] Anna: Hi.")
        #expect(result.costUSD == 0.03)
        #expect(StubURLProtocol.registry.requests(for: proxyHost).count == 1)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
        proxy.isEnabled = false
        await #expect(throws: AppError.openRouterMissingKey) { try await send(Data([1]), "x", 1, nil) }
    }

    /// The endpoint speaks the same format: a call's voice sample goes as the first audio part there too.
    @Test func aCallsVoiceSampleGoesToTheProxyBeforeTheCall() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([.stream(SSE.answer("[00:00-00:02] Sam: Hi."))])
        let (client, _) = StubURLProtocol.client([])
        let account = OpenRouterAccount(keyStore: .inMemory(nil), client: client, debounce: .zero)
        let send = CallTranscriber.openRouter(client: client, account: account, proxy: proxy)
        _ = try await send(Data([1, 2]), "The call.", 2, Data([7, 7, 7]))
        let body = ProxyFixture.json(try #require(StubURLProtocol.registry.bodies(for: proxyHost).first))
        #expect(body["provider"] == nil)
        let content = try #require((body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        let data = content.map { ($0["input_audio"] as? [String: Any])?["data"] as? String }
        #expect(data == [Data([7, 7, 7]).base64EncodedString(), Data([1, 2]).base64EncodedString()])
        #expect(content.allSatisfy { $0["type"] as? String == "input_audio" })
    }

    @Test func routeAndKeyStatusPerEngine() {
        let (proxy, _) = ProxyFixture.proxy()
        let account = OpenRouterAccount.preview(status: .missing)
        #expect(CloudRoute.provider(for: .geminiFlash, proxy: proxy) == .vertexProxy)
        #expect(CloudRoute.provider(for: .parakeet, proxy: proxy) == nil)
        #expect(CloudRoute.keyStatus(for: .geminiFlash, account: account, proxy: proxy) == .checking)
        #expect(CloudRoute.keyStatus(for: .parakeet, account: account, proxy: proxy) == .missing)
        proxy.isEnabled = false
        #expect(CloudRoute.provider(for: .geminiFlash, proxy: proxy) == .openRouter)
        #expect(CloudRoute.keyStatus(for: .geminiFlash, account: account, proxy: proxy) == .missing)
        #expect(CloudRoute.provider(for: .geminiFlash, proxy: nil) == .openRouter)
    }
}

// MARK: - What the app says

@MainActor
@Suite struct VertexProxyCopyTests {
    static let failures: [VertexProxyFailure] = [.notSetUp, .keyUnreadable, .keyRejected("x"), .spendLimit("x"), .unreachable,
                                                 .rateLimited(retryAfter: nil), .forbidden(""), .unavailable("x"),
                                                 .badRequest(""), .tooLarge]

    @Test func everyEndpointFailureSaysYourEndpointAndPointsToModels() {
        for failure in Self.failures {
            let notice = AppError.vertexProxy(failure).notice(recordingID: UUID(), fallbackEngine: .parakeet,
                                                              engine: .geminiFlash)
            #expect(notice.title.contains("endpoint"), "\(failure)")
            #expect(!notice.title.contains("OpenRouter") && !(notice.body ?? "").contains("openrouter.ai"))
            #expect(!notice.actions.contains { if case .openURL = $0.kind { true } else { false } })
        }
        let rejected = AppError.vertexProxy(.keyRejected("")).notice(recordingID: nil, fallbackEngine: nil)
        #expect(rejected.actions.first?.kind == .openHub(.models))
        #expect(AppError.vertexProxy(.unreachable).isRetryable)
        #expect(!AppError.vertexProxy(.spendLimit("")).isRetryable)
        let tooLarge = AppError.vertexProxy(.tooLarge).notice(recordingID: UUID(), fallbackEngine: nil)
        #expect(!tooLarge.actions.contains { $0.kind == .retry })
    }

    @Test func theNoticesSayWhatToDo() {
        func notice(_ failure: VertexProxyFailure) -> Notice {
            AppError.vertexProxy(failure).notice(recordingID: nil, fallbackEngine: nil, engine: .geminiFlash)
        }
        #expect(notice(.keyRejected("")).title == "Your endpoint rejected the API key")
        #expect(notice(.unreachable).title == "Can’t reach your endpoint")
        #expect(notice(.unreachable).body == "Check your connection and the endpoint’s base URL in Models.")
        #expect(notice(.spendLimit("")).title == "Your endpoint hit a spend limit")
        #expect(notice(.rateLimited(retryAfter: 3)).title == "Gemini is busy on your endpoint")
        #expect(notice(.unavailable("x")).title == "Your endpoint ran into a problem")
        #expect(notice(.forbidden("")).title == "Your endpoint refused the request")
    }

    @Test func homeRowsSayWhatTheEndpointDid() {
        #expect(DictationController.homeFailureReason(.vertexProxy(.spendLimit("x")), making: .polish())
                == "Your endpoint hit a spend limit.")
        #expect(DictationController.homeFailureReason(.vertexProxy(.unreachable), making: .transcription(.geminiFlash))
                == "Couldn’t reach your endpoint. Check its base URL in Models.")
        #expect(DictationController.homeFailureReason(.vertexProxy(.keyRejected("x")), making: .polish())
                == "Your endpoint rejected the API key.")
        #expect(DictationController.homeFailureReason(.vertexProxy(.unavailable("x")), making: .polish())
                == "Your endpoint ran into a problem.")
    }

    /// Nothing the app shows or prints names Vertex or a proxy: every notice, Home row, status, field message and
    /// CLI line about the endpoint.
    @Test func noUserFacingTextNamesVertexOrAProxy() {
        let (proxy, host) = ProxyFixture.proxy()
        var texts: [String] = [CloudProvider.vertexProxy.name, VertexProxy.label, VertexProxy.notAnAPIMessage,
                               VertexProxyAccount.keyUnreadableMessage, EndpointRow.urlHelp,
                               APIKeysGroup.footer(.openRouter), APIKeysGroup.footer(.vertexProxy)]
        texts += [VertexProxy.URLProblem.empty, .notHTTPS, .invalid].map(\.message)
        for failure in Self.failures {
            let error = AppError.vertexProxy(failure)
            let notice = error.notice(recordingID: UUID(), fallbackEngine: .parakeet, engine: .geminiFlash)
            texts += [notice.title, notice.body ?? "", error.localizedDescription]
            texts += notice.actions.map(\.title)
            texts.append(DictationController.homeFailureReason(error, making: .polish()))
            texts.append("\(VertexProxyAccount.status(for: error))")
        }
        for status in [404, 500] {
            texts.append("\(VertexProxyAccount.status(for: VertexProxyErrorMapper.map(status: status, message: "", retryAfter: nil, engine: .geminiFlash)))")
        }
        texts.append("\(VertexProxyAccount.status(for: AppError.timeout(.geminiFlash)))")
        texts.append(EngineCLI.geminiRouteLine(proxy))
        proxy.isEnabled = false
        texts.append(EngineCLI.geminiRouteLine(proxy))
        texts.append(EngineCLI.geminiRouteLine(nil))
        texts.append(EngineSummary.make(engine: .geminiFlash, localState: .notInstalled,
                                        keyStatus: .valid(KeyInfo(label: VertexProxy.label))).status)
        for keyStatus in [KeyStatus.invalid("x"), .noCredit(KeyInfo(label: VertexProxy.label)), .missing] {
            let input = HubAttention.Input(microphone: .granted, accessibility: .granted, accessibilityLikelyStale: false,
                                           fnKeyUsage: .doNothing, pushToTalkUsesFn: true, engine: .geminiFlash,
                                           localState: .notInstalled, keyStatus: keyStatus, provider: .vertexProxy)
            texts += HubAttention.items(input).flatMap { [$0.title, $0.body] }
        }
        for text in texts.map({ $0.replacingOccurrences(of: host, with: "<host>") }) {
            #expect(!text.localizedCaseInsensitiveContains("vertex"), "\(text)")
            #expect(!text.localizedCaseInsensitiveContains("proxy"), "\(text)")
        }
    }

    /// The same, read off the sources: no string literal outside Calls (another feature's, with its own tests) names
    /// Vertex or a proxy, and neither does the README.
    @Test func noStringLiteralOrReadmeNamesVertex() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/TranscribeThing")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Calls/") }
        #expect(files.count > 50)
        let literal = try Regex(#""[^"\n]*""#)
        // Code interpolated into a literal ("\(VertexProxy.label)") names the types, not the text.
        let identifier = try Regex(#"[A-Za-z]*[Vv]ertexProxy[A-Za-z]*"#)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                for match in code.matches(of: literal) {
                    let text = String(code[match.range]).replacing(identifier, with: "")
                    #expect(!text.contains("Vertex") && !text.contains("Vertex AI") && !text.contains(" proxy")
                            && !text.contains("Proxy ") && !text.contains("sk-vp-"),
                            "\(file.lastPathComponent):\(number + 1): \(text)")
                }
            }
        }
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(!readme.localizedCaseInsensitiveContains("vertex"))
        #expect(!readme.contains("sk-vp-"))
        #expect(!readme.contains("—") && !readme.contains("–"), "no em or en dashes")
    }

    @Test func homeAsksToFixTheProxyNotOpenRouter() {
        let input = HubAttention.Input(microphone: .granted, accessibility: .granted, accessibilityLikelyStale: false,
                                       fnKeyUsage: .doNothing, pushToTalkUsesFn: true, engine: .geminiFlash,
                                       localState: .notInstalled, keyStatus: .invalid("no"), provider: .vertexProxy)
        let item = HubAttention.items(input).first { $0.id == "key" }
        #expect(item?.title == "Your endpoint rejected the API key")
        var spent = input
        spent.keyStatus = .noCredit(KeyInfo(label: VertexProxy.label))
        #expect(HubAttention.items(spent).first { $0.id == "key" }?.title == "Your endpoint hit a spend limit")
        var openRouter = input
        openRouter.provider = .openRouter
        #expect(HubAttention.items(openRouter).first { $0.id == "key" }?.title == "Your OpenRouter key stopped working")
    }

    @Test func theDiagnosticsSayWhereGeminiGoesButNeverTheKeyOrAddress() {
        let settings = AppSettings.inMemory()
        let (proxy, host) = ProxyFixture.proxy(settings: settings)
        let line = DiagnosticSettingsSummary(settings: settings, keySaved: true,
                                             endpoint: DiagnosticSettingsSummary.endpointState(proxy)).line
        #expect(line.contains("provider=vertexProxy customEndpoint=set"))
        #expect(!line.contains(ProxyFixture.key) && !line.contains(host))
        proxy.isEnabled = false
        #expect(DiagnosticSettingsSummary(settings: settings, keySaved: true,
                                          endpoint: DiagnosticSettingsSummary.endpointState(proxy)).line
                    .contains("provider=openRouter customEndpoint=set"))
        #expect(DiagnosticSettingsSummary.endpointState(nil) == "notSet")
        let route = EngineCLI.geminiRouteLine(proxy)
        #expect(route == "OpenRouter (custom endpoint at \(host)/api/v1 saved, not in use)")
        #expect(!route.contains(ProxyFixture.key))
        proxy.isEnabled = true
        #expect(EngineCLI.geminiRouteLine(proxy) == "Custom endpoint (\(host)/api/v1, key saved)")
        #expect(EngineCLI.geminiRouteLine(nil) == "OpenRouter (no custom endpoint saved)")
        let (unkeyed, other) = ProxyFixture.proxy(key: nil, path: "/v1")
        #expect(EngineCLI.geminiRouteLine(unkeyed) == "Custom endpoint (\(other)/v1, not set up: no key)")
    }

    @Test func noFailureCarriesTheKey() {
        let errors: [AppError] = [
            VertexProxyErrorMapper.httpError(status: 401, data: Data(#"{"error":{"message":"API key not valid."}}"#.utf8),
                                             retryAfter: nil, engine: .geminiFlash),
            VertexProxyErrorMapper.map(status: 429, message: "Proxy spend limit reached", retryAfter: 3,
                                       engine: .geminiFlash),
            .vertexProxy(.unreachable), .vertexProxy(.keyUnreadable),
        ]
        for error in errors {
            let text = [error.code, error.detail ?? "", error.localizedDescription].joined(separator: " ")
            #expect(!text.contains(ProxyFixture.key) && !text.contains("TestKey"))
        }
    }
}

/// The client's log lines, as the app writes them, for proxy requests: never the key. In the suite of the other tests
/// that point the shared log at a folder of their own, so none of them stops it under another.
extension DiagnosticDictationTests {
    @Test func theProxyKeyNeverReachesTheDiagnosticLog() async throws {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("tt-proxy-\(UUID().uuidString)")
        DiagnosticLog.shared.start(directory: logs)
        defer {
            DiagnosticLog.shared.stop()
            DiagnosticLog.shared.flush()
            try? FileManager.default.removeItem(at: logs)
        }
        let (proxy, _) = ProxyFixture.proxy([
            ProxyFixture.models,
            ProxyFixture.error(401, "API key not valid.", code: "UNAUTHENTICATED"),
            ProxyFixture.error(429, "Proxy spend limit reached.", code: "RESOURCE_EXHAUSTED"),
            ProxyFixture.answer("ok"),
        ])
        let (service, _) = ProxyFixture.service(proxy: proxy)
        await proxy.validate()
        _ = try? await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        _ = try? await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        _ = try? await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        let text = DiagnosticLog.shared.retainedText()
        #expect(!text.contains(ProxyFixture.key))
        #expect(!text.contains("TestKey0123"))
        #expect(text.contains("endpoint."))
    }
}

/// What a dictation is refused for before the mic opens follows the proxy while it takes Gemini's requests.
@MainActor
@Suite(.serialized) struct VertexProxyDictationTests {
    @Test func geminiNeedsNoOpenRouterKeyWhileTheProxyTakesIt() {
        let (proxy, _) = ProxyFixture.proxy()
        proxy.noteCloudSuccess()
        let h = DictationControllerTests.make(keyStatus: .missing, proxy: proxy)
        h.settings.lineup.main = .gemini
        #expect(h.controller.captureRefusal() == nil)
        proxy.isEnabled = false
        #expect(h.controller.captureRefusal() == .openRouterMissingKey)
    }

    @Test func aRejectedProxyKeyRefusesGeminiAsTheProxys() {
        let (proxy, _) = ProxyFixture.proxy()
        proxy.noteCloudFailure(.vertexProxy(.keyRejected("API key not valid.")))
        let h = DictationControllerTests.make(keyStatus: .valid(KeyInfo()), proxy: proxy)
        h.settings.lineup.main = .gemini
        #expect(h.controller.captureRefusal() == .vertexProxy(.keyRejected("API key not valid.")))
        h.settings.lineup.main = .parakeet
        #expect(h.controller.captureRefusal() == nil, "Parakeet on this Mac needs no key")
    }

    @Test func anUnreadableProxyKeyRefusesGemini() {
        let (proxy, _) = ProxyFixture.proxy(keyReadFails: true)
        let h = DictationControllerTests.make(keyStatus: .valid(KeyInfo()), proxy: proxy)
        h.settings.lineup.main = .gemini
        #expect(h.controller.captureRefusal() == .vertexProxy(.keyUnreadable))
    }
}

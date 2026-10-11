import Foundation
import Testing
@testable import TranscribeThing

// The Vertex proxy: its address and key, the check that costs nothing, and Gemini's requests going to it (and only
// to it) while it's set up and on. No network: every request goes to `StubURLProtocol`.

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

    /// A proxy at a host of its own whose requests get `replies`, with `key` saved (none for nil).
    static func proxy(_ replies: [StubURLProtocol.Reply] = [], key: String? = key, enabled: Bool = true,
                      settings: AppSettings? = nil, keyReadFails: Bool = false) -> (VertexProxyAccount, String) {
        let settings = settings ?? .inMemory()
        let host = "proxy-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.registry.enqueue(replies, host: host)
        settings.vertexProxyURL = "https://\(host)"
        settings.vertexProxyEnabled = enabled
        let keyStore = KeyFileStore.inMemory(key)
        keyStore.simulateReadFailure(keyReadFails)
        let session = session
        let account = VertexProxyAccount(keyStore: keyStore, settings: settings, makeClient: { apiBase in
            OpenRouterClient(session: session, baseURL: apiBase, retryDelay: 0.01, service: .vertexProxy)
        }, debounce: .zero)
        return (account, host)
    }

    /// A client straight to a proxy at its own host.
    static func client(_ replies: [StubURLProtocol.Reply]) -> (OpenRouterClient, String) {
        let host = "proxy-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.registry.enqueue(replies, host: host)
        let client = OpenRouterClient(session: session, baseURL: URL(string: "https://\(host)/api/v1")!,
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
    @Test(arguments: [
        "https://vertex-proxy-2pthtwqema-uc.a.run.app",
        "https://vertex-proxy-2pthtwqema-uc.a.run.app/",
        "https://vertex-proxy-2pthtwqema-uc.a.run.app/api/v1",
        "https://vertex-proxy-2pthtwqema-uc.a.run.app/api/v1/",
        "  https://Vertex-Proxy-2pthtwqema-uc.a.run.app/api/v1/chat/completions \n",
        "vertex-proxy-2pthtwqema-uc.a.run.app",
    ])
    func everySpellingOfTheSameProxyGivesOneBase(_ raw: String) throws {
        let base = try VertexProxy.normalizedBaseURL(raw).get()
        #expect(base.absoluteString == "https://vertex-proxy-2pthtwqema-uc.a.run.app")
        #expect(VertexProxy.apiBase(base).absoluteString == "https://vertex-proxy-2pthtwqema-uc.a.run.app/api/v1")
    }

    @Test func aPathBeforeTheAPIIsKept() throws {
        let base = try VertexProxy.normalizedBaseURL("https://example.com/proxy/api/v1/").get()
        #expect(base.absoluteString == "https://example.com/proxy")
        #expect(VertexProxy.apiBase(base).appendingPathComponent("chat/completions").absoluteString
                == "https://example.com/proxy/api/v1/chat/completions")
    }

    @Test func badAddressesAreRefusedWithAReason() {
        #expect(VertexProxy.normalizedBaseURL("   ") == .failure(.empty))
        #expect(VertexProxy.normalizedBaseURL("http://vertex-proxy.a.run.app") == .failure(.notHTTPS))
        #expect(VertexProxy.normalizedBaseURL("http:vertex-proxy") == .failure(.notHTTPS))
        #expect(VertexProxy.normalizedBaseURL("ftp://vertex-proxy.a.run.app") == .failure(.notHTTPS))
        #expect(VertexProxy.normalizedBaseURL("https://vertex-proxy.a.run.app/?key=sk-vp-x") == .failure(.invalid))
        #expect(VertexProxy.normalizedBaseURL("https://user:pw@vertex-proxy.a.run.app") == .failure(.invalid))
        #expect(VertexProxy.normalizedBaseURL("https://") == .failure(.invalid))
    }

    @Test func keysMustStartWithThePrefix() {
        #expect(VertexProxy.keyProblem("sk-or-v1-abcdef") == "Vertex proxy keys start with “sk-vp-”.")
        #expect(VertexProxy.keyProblem("sk-vp-ab") == "That key looks too short.")
        #expect(VertexProxy.keyProblem(ProxyFixture.key) == nil)
        #expect(VertexProxy.keyProblem("") == nil, "nothing typed yet says nothing")
        #expect(VertexProxy.looksLikeKey(ProxyFixture.key))
        #expect(!VertexProxy.looksLikeKey("sk-or-v1-0123456789abcdef"))
        #expect(!VertexProxy.looksLikeKey(""))
    }

    @Test func theMaskShowsOnlyThePrefixAndLastFour() {
        let masked = VertexProxy.mask(ProxyFixture.key)
        #expect(masked == "sk-vp-••••rstu")
        #expect(!masked.contains("TestKey"))
        #expect(VertexProxy.mask("sk-vp-ab") == "sk-vp-••••")
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
        #expect(result.provider == "Vertex AI")
        #expect(result.generationID == nil, "no generation record to look up on the proxy")

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
        #expect(error == .vertexProxy(.unavailable("The connection to Vertex proxy was lost.")))
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
                == .vertexProxy(.badRequest(VertexProxy.notAProxyMessage)))
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
        let problem = await proxy.setURL("  \(host)/api/v1/ ")
        #expect(problem == nil)
        #expect(settings.vertexProxyURL == "https://\(host)")
        #expect(proxy.status == .works)
        #expect(proxy.routesGemini)
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
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
        #expect(!proxy.routesGemini)
    }

    @Test func aKeyWithoutThePrefixIsNotSaved() async {
        let (proxy, host) = ProxyFixture.proxy(key: nil)
        let problem = await proxy.setKey("sk-or-v1-0123456789abcdef0123456789")
        #expect(problem == "Vertex proxy keys start with “sk-vp-”.")
        #expect(proxy.maskedKey == nil)
        #expect(proxy.apiKey() == nil)
        #expect(!proxy.routesGemini)
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty, "nothing is checked")
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
        #expect(!proxy.routesGemini)
    }

    @Test func theCheckSaysWhatWentWrong() async {
        let cases: [(StubURLProtocol.Reply, VertexProxyStatus)] = [
            (ProxyFixture.error(401, "API key not valid.", code: "UNAUTHENTICATED"), .keyRejected("API key not valid.")),
            (StubURLProtocol.Reply(error: .cannotFindHost), .unreachable),
            (StubURLProtocol.Reply(status: 404, body: #"{"detail":"Not Found"}"#),
             .failed("No Vertex proxy answers at this address.")),
            (StubURLProtocol.Reply(body: "<html></html>"), .failed(VertexProxy.notAProxyMessage)),
        ]
        for (reply, expected) in cases {
            let (proxy, _) = ProxyFixture.proxy([reply])
            await proxy.validate()
            #expect(proxy.status == expected)
        }
    }

    @Test func useForGeminiSwitchesRoutingWithoutForgetting() {
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
                == "Ready · Vertex proxy")
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
        #expect(result.provider == "Vertex AI")
        #expect(result.costUSD == 0.0042)
        #expect(result.modelID == "google/gemini-3.8-flash")
        #expect(StubURLProtocol.registry.requests(for: proxyHost).count == 1)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
        #expect(proxy.status == .works)
    }

    @Test func aDictationsTwoRequestsAtOnceBothGoToTheProxy() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([ProxyFixture.answer("one"), ProxyFixture.answer("one")])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash, hedge: .race)
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
        #expect(result.provider == "Vertex AI")
        #expect(result.costUSD == 0.001)
        #expect(StubURLProtocol.registry.requests(for: proxyHost).count == 1)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func cloudParakeetStillGoesThroughOpenRouter() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy()
        let (service, openRouterHost) = ProxyFixture.service(
            openRouterReplies: [StubURLProtocol.Reply(body: #"{"text":"hi","usage":{"seconds":1,"cost":0.0001}}"#)],
            proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .parakeetCloud)
        #expect(result.text == "hi")
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).count == 1)
        #expect(StubURLProtocol.registry.requests(for: proxyHost).isEmpty)
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

    @Test func withOnlyTheProxyGeminiWorksAndParakeetCloudNeedsAnOpenRouterKey() async throws {
        let (proxy, _) = ProxyFixture.proxy([ProxyFixture.answer("Только прокси.")])
        let (service, openRouterHost) = ProxyFixture.service(openRouterKey: nil, proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(result.text == "Только прокси.")
        await #expect(throws: AppError.openRouterMissingKey) {
            try await service.transcribe(ProxyFixture.speech(), engine: .parakeetCloud)
        }
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
        let result = try await send(Data([1, 2]), "Transcribe the call.", 2)
        #expect(result.text == "[00:00-00:02] Anna: Hi.")
        #expect(result.costUSD == 0.03)
        #expect(StubURLProtocol.registry.requests(for: proxyHost).count == 1)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
        proxy.isEnabled = false
        await #expect(throws: AppError.openRouterMissingKey) { try await send(Data([1]), "x", 1) }
    }

    @Test func routeAndKeyStatusPerEngine() {
        let (proxy, _) = ProxyFixture.proxy()
        let account = OpenRouterAccount.preview(status: .missing)
        #expect(CloudRoute.provider(for: .geminiFlash, proxy: proxy) == .vertexProxy)
        #expect(CloudRoute.provider(for: .parakeetCloud, proxy: proxy) == .openRouter)
        #expect(CloudRoute.provider(for: .parakeet, proxy: proxy) == nil)
        #expect(CloudRoute.keyStatus(for: .geminiFlash, account: account, proxy: proxy) == .checking)
        #expect(CloudRoute.keyStatus(for: .parakeetCloud, account: account, proxy: proxy) == .missing)
        proxy.isEnabled = false
        #expect(CloudRoute.provider(for: .geminiFlash, proxy: proxy) == .openRouter)
        #expect(CloudRoute.keyStatus(for: .geminiFlash, account: account, proxy: proxy) == .missing)
        #expect(CloudRoute.provider(for: .geminiFlash, proxy: nil) == .openRouter)
    }
}

// MARK: - What the app says

@MainActor
@Suite struct VertexProxyCopyTests {
    @Test func everyProxyFailureNamesTheProxyAndPointsToModels() {
        let failures: [VertexProxyFailure] = [.keyUnreadable, .keyRejected("x"), .spendLimit("x"), .unreachable,
                                              .forbidden("x"), .unavailable("x"), .badRequest("x"), .tooLarge]
        for failure in failures {
            let notice = AppError.vertexProxy(failure).notice(recordingID: UUID(), fallbackEngine: .parakeet,
                                                              engine: .geminiFlash)
            #expect(notice.title.contains("Vertex proxy"), "\(failure)")
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

    @Test func homeRowsSayWhatTheProxyDid() {
        #expect(DictationController.homeFailureReason(.vertexProxy(.spendLimit("x")), making: .polish)
                == "Your Vertex proxy hit its spend limit.")
        #expect(DictationController.homeFailureReason(.vertexProxy(.unreachable), making: .transcription(.geminiFlash))
                == "Couldn’t reach your Vertex proxy. Check its address in Models.")
    }

    @Test func homeAsksToFixTheProxyNotOpenRouter() {
        let input = HubAttention.Input(microphone: .granted, accessibility: .granted, accessibilityLikelyStale: false,
                                       fnKeyUsage: .doNothing, pushToTalkUsesFn: true, engine: .geminiFlash,
                                       localState: .notInstalled, keyStatus: .invalid("no"), provider: .vertexProxy)
        let item = HubAttention.items(input).first { $0.id == "key" }
        #expect(item?.title == "Your Vertex proxy rejected the key")
        var spent = input
        spent.keyStatus = .noCredit(KeyInfo(label: VertexProxy.label))
        #expect(HubAttention.items(spent).first { $0.id == "key" }?.title == "Your Vertex proxy hit its spend limit")
        var openRouter = input
        openRouter.provider = .openRouter
        #expect(HubAttention.items(openRouter).first { $0.id == "key" }?.title == "Your OpenRouter key stopped working")
    }

    @Test func theDiagnosticsSayWhereGeminiGoesButNeverTheKeyOrAddress() {
        let settings = AppSettings.inMemory()
        let (proxy, host) = ProxyFixture.proxy(settings: settings)
        let line = DiagnosticSettingsSummary(settings: settings, keySaved: true,
                                             vertexProxy: DiagnosticSettingsSummary.vertexProxyState(proxy)).line
        #expect(line.contains("vertexProxy=gemini"))
        #expect(!line.contains(ProxyFixture.key) && !line.contains(host))
        proxy.isEnabled = false
        #expect(DiagnosticSettingsSummary.vertexProxyState(proxy) == "off")
        #expect(DiagnosticSettingsSummary.vertexProxyState(nil) == "notSet")
        let route = EngineCLI.geminiRouteLine(proxy)
        #expect(route.contains("switched off") && !route.contains(ProxyFixture.key))
        proxy.isEnabled = true
        #expect(EngineCLI.geminiRouteLine(proxy) == "Vertex proxy (\(host), key saved)")
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
            #expect(!text.contains("sk-vp-"))
        }
    }
}

/// The client's log lines, as the app writes them, for proxy requests: never the key.
@MainActor
@Suite(.serialized) struct VertexProxyLogTests {
    @Test func theKeyNeverReachesTheDiagnosticLog() async throws {
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
        // Another suite may stop the shared log meanwhile; when it kept running, the proxy's lines are there.
        if !text.isEmpty { #expect(text.contains("vertexProxy")) }
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

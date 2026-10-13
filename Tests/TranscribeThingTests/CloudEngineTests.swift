import AppKit
import Foundation
import Testing
@testable import TranscribeThing

// The cloud models (Gemini 3.8 Flash and Gemini 4 Argon) and what stays of the retired cloud Parakeet: engine
// metadata, provider lookup, History that still reads it, and notices.

private func generationReply(_ provider: String?) -> StubURLProtocol.Reply {
    let name = provider.map { "\"\($0)\"" } ?? "null"
    return StubURLProtocol.Reply(body: #"{"data":{"id":"gen-1","api_type":"chat","model":"google/gemini-4-argon","provider_name":\#(name),"total_cost":0.0001,"created_at":"2026-09-27T10:00:00Z"}}"#)
}

// MARK: - Engine metadata

@Suite struct CloudEngineFactsTests {
    @Test func rawValuesAreStableAndOrderIsLocalThenGemini() {
        #expect(EngineID.allCases.map(\.rawValue) == ["parakeet", "parakeetCloud", "geminiFlash", "geminiArgon",
                                                      "geminiPro"], "retired models stay readable")
        #expect(EngineID.offered == [.parakeet, .geminiFlash, .geminiArgon])
        #expect(EngineID.allCases.filter(\.isRetired) == [.parakeetCloud, .geminiPro])
        #expect(EngineID.localEngines == [.parakeet])
        #expect(EngineID.geminiEngines == [.geminiFlash, .geminiArgon])
    }

    @Test func namesAreUniqueAndTheRetiredCloudParakeetKeepsItsOwn() {
        #expect(Set(EngineID.allCases.map(\.displayName)).count == EngineID.allCases.count)
        #expect(Set(EngineID.allCases.map(\.shortName)).count == EngineID.allCases.count)
        #expect(EngineID.parakeetCloud.displayName == "Parakeet v3 · Cloud")
        #expect(EngineID.geminiArgon.displayName == "Gemini 4 Argon")
        #expect(EngineID.geminiArgon.shortName == "Gemini 4 Argon")
        #expect(EngineID.geminiArgon.glyph == "A")
    }

    @Test func argonFacts() {
        #expect(EngineID.geminiArgon.openRouterModelID == "google/gemini-4-argon")
        #expect(EngineID.geminiArgon.provider == "Google AI Studio")
        #expect(EngineID.geminiArgon.isGemini && EngineID.geminiArgon.isCloud && !EngineID.geminiArgon.isRetired)
        #expect(EngineID.geminiArgon.badges == ["Cloud"])
        #expect(EngineID.geminiArgon.approxDownloadBytes == nil)
        #expect(OpenRouterClient.engine(forModel: "google/gemini-4-argon") == .geminiArgon)
        #expect(OpenRouterClient.engine(forModel: "google/gemini-3.8-flash") == .geminiFlash)
        #expect(!EngineID.parakeet.isGemini && !EngineID.parakeetCloud.isGemini)
    }

    @Test(arguments: EngineID.allCases)
    @MainActor func symbolsExist(_ engine: EngineID) {
        #expect(NSImage(systemSymbolName: engine.symbolName, accessibilityDescription: nil) != nil)
    }

    /// Gemini's answer streams, so its timeout is a stall one, the same for any length of audio: two minutes without a
    /// byte for Flash, four for Argon, which can think longer before its first byte.
    @Test func geminisTimeoutIsAStallTimeout() {
        #expect(EngineID.geminiFlash.cloudTimeout == 120)
        #expect(EngineID.geminiArgon.cloudTimeout == 240)
        #expect(EngineID.parakeet.cloudTimeout == 0)
        #expect(EngineID.parakeetCloud.cloudTimeout == 0, "retired: it never runs")
    }

    @Test func cloudSessionTimeouts() {
        let config = URLSession.openRouterCloud.configuration
        #expect(config.timeoutIntervalForRequest == 180)
        #expect(config.timeoutIntervalForResource == 10_800, "a whole request, however long its answer streams")
    }

    @Test func noRouteHintIsGoogles() {
        let error = OpenRouterErrorMapper.map(status: 404, message: "No endpoints found", errorType: nil,
                                              retryAfter: nil, engine: .geminiArgon)
        guard case .openRouterNoRoute(let message) = error else {
            Issue.record("\(error)")
            return
        }
        #expect(message.contains("Google AI Studio"))
    }
}

// MARK: - Generation lookup

@Suite struct OpenRouterGenerationTests {
    @Test func decodesTheProviderName() async throws {
        let (client, host) = StubURLProtocol.client([generationReply("Together")])
        #expect(try await client.generationProvider(id: "gen-1 2", apiKey: "sk-or-v1-test") == "Together")
        let request = try #require(StubURLProtocol.registry.requests(for: host).first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/generation")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == [URLQueryItem(name: "id", value: "gen-1 2")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
    }

    @Test func notRecordedYetIsNil() async throws {
        let (client, _) = StubURLProtocol.client([.init(status: 404, body: #"{"error":{"code":404,"message":"Generation not found"}}"#),
                                                  generationReply(nil)])
        #expect(try await client.generationProvider(id: "gen-1", apiKey: "k") == nil)
        #expect(try await client.generationProvider(id: "gen-1", apiKey: "k") == nil)
    }

    @Test func otherFailuresThrow() async throws {
        let (client, _) = StubURLProtocol.client([.init(status: 401, body: #"{"error":{"message":"User not found.","code":401}}"#)])
        await #expect(throws: AppError.openRouterInvalidKey("User not found.")) {
            try await client.generationProvider(id: "gen-1", apiKey: "k")
        }
    }
}

// MARK: - TranscriptionService

@MainActor
@Suite struct ServedProviderTests {
    private func makeService(_ replies: [StubURLProtocol.Reply], key: String? = "sk-or-v1-test")
        -> (TranscriptionService, String, OpenRouterAccount) {
        let store = ModelStore.preview(states: [.parakeet: .ready])
        let (client, host) = StubURLProtocol.client(replies)
        let keyStore = KeyFileStore.inMemory(key)
        let account = OpenRouterAccount(keyStore: keyStore, client: client, debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: client,
                                           providerLookupDelay: .milliseconds(10))
        return (service, host, account)
    }

    /// A retired model never runs: the request never leaves.
    @Test func theRetiredCloudParakeetNeverRuns() async throws {
        let (service, host, _) = makeService([])
        await #expect(throws: AppError.self) {
            try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)),
                                         engine: .parakeetCloud)
        }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }

    @Test func servedProviderToleratesALateGenerationRecord() async throws {
        let (service, host, _) = makeService([.init(status: 404, body: #"{"error":{"code":404,"message":"Not found"}}"#),
                                              generationReply("Together")])
        #expect(await service.servedProvider(generationID: "gen-1") == "Together")
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
    }

    @Test func servedProviderGivesUpQuietly() async throws {
        let notFound = StubURLProtocol.Reply(status: 404, body: #"{"error":{"code":404,"message":"Not found"}}"#)
        let (service, host, _) = makeService([notFound, notFound])
        #expect(await service.servedProvider(generationID: "gen-1") == nil)
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)

        let (failing, failingHost, _) = makeService([.init(status: 500, body: "oops"), generationReply("Together")])
        #expect(await failing.servedProvider(generationID: "gen-1") == nil)
        #expect(StubURLProtocol.registry.requests(for: failingHost).count == 1, "only a 404 is worth asking again")

        let (keyless, keylessHost, _) = makeService([generationReply("Together")], key: nil)
        #expect(await keyless.servedProvider(generationID: "gen-1") == nil)
        #expect(StubURLProtocol.registry.requests(for: keylessHost).isEmpty)
    }

    @Test func servedProviderIsOneLookupForTheOneGeneration() async throws {
        let (service, host, _) = makeService([generationReply("Together"), generationReply("Someone Else")])
        #expect(await service.servedProvider(generationID: "gen-1") == "Together")
        let requests = StubURLProtocol.registry.requests(for: host)
        #expect(requests.count == 1)
        let url = try #require(requests.first?.url)
        #expect(url.path == "/api/v1/generation")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "id", value: "gen-1")])
    }
}

// MARK: - History and delivery

@MainActor
@Suite(.serialized) struct CloudHistoryTests {
    @Test func historyWithoutProviderStillLoads() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let old = #"""
        {"version":1,"entries":[{"audioDuration":4.5,"costUSD":0.0012,"createdAt":"2026-09-20T10:00:00.250Z",
        "engine":"geminiFlash","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","processingTime":1.5,"status":"success",
        "text":"Hello","voicedSeconds":3.25}]}
        """#
        try Data(old.utf8).write(to: paths.historyFile)
        let settings = AppSettings.inMemory()
        let store = HistoryStore(paths: paths, settings: settings)
        store.load()
        try await waitUntil { store.isLoaded }
        let entry = try #require(store.entries.first)
        #expect(entry.text == "Hello" && entry.engine == .geminiFlash && entry.provider == nil)

        store.upsert(TranscriptEntry(text: "Cześć", engine: .parakeetCloud, audioDuration: 2, voicedSeconds: 1.5,
                                     processingTime: 0.8, costUSD: 0.00005, provider: "Together"))
        store.flush()
        let raw = String(decoding: try Data(contentsOf: paths.historyFile), as: UTF8.self)
        #expect(raw.contains(#""provider":"Together""#) && raw.contains(#""engine":"parakeetCloud""#))
        // Flat for older builds and in its version: absent, not null, when unknown.
        #expect(raw.components(separatedBy: #""provider""#).count == 3, "absent, not null, when unknown")

        let reloaded = HistoryStore(paths: paths, settings: settings)
        reloaded.load()
        try await waitUntil { reloaded.isLoaded }
        #expect(reloaded.entries.map(\.provider) == ["Together", nil])
    }

    @Test func historyFromBeforeWhisperWasRemovedKeepsEveryEntry() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        // Written by a build that still offered Whisper on this Mac and through OpenRouter, plus one entry from
        // an engine no build of this one knows.
        let old = #"""
        {"version":1,"entries":[
        {"audioDuration":6,"createdAt":"2026-09-26T10:04:00.000Z","engine":"whisperCloud",
         "id":"11111111-1111-1111-1111-111111111111","processingTime":1.1,"status":"success","text":"Cloud text",
         "voicedSeconds":5,"costUSD":0.00016,"provider":"Groq"},
        {"audioDuration":5,"createdAt":"2026-09-26T10:03:00.000Z","engine":"whisper",
         "id":"22222222-2222-2222-2222-222222222222","processingTime":0.9,"status":"success","text":"Local text",
         "voicedSeconds":4},
        {"audioDuration":7,"createdAt":"2026-09-26T10:02:00.000Z","engine":"whisper","errorMessage":"Couldn’t transcribe",
         "id":"33333333-3333-3333-3333-333333333333","status":"failed","text":"","voicedSeconds":6},
        {"audioDuration":3,"createdAt":"2026-09-26T10:01:00.000Z","engine":"someFutureEngine",
         "id":"44444444-4444-4444-4444-444444444444","status":"success","text":"From the future","voicedSeconds":2},
        {"audioDuration":4,"createdAt":"2026-09-26T10:00:00.000Z","engine":"geminiFlash",
         "id":"55555555-5555-5555-5555-555555555555","status":"success","text":"Gemini text","voicedSeconds":3}
        ]}
        """#
        try Data(old.utf8).write(to: paths.historyFile)
        let settings = AppSettings.inMemory()
        let store = HistoryStore(paths: paths, settings: settings)
        store.load()
        try await waitUntil { store.isLoaded }

        // Each removed engine reads as Parakeet v3 on the same side; the rest of the entry is untouched.
        #expect(store.entries.map(\.engine) == [.parakeetCloud, .parakeet, .parakeet, .geminiFlash])
        #expect(store.entries.map(\.text) == ["Cloud text", "Local text", "", "Gemini text"])
        let cloud = try #require(store.entries.first)
        #expect(cloud.provider == "Groq" && cloud.costUSD == 0.00016 && cloud.processingTime == 1.1)
        let failed = try #require(store.entries.first { $0.status == .failed })
        #expect(failed.engine == .parakeet && failed.errorMessage == "Couldn’t transcribe")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        #expect(!siblings.contains { $0.hasPrefix("history-unreadable") }, "the file was read, not set aside")

        store.flush()
        let raw = String(decoding: try Data(contentsOf: paths.historyFile), as: UTF8.self)
        #expect(raw.contains(#""engine":"parakeetCloud""#) && !raw.contains(#""engine":"whisper"#))
    }

    @Test func deliveredCloudTranscriptLearnsItsProvider() async throws {
        let h = DictationControllerTests.make()
        var asked: [String] = []
        h.controller.providerLookupOverride = { id in
            asked.append(id)
            return "Together"
        }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "Hallo", engine: engine, processingTime: 0.4, costUSD: 0.00001,
                             generationID: "gen-1")
        }
        h.controller.insertOverride = { _ in .pasted }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .geminiArgon)
        try await waitUntil { h.history.entry(id: recording.id)?.provider != nil }
        #expect(h.history.entry(id: recording.id)?.provider == "Together")
        #expect(asked == ["gen-1"])
    }

    @Test func aResponseThatSaidItAllNeedsNoLookup() async throws {
        let h = DictationControllerTests.make()
        h.controller.providerLookupOverride = { _ in
            Issue.record("no lookup when the response named the provider and the cost")
            return nil
        }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "Hallo", engine: engine, processingTime: 0.4, costUSD: 0.00001,
                             provider: "Together", generationID: "gen-1")
        }
        h.controller.insertOverride = { _ in .pasted }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .geminiArgon)
        try await waitUntil { h.history.entry(id: recording.id) != nil }
        #expect(h.history.entry(id: recording.id)?.provider == "Together")
    }

    @Test func aMissingKeyRefusesArgonBeforeRecording() throws {
        let h = DictationControllerTests.make(models: [.parakeet: .ready], keyStatus: .missing)
        h.settings.lineup.main = .argon
        h.controller.send(.handsFreeToggle)
        #expect(h.recorder.starts == 0)
        #expect(h.controller.machine.capture == .idle)
        let notice = try #require(h.toasts.notices.first)
        #expect(notice.title == "Add your OpenRouter key")
        #expect(notice.body == "Gemini needs a key to transcribe.")
        #expect(notice.actions.map(\.kind) == [.openHub(.models), .selectEngine(.parakeet)])
    }
}

// MARK: - Notices

@Suite struct CloudNoticeTests {
    /// Nothing is refused up front, so "too large" is always OpenRouter's word. The same model would refuse it again:
    /// no Retry, the body says what takes it.
    @Test(arguments: [EngineID.geminiFlash, .geminiArgon])
    func tooLargeIsWhatOpenRouterSaid(_ engine: EngineID) {
        let notice = AppError.recordingTooLarge.notice(recordingID: UUID(), fallbackEngine: .parakeet, engine: engine)
        #expect(notice.title == "Too large to send to OpenRouter")
        #expect(notice.body?.hasPrefix(
            "OpenRouter refused this recording as too large. Parakeet v3 on this Mac takes any length.") == true)
        #expect(!notice.actions.contains { $0.kind == .retry })
    }

    /// Every cloud model is Gemini: OpenRouter's errors say "Gemini", whichever model and whatever an old History
    /// row's engine.
    @Test func openRouterCopySaysGemini() {
        for engine in [nil, EngineID.geminiFlash, .geminiArgon, .parakeet, .parakeetCloud] {
            let notice = AppError.openRouterRateLimited(retryAfter: nil).notice(recordingID: nil, fallbackEngine: nil,
                                                                              engine: engine)
            #expect(notice.title == "Gemini is rate-limited")
        }
        #expect(AppError.regionBlocked.notice(recordingID: nil, fallbackEngine: nil).title
            == "Gemini isn’t available in your region")
        #expect(AppError.openRouterProviderUnavailable("x").notice(recordingID: nil, fallbackEngine: nil,
                                                                   engine: .geminiArgon).title
            == "Google AI Studio is unavailable")
    }

    @Test func aTimeoutNamesTheModel() {
        let notice = AppError.timeout(.geminiArgon).notice(recordingID: nil, fallbackEngine: nil)
        #expect(notice.title == "Gemini 4 Argon took too long")
        #expect(notice.body == "Gemini didn’t answer in time.")
    }
}

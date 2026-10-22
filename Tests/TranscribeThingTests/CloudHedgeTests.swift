import Foundation
import os
import Testing
@testable import TranscribeThing

// Sending a request two or three times at once and taking the first answer (`CloudHedge`).

@Suite struct CloudHedgeTests {
    /// Hands each call its own index, in the order the calls start.
    private final class Calls: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (next: 0, cancelled: [Int]()))
        func next() -> Int { state.withLock { s in defer { s.next += 1 }; return s.next } }
        func cancelled(_ index: Int) { state.withLock { $0.cancelled.append(index) } }
        var cancelledCalls: [Int] { state.withLock { $0.cancelled } }
        var count: Int { state.withLock { $0.next } }
    }

    /// A call that answers `text` after `delays[index]`, or throws `failures[index]` then.
    private func work(_ calls: Calls, delays: [Double], texts: [String] = ["first", "second"],
                      failures: [Int: AppError] = [:])
        -> @Sendable (CloudHedge.Hooks) async throws -> CloudResult {
        { hooks in
            let index = calls.next()
            hooks.generation("gen-\(index)")
            do {
                try await Task.sleep(for: .seconds(delays[index]))
            } catch {
                calls.cancelled(index)
                throw error
            }
            if let failure = failures[index] { throw failure }
            var result = CloudResult(text: texts[index])
            result.generationID = "gen-\(index)"
            return result
        }
    }

    @Test func theFirstAnswerWinsAndTheOtherIsCancelled() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 2), .transcription, engine: .geminiFlash, modelName: "Gemini", progress: nil,
                                              work(calls, delays: [0.6, 0.02], texts: ["slow", "fast"]))
        #expect(result.text == "fast")
        #expect(result.otherGenerationIDs == ["gen-0"], "the cancelled one's cost is looked up later")
        try await waitUntil { calls.cancelledCalls == [0] }
        #expect(calls.count == 2, "the slow one is stopped")
    }

    @Test func aFailedRequestLeavesTheOtherToAnswer() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 2), .transcription, engine: .geminiFlash, modelName: "Gemini 3.8 Flash",
                                              progress: nil,
                                              work(calls, delays: [0.01, 0.1], texts: ["x", "answer"],
                                                   failures: [0: .openRouterProviderUnavailable("")]))
        #expect(result.text == "answer")
    }

    /// A model came back with nothing at all for speech (2026-10-14): the other request's words win.
    @Test func anEmptyAnswerWaitsForTheOtherOne() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 2), .transcription, engine: .geminiFlash, modelName: "Gemini 3.8 Flash",
                                              progress: nil, work(calls, delays: [0.01, 0.15], texts: ["", "words"]))
        #expect(result.text == "words")
    }

    /// Stray tokens without the asked-for tags wait for the other request too.
    @Test func anUntaggedAnswerWaitsForATaggedOne() async throws {
        let result = try await CloudHedge.run(.race(copies: 2), .transcription, engine: .geminiFlash, modelName: "Gemini 3.8 Flash",
                                              progress: nil) { _ in
            let fast = await Self.order.next() == 0
            if fast { var r = CloudResult(text: "!#"); r.answerTags = TaggedTranscript.Tags.none; return r }
            try await Task.sleep(for: .milliseconds(120))
            var r = CloudResult(text: "Раз, два, три."); r.answerTags = .pair; return r
        }
        #expect(result.text == "Раз, два, три.")
    }

    private actor Order { var n = 0; func next() -> Int { defer { n += 1 }; return n } }
    private static let order = Order()

    @Test func twoEmptyAnswersAreEmpty() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 2), .transcription, engine: .geminiFlash, modelName: "Gemini 3.8 Flash",
                                              progress: nil, work(calls, delays: [0.01, 0.05], texts: [" ", ""]))
        #expect(result.text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test func anEmptyAnswerStandsWhenTheOtherFails() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 2), .transcription, engine: .geminiFlash, modelName: "Gemini 3.8 Flash",
                                              progress: nil,
                                              work(calls, delays: [0.01, 0.05], texts: ["", "x"],
                                                   failures: [1: .openRouterProviderUnavailable("")]))
        #expect(result.text.isEmpty)
    }

    @Test func whenBothFailTheFirstFailureIsThrown() async {
        let calls = Calls()
        await #expect(throws: AppError.timeout(.parakeet)) {
            try await CloudHedge.run(.race(copies: 2), .transcription, engine: .geminiFlash, modelName: "Gemini 3.8 Flash", progress: nil,
                                     work(calls, delays: [0.01, 0.05],
                                          failures: [0: .timeout(.parakeet), 1: .openRouterTruncated("")]))
        }
    }

    /// Measuring pastes the first answer at once and lets the other run to its end, then says how much sooner the
    /// first one came.
    @Test func measuringAnswersAtOnceAndMeasuresTheOther() async throws {
        let calls = Calls()
        let measured = OSAllocatedUnfairLock<CloudHedge.Measurement?>(initialState: nil)
        let result = try await CloudHedge.run(.measure, .transcription, engine: .geminiFlash, modelName: "Gemini",
                                              progress: nil, measured: { m in measured.withLock { $0 = m } },
                                              work(calls, delays: [0.02, 1.0], texts: ["fast", "slow"]))
        #expect(result.text == "fast")
        #expect(measured.withLock { $0 } == nil, "the first answer doesn't wait for the other")
        try await waitUntil { measured.withLock { $0 } != nil }
        let m = try #require(measured.withLock { $0 })
        #expect(calls.cancelledCalls.isEmpty && m.kind == .transcription && m.modelName == "Gemini")
        #expect((m.second ?? 0) >= 0.99 && (m.saved ?? 0) > 0)
    }

    /// The pill hears the further of the two streams: its count never goes back when the other one reports.
    @Test func progressIsTheFurtherOfTheTwo() async throws {
        let heard = OSAllocatedUnfairLock(initialState: [ChatStreamProgress]())
        let calls = Calls()
        _ = try await CloudHedge.run(.race(copies: 2), .transcription, engine: .geminiFlash, modelName: "Gemini",
                                     progress: { p in heard.withLock { $0.append(p) } }) { hooks in
            let report = hooks.progress
            let index = calls.next()
            if index == 0 {
                report?(ChatStreamProgress(reasoningCharacters: 400, outputCharacters: 0))
                try await Task.sleep(for: .milliseconds(80))
                report?(ChatStreamProgress(reasoningCharacters: 400, outputCharacters: 30))
                return CloudResult(text: "first")
            }
            try await Task.sleep(for: .milliseconds(20))
            report?(ChatStreamProgress(reasoningCharacters: 100, outputCharacters: 0))
            try await Task.sleep(for: .seconds(1))
            return CloudResult(text: "second")
        }
        let reasoning = heard.withLock { $0.map(\.reasoningCharacters) }
        #expect(reasoning.allSatisfy { $0 == 400 })
        #expect(heard.withLock { $0.last?.outputCharacters } == 30)
    }

    // MARK: Three at once

    @Test func theFirstOfThreeWinsAndBothOthersAreCancelledAndLookedUp() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 3), .transcription, engine: .geminiFlash, modelName: "Gemini",
                                              progress: nil,
                                              work(calls, delays: [0.6, 0.02, 0.6], texts: ["slow", "fast", "slower"]))
        #expect(result.text == "fast")
        #expect(calls.count == 3, "three requests went")
        #expect(Set(result.otherGenerationIDs) == ["gen-0", "gen-2"], "both cancelled ones' costs are looked up later")
        try await waitUntil { calls.cancelledCalls.count == 2 }
        #expect(Set(calls.cancelledCalls) == [0, 2])
    }

    /// Only the requests OpenRouter had named can be looked up; the winner's own generation is never among them.
    @Test func anUnnamedRequestIsLeftOutOfTheLookups() async throws {
        let order = Calls()
        let result = try await CloudHedge.run(.race(copies: 3), .transcription, engine: .geminiFlash, modelName: "Gemini",
                                              progress: nil) { hooks in
            let index = order.next()
            if index == 0 {
                hooks.generation("gen-won")
                var r = CloudResult(text: "words"); r.generationID = "gen-won"; return r
            }
            if index == 1 { hooks.generation("gen-named") }
            try await Task.sleep(for: .seconds(1))
            return CloudResult(text: "late")
        }
        #expect(result.text == "words")
        #expect(result.otherGenerationIDs == ["gen-named"])
    }

    @Test func aWeakAnswerWaitsForTheOtherTwo() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 3), .transcription, engine: .geminiFlash,
                                              modelName: "Gemini 3.8 Flash", progress: nil,
                                              work(calls, delays: [0.01, 0.05, 0.15], texts: ["", " ", "words"]))
        #expect(result.text == "words")
    }

    @Test func aWeakAnswerStandsWhenTheOtherTwoFail() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 3), .transcription, engine: .geminiFlash,
                                              modelName: "Gemini 3.8 Flash", progress: nil,
                                              work(calls, delays: [0.01, 0.05, 0.1], texts: ["", "x", "y"],
                                                   failures: [1: .openRouterProviderUnavailable(""),
                                                              2: .openRouterTruncated("")]))
        #expect(result.text.isEmpty)
    }

    @Test func twoFailuresLeaveTheThirdToAnswer() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race(copies: 3), .transcription, engine: .geminiFlash,
                                              modelName: "Gemini 3.8 Flash", progress: nil,
                                              work(calls, delays: [0.01, 0.03, 0.1], texts: ["x", "y", "answer"],
                                                   failures: [0: .openRouterProviderUnavailable(""),
                                                              1: .timeout(.geminiFlash)]))
        #expect(result.text == "answer")
    }

    @Test func whenAllThreeFailTheFirstFailureIsThrown() async {
        let calls = Calls()
        await #expect(throws: AppError.timeout(.parakeet)) {
            try await CloudHedge.run(.race(copies: 3), .transcription, engine: .geminiFlash,
                                     modelName: "Gemini 3.8 Flash", progress: nil,
                                     work(calls, delays: [0.01, 0.05, 0.1], texts: ["a", "b", "c"],
                                          failures: [0: .timeout(.parakeet), 1: .openRouterTruncated(""),
                                                     2: .openRouterProviderUnavailable("")]))
        }
    }

    /// Esc before any answer: all three requests stop.
    @Test func cancellingTheCallerCancelsAllThree() async throws {
        let calls = Calls()
        let task = Task {
            try await CloudHedge.run(.race(copies: 3), .transcription, engine: .geminiFlash, modelName: "Gemini",
                                     progress: nil, work(calls, delays: [5, 5, 5], texts: ["a", "b", "c"]))
        }
        try await waitUntil { calls.count == 3 }
        task.cancel()
        try await waitUntil { calls.cancelledCalls.count == 3 }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func progressIsTheFurthestOfThree() async throws {
        let heard = OSAllocatedUnfairLock(initialState: [ChatStreamProgress]())
        let calls = Calls()
        _ = try await CloudHedge.run(.race(copies: 3), .transcription, engine: .geminiFlash, modelName: "Gemini",
                                     progress: { p in heard.withLock { $0.append(p) } }) { hooks in
            let report = hooks.progress
            switch calls.next() {
            case 0:
                try await Task.sleep(for: .milliseconds(10))
                report?(ChatStreamProgress(reasoningCharacters: 100, outputCharacters: 0))
                try await Task.sleep(for: .seconds(1))
                return CloudResult(text: "slow")
            case 1:
                try await Task.sleep(for: .milliseconds(30))
                report?(ChatStreamProgress(reasoningCharacters: 600, outputCharacters: 0))
                try await Task.sleep(for: .milliseconds(60))
                report?(ChatStreamProgress(reasoningCharacters: 600, outputCharacters: 40))
                return CloudResult(text: "first")
            default:
                try await Task.sleep(for: .milliseconds(50))
                report?(ChatStreamProgress(reasoningCharacters: 300, outputCharacters: 0))
                try await Task.sleep(for: .seconds(1))
                return CloudResult(text: "slower")
            }
        }
        let reasoning = heard.withLock { $0.map(\.reasoningCharacters) }
        #expect(reasoning == reasoning.sorted(), "the count never goes back")
        #expect(reasoning.last == 600 && heard.withLock { $0.last?.outputCharacters } == 40)
    }

    @Test func measuringSendsTwo() {
        #expect(CloudHedge.measure.copies == 2)
        #expect(CloudHedge.race(copies: 3).copies == 3)
    }
}

/// The service sends the very same request two or three times.
@MainActor
@Suite(.serialized) struct CloudHedgeServiceTests {
    private let recording = Recording(samples: [Float](repeating: 0.1, count: 16_000))

    @Test func aGeminiRequestGoesTwiceWithTheSameBody() async throws {
        let replies = [StubURLProtocol.Reply.stream(SSE.answer("Hello.")), .stream(SSE.answer("Hello."))]
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: KeyFileStore.inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        let result = try await service.transcribe(recording, engine: .geminiFlash, hedge: .race(copies: 2))
        #expect(result.text == "Hello.")
        let bodies = try StubURLProtocol.registry.bodies(for: host)
        #expect(bodies.count == 2)
        let decoded = try bodies.map { try #require(JSONSerialization.jsonObject(with: $0) as? NSDictionary) }
        #expect(decoded.count == 2 && decoded[0] == decoded[1])
    }

    @Test func threeAtOnceGoWithTheSameBody() async throws {
        let replies = [StubURLProtocol.Reply](repeating: .stream(SSE.answer("Hello.")), count: 3)
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: KeyFileStore.inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        let result = try await service.transcribe(recording, engine: .geminiFlash, hedge: .race(copies: 3))
        #expect(result.text == "Hello.")
        try await waitUntil { StubURLProtocol.registry.bodies(for: host).count == 3 }
        let decoded = try StubURLProtocol.registry.bodies(for: host).map {
            try #require(JSONSerialization.jsonObject(with: $0) as? NSDictionary)
        }
        #expect(decoded.count == 3 && decoded[0] == decoded[1] && decoded[1] == decoded[2])
    }

    @Test func withoutItTheRequestGoesOnce() async throws {
        let (client, host) = StubURLProtocol.client([.stream(SSE.answer("Hello."))])
        let account = OpenRouterAccount(keyStore: KeyFileStore.inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        _ = try await service.transcribe(recording, engine: .geminiFlash)
        #expect(try StubURLProtocol.registry.bodies(for: host).count == 1)
    }
}

/// A dictation's cost is what all its raced requests cost: each cancelled one's is added once OpenRouter has it.
@MainActor
@Suite(.serialized) struct CloudHedgeCostTests {
    private typealias H = DictationControllerTests

    @Test func theCancelledRequestsCostIsAddedToTheDictations() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.controller.cancelledGenerationDelay = .zero
        h.controller.generationLookupOverride = { id in
            id == "gen-other" ? GenerationDetails(provider: "Google AI Studio", costUSD: 0.00002) : nil
        }
        h.controller.transcribeOverride = { _, engine in
            var result = TranscriptResult(text: "Hello there.", engine: engine, processingTime: 0.9, costUSD: 0.00005,
                                          provider: "Google AI Studio", generationID: "gen-won")
            result.modelID = engine.openRouterModelID
            result.otherGenerationIDs = ["gen-other"]
            return result
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .geminiFlash)
        let kind = TranscriptVersionKind.transcription(.geminiFlash)
        try await waitUntil { h.history.entry(id: r.id)?.version(kind)?.metadata.pendingGenerationIDs == nil
            && h.history.entry(id: r.id)?.version(kind) != nil }
        let cost = try #require(h.history.entry(id: r.id)?.version(kind)?.metadata.costUSD)
        #expect(abs(cost - 0.00007) < 1e-12, "both requests, as one dictation")
    }

    /// Three at once: both cancelled ones' costs are added.
    @Test func bothCancelledRequestsCostsAreAdded() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.controller.cancelledGenerationDelay = .zero
        h.controller.generationLookupOverride = { id in
            switch id {
            case "gen-second": GenerationDetails(provider: "Google AI Studio", costUSD: 0.00002)
            case "gen-third": GenerationDetails(provider: "Google AI Studio", costUSD: 0.00003)
            default: nil
            }
        }
        h.controller.transcribeOverride = { _, engine in
            var result = TranscriptResult(text: "Hello there.", engine: engine, processingTime: 0.9, costUSD: 0.00005,
                                          provider: "Google AI Studio", generationID: "gen-won")
            result.modelID = engine.openRouterModelID
            result.otherGenerationIDs = ["gen-second", "gen-third"]
            return result
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .geminiFlash)
        let kind = TranscriptVersionKind.transcription(.geminiFlash)
        try await waitUntil { h.history.entry(id: r.id)?.version(kind)?.metadata.pendingGenerationIDs == nil
            && h.history.entry(id: r.id)?.version(kind) != nil }
        let cost = try #require(h.history.entry(id: r.id)?.version(kind)?.metadata.costUSD)
        #expect(abs(cost - 0.0001) < 1e-12, "all three requests, as one dictation")
    }
}

/// General → Experimental → Race requests decides how many times a dictation's Gemini request goes at once.
@MainActor
@Suite(.serialized) struct RaceRequestsDictationTests {
    private typealias H = DictationControllerTests

    /// A stream that stays open: the model still thinking, so every request that goes is still there to count.
    private static let thinking = StubURLProtocol.Reply.stream(
        ": OPENROUTER PROCESSING\n\n" + SSE.stream([SSE.chunk(reasoning: "Listening.")], done: false), staysOpen: true)

    @Test(arguments: [RaceRequests.off, .two, .three])
    func aDictationGoesAsManyTimesAsPicked(_ race: RaceRequests) async throws {
        let (client, host) = StubURLProtocol.client(Array(repeating: Self.thinking, count: 3))
        let h = H.make(keyStatus: .valid(KeyInfo()), client: client)
        h.controller.insertOverride = { _ in Issue.record("canceled before its text came"); return .pasted }
        h.settings.raceRequests = race
        h.controller.enqueue(H.recording(), engine: .geminiFlash)
        try await waitUntil { StubURLProtocol.registry.requests(for: host).count == race.rawValue }
        try await Task.sleep(for: .milliseconds(200))
        #expect(StubURLProtocol.registry.requests(for: host).count == race.rawValue)
        h.controller.handle(.cancel)
    }

    /// The setting is read as each dictation starts: picking 3 between two dictations changes the next one.
    @Test func theNextDictationFollowsAChange() async throws {
        let (client, host) = StubURLProtocol.client(Array(repeating: Self.thinking, count: 4))
        let h = H.make(keyStatus: .valid(KeyInfo()), client: client)
        h.controller.insertOverride = { _ in Issue.record("canceled before its text came"); return .pasted }
        #expect(h.settings.raceRequests == .off)
        h.controller.enqueue(H.recording(), engine: .geminiFlash)
        try await waitUntil { StubURLProtocol.registry.requests(for: host).count == 1 }
        h.controller.handle(.cancel)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        h.settings.raceRequests = .three
        h.controller.enqueue(H.recording(), engine: .geminiFlash)
        try await waitUntil { StubURLProtocol.registry.requests(for: host).count == 4 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(StubURLProtocol.registry.requests(for: host).count == 4)
        h.controller.handle(.cancel)
    }
}

/// Race requests is stored under its own key, off until picked.
@MainActor
@Suite struct RaceRequestsSettingTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    @Test func itIsOffUntilPickedAndKeptAcrossLaunches() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            #expect(settings.raceRequests == .off)
            #expect(settings.raceRequests.hedge == nil, "one request")
            settings.raceRequests = .three
            #expect(defaults.integer(forKey: "tt.raceRequests") == 3)
            let again = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            #expect(again.raceRequests == .three && again.raceRequests.hedge == .race(copies: 3))
            again.raceRequests = .two
            #expect(AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() }).raceRequests == .two)
        }
    }

    /// The day-old "Ask twice" switches still go at load, and say nothing about Race requests.
    @Test func theOldSwitchesDontTurnItOn() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: SettingsKey.sendsTwice.defaultsKey)
            defaults.set(true, forKey: SettingsKey.measuresSendingTwice.defaultsKey)
            let settings = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            #expect(settings.raceRequests == .off)
            #expect(defaults.object(forKey: SettingsKey.sendsTwice.defaultsKey) == nil)
            #expect(SettingsKey.raceRequests.defaultsKey != SettingsKey.sendsTwice.defaultsKey)
            settings.raceRequests = .two
            #expect(AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() }).raceRequests == .two,
                    "the cleanup leaves the new key alone")
        }
    }

    /// A number this build doesn't offer (a newer build's) leaves it off.
    @Test func anUnknownNumberIsOff() throws {
        try withDefaults { defaults in
            defaults.set(5, forKey: "tt.raceRequests")
            #expect(AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() }).raceRequests == .off)
        }
    }

    @Test func theDiagnosticsSayIt() {
        let settings = AppSettings.inMemory()
        #expect(DiagnosticSettingsSummary(settings: settings, keySaved: false).line.contains("raceRequests=off"))
        settings.raceRequests = .three
        #expect(DiagnosticSettingsSummary(settings: settings, keySaved: false).line.contains("raceRequests=3"))
    }
}

/// The stream names its generation as soon as OpenRouter does, so a request cancelled midway can still be looked up.
@MainActor
@Suite(.serialized) struct GenerationNamingTests {
    @Test func theStreamNamesItsGenerationEarly() async throws {
        let (client, _) = StubURLProtocol.client([.stream(SSE.answer("Hello."))])
        let named = OSAllocatedUnfairLock(initialState: [String]())
        let result = try await client.sendText("hello", route: try #require(PolishSelectionModel.geminiFlash.route),
                                               systemPrompt: "Polish it.", apiKey: "sk-or-v1-test", timeout: 10,
                                               generation: { id in named.withLock { $0.append(id) } })
        let ids = named.withLock { $0 }
        #expect(ids.count == 1 && ids.first == result.generationID && result.generationID != nil)
    }
}

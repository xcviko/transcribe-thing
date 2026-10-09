import Foundation
import os
import Testing
@testable import TranscribeThing

// Sending a request twice at once and taking the first answer (`CloudHedge`).

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
        let result = try await CloudHedge.run(.race, .transcription, engine: .geminiFlash, modelName: "Gemini", progress: nil,
                                              work(calls, delays: [0.6, 0.02], texts: ["slow", "fast"]))
        #expect(result.text == "fast")
        #expect(result.otherGenerationIDs == ["gen-0"], "the cancelled one's cost is looked up later")
        try await waitUntil { calls.cancelledCalls == [0] }
        #expect(calls.count == 2, "the slow one is stopped")
    }

    @Test func aFailedRequestLeavesTheOtherToAnswer() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race, .transcription, engine: .parakeetCloud, modelName: "Parakeet",
                                              progress: nil,
                                              work(calls, delays: [0.01, 0.1], texts: ["x", "answer"],
                                                   failures: [0: .openRouterProviderUnavailable("")]))
        #expect(result.text == "answer")
    }

    @Test func whenBothFailTheFirstFailureIsThrown() async {
        let calls = Calls()
        await #expect(throws: AppError.timeout(.parakeet)) {
            try await CloudHedge.run(.race, .transcription, engine: .parakeetCloud, modelName: "Parakeet", progress: nil,
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
        _ = try await CloudHedge.run(.race, .transcription, engine: .geminiFlash, modelName: "Gemini",
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
}

/// The service sends the very same request twice.
@MainActor
@Suite(.serialized) struct CloudHedgeServiceTests {
    private let recording = Recording(samples: [Float](repeating: 0.1, count: 16_000))

    @Test func aGeminiRequestGoesTwiceWithTheSameBody() async throws {
        let replies = [StubURLProtocol.Reply.stream(SSE.answer("Hello.")), .stream(SSE.answer("Hello."))]
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: KeyFileStore.inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        let result = try await service.transcribe(recording, engine: .geminiFlash, hedge: .race)
        #expect(result.text == "Hello.")
        let bodies = try StubURLProtocol.registry.bodies(for: host)
        #expect(bodies.count == 2)
        let decoded = try bodies.map { try #require(JSONSerialization.jsonObject(with: $0) as? NSDictionary) }
        #expect(decoded.count == 2 && decoded[0] == decoded[1])
    }

    @Test func withoutItTheRequestGoesOnce() async throws {
        let (client, host) = StubURLProtocol.client([.stream(SSE.answer("Hello."))])
        let account = OpenRouterAccount(keyStore: KeyFileStore.inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        _ = try await service.transcribe(recording, engine: .geminiFlash)
        #expect(try StubURLProtocol.registry.bodies(for: host).count == 1)
    }
}

/// A dictation's cost is what both requests of its pair cost: the cancelled one's is added once OpenRouter has it.
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

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
        -> @Sendable ((@Sendable (ChatStreamProgress) -> Void)?) async throws -> CloudResult {
        { _ in
            let index = calls.next()
            do {
                try await Task.sleep(for: .seconds(delays[index]))
            } catch {
                calls.cancelled(index)
                throw error
            }
            if let failure = failures[index] { throw failure }
            return CloudResult(text: texts[index])
        }
    }

    @Test func theFirstAnswerWinsAndTheOtherIsCancelled() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race, .transcription, engine: .geminiFlash, modelName: "Gemini", progress: nil,
                                              work(calls, delays: [0.6, 0.02], texts: ["slow", "fast"]))
        #expect(result.text == "fast")
        try await waitUntil { calls.cancelledCalls == [0] }
        #expect(calls.count == 2, "the slow one is stopped")
    }

    @Test func aFailedRequestLeavesTheOtherToAnswer() async throws {
        let calls = Calls()
        let result = try await CloudHedge.run(.race, .cleanup, engine: .parakeet, modelName: "Clean-up", progress: nil,
                                              work(calls, delays: [0.01, 0.1], texts: ["x", "answer"],
                                                   failures: [0: .openRouterProviderUnavailable("")]))
        #expect(result.text == "answer")
    }

    @Test func whenBothFailTheFirstFailureIsThrown() async {
        let calls = Calls()
        await #expect(throws: AppError.timeout(.parakeet)) {
            try await CloudHedge.run(.race, .cleanup, engine: .parakeet, modelName: "Clean-up", progress: nil,
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

    @Test func theCardSaysHowMuchSoonerAndTheAverage() {
        let m = CloudHedge.Measurement(kind: .cleanup, modelName: "Gemini 3 Flash", first: 0.9, second: 2.4)
        let one = DictationController.hedgeCard(m, tally: (1, 1.5))
        #expect(one.title == "1.5 s sooner by asking twice")
        #expect(one.body == "Clean-up by Gemini 3 Flash answered in 0.9 s and 2.4 s.")
        let more = DictationController.hedgeCard(m, tally: (4, 4.0))
        #expect(more.body?.hasSuffix("This launch: 1.0 s sooner on average over 4.") == true)
        let failed = DictationController.hedgeCard(CloudHedge.Measurement(kind: .transcription,
                                                                          modelName: "Gemini 3.8 Flash", first: 3.1),
                                                   tally: (0, 0))
        #expect(failed.title == "Asked twice · the other request failed")
        #expect(failed.body == "Gemini 3.8 Flash answered in 3.1 s.")
    }

    /// The pill hears the further of the two streams: its count never goes back when the other one reports.
    @Test func progressIsTheFurtherOfTheTwo() async throws {
        let heard = OSAllocatedUnfairLock(initialState: [ChatStreamProgress]())
        let calls = Calls()
        _ = try await CloudHedge.run(.race, .transcription, engine: .geminiFlash, modelName: "Gemini",
                                     progress: { p in heard.withLock { $0.append(p) } }) { report in
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

/// The settings that turn it on.
@MainActor
@Suite struct CloudHedgeSettingsTests {
    @Test func itsOffUntilTurnedOnAndMeasuresOnlyWhenAsked() {
        let settings = AppSettings.inMemory()
        #expect(settings.cloudHedge == nil)
        settings.measuresSendingTwice = true
        #expect(settings.cloudHedge == nil, "measuring alone sends nothing twice")
        settings.sendsTwice = true
        #expect(settings.cloudHedge == .measure)
        settings.measuresSendingTwice = false
        #expect(settings.cloudHedge == .race)
    }
}

/// The service sends the very same request twice.
@MainActor
@Suite(.serialized) struct CloudHedgeServiceTests {
    @Test func aCleanUpGoesTwiceWithTheSameBody() async throws {
        let replies = [StubURLProtocol.Reply.stream(SSE.answer("Hello.")), .stream(SSE.answer("Hello."))]
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: KeyFileStore.inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        let result = try await service.cleanUp("hello", of: .parakeet, hedge: .measure)
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
        _ = try await service.cleanUp("hello", of: .parakeet)
        #expect(try StubURLProtocol.registry.bodies(for: host).count == 1)
    }
}

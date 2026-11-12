import Foundation
import os

/// Two or three identical requests at once to the same model: a dictation's Gemini request, when General →
/// Experimental → Race requests says so (`RaceRequests`). A model's time varies a lot from one request to the next
/// (Gemini 3.8 Flash thinks anywhere from none to thousands of tokens), so the first of several answers is often much
/// sooner than any one alone.
enum CloudHedge: Sendable, Equatable {
    /// `copies` requests (2 or 3): the first answer is used and the others are cancelled, whatever they're doing. What
    /// they cost is looked up later by their generations (`CloudResult.otherGenerationIDs`) and added to the first
    /// one's.
    case race(copies: Int)
    /// Two requests: the first answer is used at once, and the other request runs to its end in the background: how
    /// much sooner the first one came is measured (`Measurement`, logged as `hedge.measured`).
    case measure

    /// How many requests go at once.
    var copies: Int {
        switch self {
        case .race(let copies): max(2, copies)
        case .measure: 2
        }
    }

    /// What the log calls the request: "transcription".
    enum Kind: String, Sendable { case transcription }

    /// What a request hears as it goes: its stream's progress (nil when nobody listens), and its generation id once
    /// OpenRouter names it.
    struct Hooks: Sendable {
        var progress: (@Sendable (ChatStreamProgress) -> Void)?
        var generation: @Sendable (String) -> Void
    }

    /// Both answers of a measured request, the first one's and the other one's.
    struct Measurement: Sendable, Equatable {
        var kind: Kind
        /// "Gemini 3.8 Flash", "Gemini 3 Flash".
        var modelName: String
        var first: TimeInterval
        /// nil when the other request failed.
        var second: TimeInterval?
        var reasoningFirst: Int?
        var reasoningSecond: Int?

        /// How much sooner the first answer came than the other.
        var saved: TimeInterval? { second.map { $0 - first } }
    }

    /// `work` `mode.copies` times at once; the first answer comes back as soon as it's there, with the other requests'
    /// generations in `otherGenerationIDs` where OpenRouter had named them. A request that fails leaves the others to
    /// answer; when all fail, the first failure is thrown. A weak answer (no text at all, or text without the tags the
    /// prompt asked for) waits for the others: a model can come back with nothing or with stray tokens ("!#", its own
    /// thoughts) for audio with speech in it, and another request often has the words; when every answer is weak, or
    /// the rest fail, the first weak one is the answer. `progress` hears the furthest of the streams, so the pill's
    /// count never goes back. Cancelling the caller before an answer cancels them all. `measured` hears both answers
    /// once the other is in too (`.measure` only).
    static func run(_ mode: CloudHedge, _ kind: Kind, engine: EngineID, modelName: String,
                    progress: (@Sendable (ChatStreamProgress) -> Void)?,
                    measured: (@Sendable (Measurement) -> Void)? = nil,
                    _ work: @escaping @Sendable (_ hooks: Hooks) async throws -> CloudResult) async throws -> CloudResult {
        let copies = mode.copies
        let merger = ProgressMerger(progress, copies: copies)
        let generations = OSAllocatedUnfairLock(initialState: [String?](repeating: nil, count: copies))
        let race = Race(copies: copies) { first, second in
            guard mode == .measure else { return }
            let measurement = Measurement(kind: kind, modelName: modelName, first: first.seconds,
                                          second: second.result == nil ? nil : second.seconds,
                                          reasoningFirst: first.result.reasoningTokens,
                                          reasoningSecond: second.result?.reasoningTokens)
            DiagnosticLog.shared.event(.engine, "hedge.measured", [
                "kind": kind.rawValue, "engine": engine, "first": measurement.first, "second": measurement.second,
                "saved": measurement.saved.map { Self.rounded($0) }, "secondFailed": second.result == nil ? true : nil,
                "reasoningFirst": measurement.reasoningFirst, "reasoningSecond": measurement.reasoningSecond,
                "costFirst": first.result.costUSD, "costSecond": second.result?.costUSD])
            measured?(measurement)
        }
        let tasks = (0..<copies).map { index in
            let hooks = Hooks(progress: merger.reporter(for: index)) { id in generations.withLock { $0[index] = id } }
            return Task {
                let started = ContinuousClock.now
                let outcome: Result<CloudResult, any Error>
                do {
                    outcome = .success(try await work(hooks))
                } catch {
                    outcome = .failure(error)
                }
                await race.finish(index, outcome, seconds: Self.seconds(started.duration(to: .now)))
            }
        }
        let first = try await withTaskCancellationHandler {
            try await race.firstAnswer()
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
        var result = first.result
        if case .race = mode {
            for (index, task) in tasks.enumerated() where index != first.index { task.cancel() }
            let others = generations.withLock { ids in ids.enumerated().filter { $0.offset != first.index } }
                .compactMap(\.element).filter { $0 != result.generationID }
            result.otherGenerationIDs = others
            DiagnosticLog.shared.event(.engine, "hedge.won", [
                "kind": kind.rawValue, "engine": engine, "copies": copies, "seconds": first.seconds,
                "reasoning": first.result.reasoningTokens, "otherNamed": others.count])
        }
        return result
    }

    /// The requests' answers as they come: the first good one goes to the caller at once, and `onLater` hears it with
    /// each later one's, as that one is in too.
    private actor Race {
        typealias Answer = (index: Int, result: CloudResult, seconds: TimeInterval)
        typealias Other = (result: CloudResult?, seconds: TimeInterval)

        private let copies: Int
        private var first: Answer?
        /// The first weak answer, held while another request may still bring words.
        private var weak: Answer?
        private var failures: [any Error] = []
        private var finished = 0
        private var waiter: CheckedContinuation<Answer, any Error>?
        private let onLater: @Sendable (Answer, Other) -> Void

        init(copies: Int, onLater: @escaping @Sendable (Answer, Other) -> Void) {
            self.copies = copies
            self.onLater = onLater
        }

        func finish(_ index: Int, _ outcome: Result<CloudResult, any Error>, seconds: TimeInterval) {
            finished += 1
            switch outcome {
            case .success(let result) where first == nil:
                let answer = (index, result, seconds)
                if Self.isWeak(result) {
                    if weak == nil { weak = answer }
                } else {
                    settle(answer)
                }
            case .success(let result):
                if let first { onLater(first, (result, seconds)) }
            case .failure(let error):
                if let first {
                    if !(error is CancellationError) { onLater(first, (nil, seconds)) }
                } else {
                    failures.append(error)
                }
            }
            if first == nil, finished == copies {
                if let weak {
                    settle(weak)
                } else {
                    waiter?.resume(throwing: firstFailure)
                    waiter = nil
                }
            }
        }

        private func settle(_ answer: Answer) {
            first = answer
            waiter?.resume(returning: answer)
            waiter = nil
        }

        private static func isWeak(_ result: CloudResult) -> Bool {
            result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || result.answerTags == TaggedTranscript.Tags.none
        }

        func firstAnswer() async throws -> Answer {
            if let first { return first }
            if finished == copies {
                if let weak { return weak }
                throw firstFailure
            }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }

        private var firstFailure: any Error {
            failures.first { !($0 is CancellationError) } ?? failures.first ?? CancellationError()
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (whole, attoseconds) = duration.components
        return rounded(Double(whole) + Double(attoseconds) / 1e18)
    }

    private static func rounded(_ seconds: TimeInterval) -> TimeInterval {
        (seconds * 1000).rounded() / 1000
    }

    /// The streams' progress as one: each count the furthest of them.
    private final class ProgressMerger: Sendable {
        private let forward: (@Sendable (ChatStreamProgress) -> Void)?
        private let legs: OSAllocatedUnfairLock<[ChatStreamProgress]>

        init(_ forward: (@Sendable (ChatStreamProgress) -> Void)?, copies: Int) {
            self.forward = forward
            legs = OSAllocatedUnfairLock(initialState: Array(repeating: ChatStreamProgress(), count: copies))
        }

        func reporter(for index: Int) -> (@Sendable (ChatStreamProgress) -> Void)? {
            guard let forward else { return nil }
            return { [legs] progress in
                let merged = legs.withLock { legs -> ChatStreamProgress in
                    legs[index] = progress
                    return ChatStreamProgress(reasoningCharacters: legs.map(\.reasoningCharacters).max() ?? 0,
                                              outputCharacters: legs.map(\.outputCharacters).max() ?? 0)
                }
                forward(merged)
            }
        }
    }
}

/// General → Experimental → Race requests: how many times each Gemini dictation's request goes at once, the first
/// answer pasted and the rest stopped. Off (once) by default. Stored as that number (`AppSettings.raceRequests`).
enum RaceRequests: Int, CaseIterable, Sendable, Identifiable {
    case off = 1, two = 2, three = 3

    var id: Int { rawValue }

    /// The picker's, and the diagnostics': "Off", "2", "3".
    var title: String { self == .off ? "Off" : "\(rawValue)" }

    /// How a dictation's request goes: once (nil), or raced (`CloudHedge.race`).
    var hedge: CloudHedge? { self == .off ? nil : .race(copies: rawValue) }
}

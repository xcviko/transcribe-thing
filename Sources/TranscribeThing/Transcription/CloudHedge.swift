import Foundation
import os

/// Two identical requests at once to the same model: every dictation's cloud request (Gemini 3.8 Flash, cloud
/// Parakeet). A model's time varies a lot from one request to the next (Gemini 3.8 Flash thinks anywhere from
/// none to thousands of tokens), so the first of two answers is often much sooner than either one alone.
enum CloudHedge: Sendable, Equatable {
    /// The first answer is used and the other request is cancelled, whatever it's doing. What it cost is looked up
    /// later by its generation (`CloudResult.otherGenerationIDs`) and added to the first one's.
    case race
    /// The first answer is used at once, and the other request runs to its end in the background: how much sooner the
    /// first one came is measured (`Measurement`, logged as `hedge.measured`).
    case measure

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

    /// `work` twice at once; the first answer comes back as soon as it's there, with the other request's generation in
    /// `otherGenerationIDs` when OpenRouter had named it. A request that fails leaves the other to answer; when both
    /// fail, the first failure is thrown. A weak answer (no text at all, or text without the tags the prompt asked
    /// for) waits for the other one: a model can come back with nothing or with stray tokens ("!#", its own
    /// thoughts) for audio with speech in it, and the other request often has the words; when both are weak, or the
    /// other fails, the weak one is the answer. `progress` hears the further of the two streams, so the pill's count
    /// never goes back. Cancelling the caller before an answer cancels both. `measured` hears both answers once the other is
    /// in too (`.measure` only).
    static func run(_ mode: CloudHedge, _ kind: Kind, engine: EngineID, modelName: String,
                    progress: (@Sendable (ChatStreamProgress) -> Void)?,
                    measured: (@Sendable (Measurement) -> Void)? = nil,
                    _ work: @escaping @Sendable (_ hooks: Hooks) async throws -> CloudResult) async throws -> CloudResult {
        let merger = ProgressMerger(progress)
        let generations = OSAllocatedUnfairLock(initialState: [String?](repeating: nil, count: 2))
        let race = Race { first, second in
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
        let tasks = (0..<2).map { index in
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
        if mode == .race {
            for (index, task) in tasks.enumerated() where index != first.index { task.cancel() }
            let others = generations.withLock { ids in ids.enumerated().filter { $0.offset != first.index } }
                .compactMap(\.element).filter { $0 != result.generationID }
            result.otherGenerationIDs = others
            DiagnosticLog.shared.event(.engine, "hedge.won", [
                "kind": kind.rawValue, "engine": engine, "seconds": first.seconds,
                "reasoning": first.result.reasoningTokens, "otherNamed": !others.isEmpty])
        }
        return result
    }

    /// The two requests' answers as they come: the first success goes to the caller at once, and `onSecond` hears
    /// it with the other's, once that one is in too.
    private actor Race {
        typealias Answer = (index: Int, result: CloudResult, seconds: TimeInterval)
        typealias Other = (result: CloudResult?, seconds: TimeInterval)

        private var first: Answer?
        /// An empty answer held while the other request may still bring words.
        private var empty: Answer?
        private var failures: [any Error] = []
        private var finished = 0
        private var waiter: CheckedContinuation<Answer, any Error>?
        private let onSecond: @Sendable (Answer, Other) -> Void

        init(onSecond: @escaping @Sendable (Answer, Other) -> Void) {
            self.onSecond = onSecond
        }

        func finish(_ index: Int, _ outcome: Result<CloudResult, any Error>, seconds: TimeInterval) {
            finished += 1
            switch outcome {
            case .success(let result) where first == nil && Self.isWeak(result) && finished < 2:
                empty = (index, result, seconds)
            case .success(let result) where first == nil:
                let answer = (index, result, seconds)
                first = answer
                waiter?.resume(returning: answer)
                waiter = nil
            case .success(let result):
                if let first { onSecond(first, (result, seconds)) }
            case .failure(let error):
                if let first {
                    if !(error is CancellationError) { onSecond(first, (nil, seconds)) }
                } else {
                    failures.append(error)
                }
            }
            if first == nil, finished == 2 {
                if let empty {
                    first = empty
                    waiter?.resume(returning: empty)
                } else {
                    waiter?.resume(throwing: firstFailure)
                }
                waiter = nil
            }
        }

        private static func isWeak(_ result: CloudResult) -> Bool {
            result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || result.answerTags == TaggedTranscript.Tags.none
        }

        func firstAnswer() async throws -> Answer {
            if let first { return first }
            if finished == 2 {
                if let empty { return empty }
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

    /// The two streams' progress as one: each count the further of the two.
    private final class ProgressMerger: Sendable {
        private let forward: (@Sendable (ChatStreamProgress) -> Void)?
        private let legs = OSAllocatedUnfairLock(initialState: [ChatStreamProgress(), ChatStreamProgress()])

        init(_ forward: (@Sendable (ChatStreamProgress) -> Void)?) {
            self.forward = forward
        }

        func reporter(for index: Int) -> (@Sendable (ChatStreamProgress) -> Void)? {
            guard let forward else { return nil }
            return { [legs] progress in
                let merged = legs.withLock { legs -> ChatStreamProgress in
                    legs[index] = progress
                    return ChatStreamProgress(
                        reasoningCharacters: max(legs[0].reasoningCharacters, legs[1].reasoningCharacters),
                        outputCharacters: max(legs[0].outputCharacters, legs[1].outputCharacters))
                }
                forward(merged)
            }
        }
    }
}

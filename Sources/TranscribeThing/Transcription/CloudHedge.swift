import Foundation
import os

/// Two identical requests at once to the same model (General → Experimental): a dictation's Gemini transcription, or
/// its clean-up. A model's time varies a lot from one request to the next (Gemini 3.8 Flash thinks anywhere from none
/// to thousands of tokens), so the first of two answers is often much sooner than either one alone.
enum CloudHedge: Sendable, Equatable {
    /// The first answer is used and the other request is cancelled.
    case race
    /// Both run to their end, the first answer is used, and the log says how long the second took
    /// (`hedge.measured`): what sending twice saves. The dictation waits for both, the pill with it.
    case measure

    /// What the log calls the request: "transcription", "cleanup".
    enum Kind: String, Sendable { case transcription, cleanup }

    /// `work` twice at once, the first answer used. A request that fails leaves the other to answer; when both fail,
    /// the first failure is thrown. `progress` hears the further of the two streams, so the pill's count never goes
    /// back. Cancelling the caller cancels both.
    static func run(_ mode: CloudHedge, _ kind: Kind, engine: EngineID,
                    progress: (@Sendable (ChatStreamProgress) -> Void)?,
                    _ work: @escaping @Sendable (_ progress: (@Sendable (ChatStreamProgress) -> Void)?) async throws
                        -> CloudResult) async throws -> CloudResult {
        let merger = ProgressMerger(progress)
        typealias Leg = (index: Int, outcome: Result<CloudResult, any Error>, seconds: TimeInterval)
        return try await withThrowingTaskGroup(of: Leg.self) { group in
            for index in 0..<2 {
                let report = merger.reporter(for: index)
                group.addTask {
                    let started = ContinuousClock.now
                    do {
                        let result = try await work(report)
                        return (index, .success(result), seconds(started.duration(to: .now)))
                    } catch {
                        return (index, .failure(error), seconds(started.duration(to: .now)))
                    }
                }
            }
            var first: (result: CloudResult, seconds: TimeInterval)?
            var second: (result: CloudResult?, seconds: TimeInterval)?
            var failures: [any Error] = []
            for try await leg in group {
                switch leg.outcome {
                case .success(let result) where first == nil:
                    first = (result, leg.seconds)
                    if mode == .race { group.cancelAll() }
                case .success(let result):
                    second = (result, leg.seconds)
                case .failure(let error) where first == nil:
                    failures.append(error)
                case .failure:
                    second = (nil, leg.seconds)
                }
                if first != nil, mode == .race { break }
            }
            try Task.checkCancellation()
            guard let first else {
                if let error = failures.first(where: { !($0 is CancellationError) }) ?? failures.first { throw error }
                throw CancellationError()
            }
            log(mode, kind, engine: engine, first: first, second: second)
            return first.result
        }
    }

    private static func log(_ mode: CloudHedge, _ kind: Kind, engine: EngineID,
                            first: (result: CloudResult, seconds: TimeInterval),
                            second: (result: CloudResult?, seconds: TimeInterval)?) {
        switch mode {
        case .race:
            DiagnosticLog.shared.event(.engine, "hedge.won", [
                "kind": kind.rawValue, "engine": engine, "seconds": first.seconds,
                "reasoning": first.result.reasoningTokens])
        case .measure:
            DiagnosticLog.shared.event(.engine, "hedge.measured", [
                "kind": kind.rawValue, "engine": engine, "first": first.seconds, "second": second?.seconds,
                "saved": second.map { $0.seconds - first.seconds },
                "secondFailed": second.flatMap { $0.result == nil ? true : nil },
                "reasoningFirst": first.result.reasoningTokens, "reasoningSecond": second?.result?.reasoningTokens,
                "costFirst": first.result.costUSD, "costSecond": second?.result?.costUSD])
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (whole, attoseconds) = duration.components
        return (Double(whole) + Double(attoseconds) / 1e18).rounded(toPlaces: 3)
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

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}

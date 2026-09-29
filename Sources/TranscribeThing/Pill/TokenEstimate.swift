import Foundation

/// Turns what a streamed answer has shown so far into the pill's live count. OpenRouter sends no running token
/// counts, and Gemini streams summaries of its thoughts far shorter than the reasoning it's billed for, so the number
/// is an estimate from characters, calibrated by the exact counts History already keeps for the same model.
struct TokenEstimate: Equatable, Sendable {
    /// Tokens per character of streamed reasoning. With no history yet it counts the visible text, about 4
    /// characters a token.
    var reasoningPerCharacter = 0.25
    /// Tokens per character of the answer: about 2.5 characters a token of Russian.
    var outputPerCharacter = 0.4

    /// How many past versions calibrate it at most, newest first.
    static let sampleLimit = 20
    /// A ratio outside this is a broken record, not a model: it's held to the edge.
    static let ratioRange = 0.05...20.0

    /// The estimate for the model `modelID` (an OpenRouter slug) from its last versions in `entries` (newest first):
    /// each ratio is the median of what they billed per character they streamed. A version that didn't record both
    /// counts is skipped; with none, the defaults stand. A slug OpenRouter answered with a date on
    /// ("openai/gpt-6-luna-20260922") counts as its model.
    static func learned(from entries: [TranscriptEntry], modelID: String?) -> TokenEstimate {
        var estimate = TokenEstimate()
        guard let modelID, !modelID.isEmpty else { return estimate }
        var reasoning: [Double] = []
        var output: [Double] = []
        var taken = 0
        search: for entry in entries {
            for version in entry.versions.reversed()
            where version.metadata.modelID?.hasPrefix(modelID) == true {
                guard taken < sampleLimit else { break search }
                taken += 1
                let usage = version.metadata.usage
                if let tokens = usage?.reasoningTokens, let characters = version.metadata.reasoningCharacters,
                   tokens > 0, characters > 0 {
                    reasoning.append(Double(tokens) / Double(characters))
                }
                let characters = version.text.count
                if let tokens = usage?.outputTokens, tokens > 0, characters > 0 {
                    output.append(Double(tokens) / Double(characters))
                }
            }
        }
        if let ratio = median(reasoning) { estimate.reasoningPerCharacter = clamped(ratio) }
        if let ratio = median(output) { estimate.outputPerCharacter = clamped(ratio) }
        return estimate
    }

    /// The count for `progress`: once the answer has started, the tokens written so far; before, the tokens
    /// thought. Each phase counts its own, so thinking matches History's "17.7k thinking" and writing starts from its
    /// first tokens. nil while nothing has streamed. Any character counts as at least one token.
    func count(for progress: ChatStreamProgress) -> PillTokenCount? {
        if progress.outputCharacters > 0 {
            return PillTokenCount(phase: .writing, tokens: Self.tokens(progress.outputCharacters, outputPerCharacter))
        }
        if progress.reasoningCharacters > 0 {
            return PillTokenCount(phase: .thinking,
                                  tokens: Self.tokens(progress.reasoningCharacters, reasoningPerCharacter))
        }
        return nil
    }

    private static func tokens(_ characters: Int, _ perCharacter: Double) -> Int {
        max(1, Int((Double(characters) * perCharacter).rounded()))
    }

    private static func clamped(_ ratio: Double) -> Double {
        min(ratioRange.upperBound, max(ratioRange.lowerBound, ratio))
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// The live count inside the processing pill: "~1.2k thinking", then "~340 writing".
struct PillTokenCount: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case thinking, writing
    }

    var phase: Phase
    var tokens: Int

    /// Calm rather than precise, as an estimate should read: "~7", tens under a thousand ("~640"), then "~1.2k",
    /// "~17.7k", "~123k".
    var text: String {
        "~" + (tokens < 1_000 ? "\(shownTokens)" : Fmt.tokens(tokens))
    }

    /// "thinking" or "writing".
    var word: String {
        switch phase {
        case .thinking: "thinking"
        case .writing: "writing"
        }
    }

    /// The number `text` shows, whole: 643 → 640, 1,249 → 1,200, 123,456 → 123,000.
    var shownTokens: Int {
        let tokens = max(0, tokens)
        return switch tokens {
        case ..<10: tokens
        case ..<1_000: tokens / 10 * 10
        case ..<100_000: Int((Double(tokens) / 100).rounded()) * 100
        default: Int((Double(tokens) / 1_000).rounded()) * 1_000
        }
    }

    /// VoiceOver: "Thinking, about 1,200 tokens".
    var spokenDescription: String {
        let number = shownTokens.formatted(.number.locale(Locale(identifier: "en_US")))
        return "\(phase == .thinking ? "Thinking" : "Writing"), about \(number) tokens"
    }
}

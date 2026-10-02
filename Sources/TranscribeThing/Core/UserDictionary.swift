import Foundation

/// The user's dictionary (Hub → Dictionary, or fn D over selected text): words, names and terms that Gemini 3.8 Flash
/// and GPT-6 Luna spell as written (`prompt(_:with:)`). Parakeet hears without instructions and can't use it. Words
/// keep the order they came in, each once (case aside); one JSON array under `SettingsKey.dictionary`.
struct UserDictionary: Equatable, Sendable {
    /// Oldest first.
    private(set) var words: [String] = []

    /// A word, a name or a short term: one line, at most this many characters.
    static let maxLength = 64
    /// More than this and the prompts grow long; the oldest go first.
    static let maxCount = 500

    enum AddResult: Equatable, Sendable {
        /// `replacing`: the same word with other capitals, which this spelling took the place of.
        case added(String, replacing: String? = nil)
        /// It's there already, as written here.
        case alreadyThere(String)
        case invalid(InvalidReason)
    }

    enum InvalidReason: Error, Equatable, Sendable {
        /// Nothing left once the spaces and punctuation around it are trimmed.
        case empty
        /// More than one line.
        case lines
        /// Longer than `maxLength`.
        case tooLong
        /// "<" or ">", which would break the prompt's own `<dictionary>` block.
        case tags
    }

    init(words: [String] = []) {
        for word in words { _ = add(word, typed: true) }
    }

    /// `text` as a dictionary word, or why it can't be one. Inner whitespace is collapsed. `typed`: written by hand in
    /// the Hub, so only the spaces around it go. Otherwise it's a selection, which picks up what's around a word: the
    /// quotes, the end punctuation of its sentence, and brackets it didn't open ("Wispr," → "Wispr", "«Flow»" →
    /// "Flow", "(GPT-6 Luna)." → "GPT-6 Luna"), while a term keeps its own (".NET", "U.S.", "f(x)").
    static func validated(_ text: String, typed: Bool = false) -> Result<String, InvalidReason> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { return .failure(.lines) }
        guard !trimmed.contains(where: { $0 == "<" || $0 == ">" }) else { return .failure(.tags) }
        var word = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !typed { word = trimmedSelection(word) }
        guard !word.isEmpty else { return .failure(.empty) }
        guard word.count <= maxLength else { return .failure(.tooLong) }
        return .success(word)
    }

    static func normalized(_ text: String, typed: Bool = false) -> String? {
        try? validated(text, typed: typed).get()
    }

    private static let quotes: Set<Character> = ["\"", "'", "«", "»", "“", "”", "‘", "’", "„"]
    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    /// What a selection picked up around the word, peeled off until nothing more comes away.
    private static func trimmedSelection(_ text: String) -> String {
        var word = Substring(text)
        while let peeled = peel(word), peeled != word { word = peeled.trimmingCharacters(in: .whitespaces)[...] }
        return String(word)
    }

    private static func peel(_ word: Substring) -> Substring? {
        guard let first = word.first, let last = word.last else { return nil }
        if quotes.contains(first) { return word.dropFirst() }
        if quotes.contains(last) { return word.dropLast() }
        // A sentence's end: ",", ";", ":", "?", "!", "…", and a final period unless it closes an abbreviation of
        // single letters ("U.S.", "Ph.D.", "e.g.").
        if ",;:?!…".contains(last) { return word.dropLast() }
        if last == ".", !isAbbreviation(word) { return word.dropLast() }
        // Brackets around all of it, or one the selection cut off from its partner.
        if let close = pairs[first], last == close { return word.dropFirst().dropLast() }
        if let close = pairs[first], !word.dropFirst().contains(close) { return word.dropFirst() }
        if let open = pairs.first(where: { $0.value == last })?.key, !word.dropLast().contains(open) {
            return word.dropLast()
        }
        return word
    }

    /// "U.S.", "Ph.D.": the period before the final one sets off a single letter.
    private static func isAbbreviation(_ word: Substring) -> Bool {
        let body = word.dropLast()
        guard let dot = body.lastIndex(of: ".") else { return false }
        let tail = body[body.index(after: dot)...]
        return tail.count == 1 && tail.allSatisfy(\.isLetter)
    }

    func contains(_ word: String) -> Bool {
        index(of: word) != nil
    }

    /// The same word with other capitals ("wispr" for "Wispr"). Letters that differ otherwise make another word:
    /// "все" and "всё", "Muller" and "Müller".
    private func index(of word: String) -> Int? {
        words.firstIndex { $0.compare(word, options: .caseInsensitive) == .orderedSame }
    }

    /// Adds `text` as `validated(_:typed:)` makes it. A word already there with other capitals is replaced by this
    /// spelling (the newer one is the one the user means), and the result says which it replaced.
    @discardableResult
    mutating func add(_ text: String, typed: Bool = false) -> AddResult {
        let word: String
        switch Self.validated(text, typed: typed) {
        case .success(let valid): word = valid
        case .failure(let reason): return .invalid(reason)
        }
        var replaced: String?
        if let i = index(of: word) {
            guard words[i] != word else { return .alreadyThere(word) }
            replaced = words.remove(at: i)
        }
        words.append(word)
        if words.count > Self.maxCount { words.removeFirst(words.count - Self.maxCount) }
        return .added(word, replacing: replaced)
    }

    mutating func remove(_ word: String) {
        words.removeAll { $0 == word }
    }

    // MARK: Prompts

    /// `prompt` followed by the dictionary, for a model that reads it: Gemini's (`heard`: it hears the words, in
    /// audio) or a model that reads a text (GPT-6 Luna's clean-up, Polish Selection's). In the prompt's own language:
    /// Russian when it has Cyrillic, else English. With no words, or an empty prompt (the CLI's `--prompt ""` sends
    /// only the audio), `prompt` as it is.
    static func prompt(_ prompt: String, with words: [String], heard: Bool) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !trimmed.isEmpty else { return prompt }
        let russian = trimmed.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let intro = switch (russian, heard) {
        case (true, true):
            "Мой словарь: слова, имена и термины, которые я говорю. Когда я говорю одно из них, пиши его точно так, как здесь, даже если слышится немного иначе. Обычные слова, которые просто похоже звучат, не меняй, а русские слова оставляй кириллицей."
        case (true, false):
            "Мой словарь: слова, имена и термины, которые я использую. Если в тексте имеется в виду одно из них, но написано оно иначе (с ошибкой или по звучанию), пиши его точно так, как здесь. Обычные слова, которые просто похожи, не меняй, а русские слова оставляй кириллицей."
        case (false, true):
            "The speaker's dictionary: words, names and terms they say. When they say one of them, write it exactly as listed here, even if it sounds a little different. Don't change ordinary words that only sound similar, and keep Russian words in Cyrillic."
        case (false, false):
            "The speaker's dictionary: words, names and terms they use. When the text means one of them but spells it differently (misspelled, or spelled by sound), write it exactly as listed here. Don't change ordinary words that only look or sound similar, and keep Russian words in Cyrillic."
        }
        return trimmed + "\n\n" + intro + "\n<dictionary>\n" + words.joined(separator: "\n") + "\n</dictionary>"
    }
}

extension UserDictionary: Codable {
    /// Lenient, as a stored value outlives builds: a value that isn't a list of strings leaves it empty, and each
    /// word is checked again.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([String].self)) ?? []
        self.init(words: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(words)
    }
}

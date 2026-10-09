import Foundation

/// The user's dictionary (Hub → Dictionary, or fn D over selected text): words, names and terms that Gemini 3.8 Flash
/// gets as a hint (Polish and Polish Selection too): they exist, and this is how they're spelled (`prompt(_:with:)`).
/// Parakeet hears without instructions and can't use it. Words keep the order they came in, each once (case aside); one JSON
/// array under `SettingsKey.dictionary`. The user may sort them into groups (`Group`) for their own overview on the
/// Dictionary page; the prompts get every word alike, and the groups are kept apart (`grouping`).
struct UserDictionary: Equatable, Sendable {
    /// Oldest first.
    private(set) var words: [String] = []
    /// The groups, in the order the Dictionary page shows them.
    private(set) var groups: [Group] = []
    /// Which group a word is in, by its spelling in lowercase, so a word respelled stays where it was. A word that
    /// isn't here is ungrouped.
    private var membership: [String: UUID] = [:]

    /// A group the user sorts words into on the Dictionary page.
    struct Group: Identifiable, Codable, Equatable, Sendable {
        var id = UUID()
        var name: String
    }

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
        // Brackets around all of it ("(a) and (b)" keeps its own), or one the selection cut off from its partner.
        if let close = pairs[first], last == close, opensAll(word, first, close) { return word.dropFirst().dropLast() }
        if let close = pairs[first], !word.dropFirst().contains(close) { return word.dropFirst() }
        if let open = pairs.first(where: { $0.value == last })?.key, !word.dropLast().contains(open) {
            return word.dropLast()
        }
        return word
    }

    /// The first character's bracket closes only at the last one: it holds all of `word`.
    private static func opensAll(_ word: Substring, _ open: Character, _ close: Character) -> Bool {
        var depth = 0
        for (i, c) in word.enumerated() {
            if c == open { depth += 1 } else if c == close { depth -= 1 }
            if depth == 0 { return i == word.count - 1 }
        }
        return false
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
        if words.count > Self.maxCount {
            for gone in words.prefix(words.count - Self.maxCount) { membership[Self.key(gone)] = nil }
            words.removeFirst(words.count - Self.maxCount)
        }
        return .added(word, replacing: replaced)
    }

    mutating func remove(_ word: String) {
        words.removeAll { $0 == word }
        if index(of: word) == nil { membership[Self.key(word)] = nil }
    }

    /// Takes back the add of `word` that made `after` out of `before`, keeping whatever changed since: the word goes,
    /// and the spelling it replaced and the oldest words it pushed out come back where they were, in their groups.
    mutating func undoAdding(_ word: String, before: UserDictionary, after: UserDictionary) {
        remove(word)
        for (i, taken) in before.words.enumerated() where !after.words.contains(taken) && index(of: taken) == nil {
            words.insert(taken, at: min(i, words.count))
            if let group = before.group(of: taken), groups.contains(where: { $0.id == group }) {
                membership[Self.key(taken)] = group
            }
        }
    }

    // MARK: Groups

    private static func key(_ word: String) -> String { word.lowercased() }

    /// The group `word` is in; nil when it's ungrouped.
    func group(of word: String) -> UUID? { membership[Self.key(word)] }

    /// The words of `group` (nil: the ungrouped ones), newest first, as the Dictionary page lists them.
    func words(in group: UUID?) -> [String] {
        words.reversed().filter { self.group(of: $0) == group }
    }

    /// A new group, named `name` (or "New group"), first among the groups.
    @discardableResult
    mutating func addGroup(named name: String = "") -> UUID {
        let group = Group(name: Self.groupName(name) ?? "New group")
        groups.insert(group, at: 0)
        return group.id
    }

    mutating func rename(group id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }), let name = Self.groupName(name) else { return }
        groups[i].name = name
    }

    /// One line, the spaces around it trimmed; nil when nothing's left.
    private static func groupName(_ name: String) -> String? {
        let line = name.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(60))
    }

    /// Puts `word` into `group` (nil: ungrouped).
    mutating func move(_ word: String, to group: UUID?) {
        guard index(of: word) != nil else { return }
        guard let group else {
            membership[Self.key(word)] = nil
            return
        }
        guard groups.contains(where: { $0.id == group }) else { return }
        membership[Self.key(word)] = group
    }

    /// Puts group `id` just before group `target`, or last when `target` is nil.
    mutating func moveGroup(_ id: UUID, before target: UUID?) {
        guard id != target, let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: from)
        let to = target.flatMap { t in groups.firstIndex { $0.id == t } } ?? groups.count
        groups.insert(group, at: to)
    }

    /// Deletes group `id`: its words go with it, or stay, ungrouped, when `keepingWords`.
    mutating func deleteGroup(_ id: UUID, keepingWords: Bool) {
        guard groups.contains(where: { $0.id == id }) else { return }
        if !keepingWords {
            let membership = membership
            words.removeAll { membership[Self.key($0)] == id }
        }
        membership = membership.filter { $0.value != id }
        groups.removeAll { $0.id == id }
    }

    /// The groups and who's in them, stored apart from the words (`SettingsKey.dictionaryGroups`): an older build
    /// reads the words as they always were. Set back, it keeps only words still here and groups that exist.
    struct Grouping: Codable, Equatable, Sendable {
        var groups: [Group] = []
        var membership: [String: UUID] = [:]
    }

    var grouping: Grouping {
        get { Grouping(groups: groups, membership: membership) }
        set {
            groups = newValue.groups
            let ids = Set(newValue.groups.map(\.id))
            let present = Set(words.map(Self.key))
            membership = newValue.membership.filter { ids.contains($0.value) && present.contains($0.key) }
        }
    }

    // MARK: Prompts

    /// `prompt` followed by the dictionary as a hint, not a rule: these words exist and are usually spelled this way,
    /// and the model decides what to make of it. For Gemini (`heard`: it hears the words, in audio) or a model that
    /// reads a text (Polish Selection's). In the prompt's own language: Russian when most of its letters
    /// are Cyrillic (an English prompt may quote a Russian example), else English. With no words, or an empty prompt
    /// (the CLI's `--prompt ""` sends only the audio), `prompt` as it is.
    static func prompt(_ prompt: String, with words: [String], heard: Bool) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !trimmed.isEmpty else { return prompt }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        let russian = cyrillic * 2 > letters.count
        let intro = switch (russian, heard) {
        case (true, true):
            "Подсказка: слова, имена и термины, которые я иногда говорю, и как они обычно пишутся. Если услышишь что-то из этого, скорее всего, имеется в виду такое написание. Решай сам, по смыслу."
        case (true, false):
            "Подсказка: слова, имена и термины, которые я иногда использую, и как они обычно пишутся. Если встретишь в тексте что-то из этого, скорее всего, имеется в виду такое написание. Решай сам, по смыслу."
        case (false, true):
            "A hint: words, names and terms the speaker sometimes says, and how they're usually spelled. If you hear one of them, it's most likely meant this way. Use your judgment."
        case (false, false):
            "A hint: words, names and terms the speaker sometimes uses, and how they're usually spelled. If the text has one of them, it's most likely meant this way. Use your judgment."
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

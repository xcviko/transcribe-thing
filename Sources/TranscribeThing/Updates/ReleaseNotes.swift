import Foundation

// Release notes as GitHub renders them, reduced to what the Software Update page draws: headings, lists (nested),
// paragraphs, code blocks and rules. Inline formatting (bold, code, links) is left to AttributedString.

enum ReleaseNotesBlock: Equatable, Sendable {
    /// 1...6
    case heading(level: Int, text: String)
    /// Lines keep their breaks, as on GitHub.
    case paragraph(String)
    case list(ReleaseNotesList)
    case code(String)
    case rule
}

struct ReleaseNotesList: Equatable, Sendable {
    var ordered: Bool
    /// The first item's number (ordered lists).
    var start: Int
    var items: [ReleaseNotesListItem]
}

struct ReleaseNotesListItem: Equatable, Sendable {
    var text: String
    var children: [ReleaseNotesList] = []
}

enum ReleaseNotes {
    // MARK: Tidying

    /// GitHub's auto-generated notes, made readable: "* Fix paste by @sam in https://github.com/o/r/pull/12"
    /// becomes "* Fix paste ([#12](…))", "**Full Changelog**: …/compare/v1...v2" a "Full changelog" link, the
    /// "What’s Changed" heading (each release already has a header) and HTML comments go, and bare URLs link.
    static func tidy(_ markdown: String) -> String {
        let text = stripComments(markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var output: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                output.append(line)
                continue
            }
            if inFence {
                output.append(line)
                continue
            }
            if isWhatsChangedHeading(trimmed) { continue }
            if let full = fullChangelog(trimmed) {
                output.append("[Full changelog](\(full))")
                continue
            }
            output.append(linkBareURLs(pullRequestCredits(line)))
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripComments(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<!--") {
            guard let close = result.range(of: "-->", range: open.upperBound..<result.endIndex) else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result
    }

    private static func isWhatsChangedHeading(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "’", with: "'").lowercased()
        return title == "what's changed"
    }

    private static let fullChangelogPattern = try! NSRegularExpression(
        pattern: #"^\*\*Full Changelog\*\*:?\s*(https?://\S+)$"#, options: [.caseInsensitive])

    private static func fullChangelog(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = fullChangelogPattern.firstMatch(in: line, range: range),
              let url = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[url])
    }

    /// "Title by @user in <pull URL>" → "Title ([#12](<pull URL>))"; "@user made their first contribution in
    /// <pull URL>" keeps the sentence and links the number the same way.
    private static let creditPattern = try! NSRegularExpression(
        pattern: #"\s+(?:by\s+@[A-Za-z0-9-]+(?:\[bot\])?\s+)?in\s+(https://github\.com/[^\s/]+/[^\s/]+/pull/(\d+))\s*$"#)

    private static func pullRequestCredits(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = creditPattern.firstMatch(in: line, range: range),
              let whole = Range(match.range, in: line),
              let url = Range(match.range(at: 1), in: line),
              let number = Range(match.range(at: 2), in: line) else { return line }
        return String(line[..<whole.lowerBound]) + " ([#\(line[number])](\(line[url])))"
    }

    private static let bareURLPattern = try! NSRegularExpression(pattern: #"(?<![(<\[\w/])https?://[^\s<>()\[\]]+"#)

    /// Wraps bare URLs in <…> so they become links; ones already inside a link or an autolink are left alone.
    private static func linkBareURLs(_ line: String) -> String {
        let matches = bareURLPattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard !matches.isEmpty else { return line }
        var result = line
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var url = String(result[range])
            // Sentence punctuation after a URL isn't part of it.
            while let last = url.last, ".,;:!?'\"".contains(last) { url.removeLast() }
            let end = result.index(range.lowerBound, offsetBy: url.count)
            result.replaceSubrange(range.lowerBound..<end, with: "<\(url)>")
        }
        return result
    }

    // MARK: Parsing

    /// Block structure of `markdown` (tidy it first for GitHub's generated notes).
    static func blocks(_ markdown: String) -> [ReleaseNotesBlock] {
        var parser = Parser()
        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            parser.consume(line)
        }
        return parser.finish()
    }

    /// Inline markdown (bold, italics, code, links) with line breaks kept; plain text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// One plain line for the pill's toast: the first sentence of the first paragraph or list item that isn't a
    /// heading or the changelog link, without its pull request number, at most `limit` characters.
    static func summary(_ markdown: String, limit: Int = 90) -> String? {
        for block in blocks(tidy(markdown)) {
            let text: String
            switch block {
            case .paragraph(let paragraph): text = paragraph
            case .list(let list): text = list.items.first?.text ?? ""
            case .heading, .code, .rule: continue
            }
            var plain = String(inline(text).characters)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            plain = plain.replacingOccurrences(of: #"\s*\(#\d+\)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty, plain.lowercased() != "full changelog" else { continue }
            if let end = plain.range(of: ". ") {
                plain = String(plain[..<end.lowerBound]) + "."
            }
            guard plain.count > limit else { return plain }
            // Cut at a word boundary when there is one in the second half.
            var cut = String(plain.prefix(limit - 1))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
                cut = String(cut[..<space])
            }
            return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
        }
        return nil
    }

    // MARK: -

    private final class ListNode {
        let ordered: Bool
        let start: Int
        /// Column of the markers.
        let indent: Int
        var items: [ItemNode] = []

        init(ordered: Bool, start: Int, indent: Int) {
            self.ordered = ordered
            self.start = start
            self.indent = indent
        }

        var value: ReleaseNotesList {
            ReleaseNotesList(ordered: ordered, start: start, items: items.map(\.value))
        }
    }

    private final class ItemNode {
        var lines: [String]
        /// Column where the item's text starts; lines indented this far belong to it.
        let contentIndent: Int
        var children: [ListNode] = []

        init(text: String, contentIndent: Int) {
            lines = [text]
            self.contentIndent = contentIndent
        }

        var value: ReleaseNotesListItem {
            ReleaseNotesListItem(text: lines.joined(separator: "\n"), children: children.map(\.value))
        }
    }

    private struct Marker {
        var indent: Int
        var contentIndent: Int
        var ordered: Bool
        var number: Int
        var text: String
    }

    private struct Parser {
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        /// Open lists, outermost first.
        var stack: [ListNode] = []
        var fence: (marker: String, lines: [String])?
        var previousBlank = false

        mutating func consume(_ rawLine: String) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count

            if var open = fence {
                if trimmed.hasPrefix(open.marker) && trimmed.drop(while: { $0 == open.marker.first }).trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.code(open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
                return
            }
            if trimmed.isEmpty {
                flushParagraph()
                previousBlank = true
                return
            }
            defer { previousBlank = false }

            if indent < 4, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                fence = (String(trimmed.prefix(3)), [])
                return
            }
            if indent < 4, let heading = Self.heading(trimmed) {
                flushAll()
                blocks.append(heading)
                return
            }
            if indent < 4, !paragraph.isEmpty, stack.isEmpty, let level = Self.setextLevel(trimmed) {
                let text = paragraph.joined(separator: "\n")
                paragraph = []
                blocks.append(.heading(level: level, text: text))
                return
            }
            if indent < 4, Self.isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                return
            }
            if let marker = Self.marker(line) {
                flushParagraph()
                addItem(marker)
                return
            }
            if !stack.isEmpty {
                // Indented far enough for an open item, or a lazy continuation right under it.
                let owner = stack.last?.items.last
                if let item = deepestItem(acceptingIndent: indent) ?? (previousBlank ? nil : owner) {
                    item.lines.append(trimmed)
                    return
                }
                flushList()
            }
            let text = trimmed.hasPrefix(">") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            paragraph.append(text)
        }

        mutating func finish() -> [ReleaseNotesBlock] {
            if let open = fence {
                blocks.append(.code(open.lines.joined(separator: "\n")))
                fence = nil
            }
            flushAll()
            return blocks
        }

        private mutating func addItem(_ marker: Marker) {
            while stack.count > 1, let top = stack.last, marker.indent < top.indent {
                stack.removeLast()
            }
            let item = ItemNode(text: marker.text, contentIndent: marker.contentIndent)
            if let top = stack.last, let last = top.items.last, marker.indent >= last.contentIndent {
                let child = ListNode(ordered: marker.ordered, start: marker.number, indent: marker.indent)
                child.items.append(item)
                last.children.append(child)
                stack.append(child)
                return
            }
            if let top = stack.last, top.ordered == marker.ordered {
                top.items.append(item)
                return
            }
            if stack.count > 1 {
                // A different kind of list at the same depth: a sibling list under the same parent item.
                stack.removeLast()
                if let parent = stack.last?.items.last {
                    let sibling = ListNode(ordered: marker.ordered, start: marker.number, indent: marker.indent)
                    sibling.items.append(item)
                    parent.children.append(sibling)
                    stack.append(sibling)
                    return
                }
            }
            flushList()
            let list = ListNode(ordered: marker.ordered, start: marker.number, indent: marker.indent)
            list.items.append(item)
            stack = [list]
        }

        private func deepestItem(acceptingIndent indent: Int) -> ItemNode? {
            for list in stack.reversed() {
                if let item = list.items.last, indent >= item.contentIndent { return item }
            }
            return nil
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        private mutating func flushList() {
            guard let root = stack.first else { return }
            blocks.append(.list(root.value))
            stack = []
        }

        private mutating func flushAll() {
            flushParagraph()
            flushList()
        }

        static func heading(_ trimmed: String) -> ReleaseNotesBlock? {
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes) else { return nil }
            let rest = trimmed.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            // Closing hashes ("## Fixes ##") aren't part of the title.
            while text.hasSuffix("#") { text.removeLast() }
            return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
        }

        static func setextLevel(_ trimmed: String) -> Int? {
            if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
            if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        static func isRule(_ trimmed: String) -> Bool {
            let compact = trimmed.filter { $0 != " " }
            guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
            return compact.allSatisfy { $0 == first }
        }

        static func marker(_ line: String) -> Marker? {
            let indent = line.prefix(while: { $0 == " " }).count
            let rest = line.dropFirst(indent)
            guard let first = rest.first else { return nil }
            if "-*+".contains(first) {
                let after = rest.dropFirst()
                guard after.first == " " else { return nil }
                let spaces = min(4, after.prefix(while: { $0 == " " }).count)
                let text = after.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return Marker(indent: indent, contentIndent: indent + 1 + spaces, ordered: false, number: 1, text: text)
            }
            let digits = rest.prefix(while: \.isNumber)
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
            let body = after.dropFirst()
            guard body.first == " " else { return nil }
            let spaces = min(4, body.prefix(while: { $0 == " " }).count)
            let text = body.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return Marker(indent: indent, contentIndent: indent + digits.count + 1 + spaces, ordered: true,
                          number: number, text: text)
        }
    }
}

import SwiftUI

/// The user's dictionary (`UserDictionary`): words, names and terms Gemini 3.8 Flash and GPT-6 Luna spell as written.
/// Most come from fn D over selected text; the field here adds one by hand. Newest first, as chips that wrap.
struct DictionaryPage: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HubContext.self) private var hub

    @State private var draft = ""
    @State private var search = ""
    /// What the last Add said, under the field: "Already there", or why it can't go in.
    @State private var feedback: String?
    @FocusState private var fieldFocused: Bool
    @FocusState private var searchFocused: Bool

    /// From this many words on, a search field filters them.
    static let searchFrom = 16

    var body: some View {
        HubPage("Dictionary",
                subtitle: "Words, names and terms that Gemini 3.8 Flash and GPT-6 Luna write exactly as they are here.") {
            HubGroup("Add") {
                SettingsGroup {
                    addRow
                }
                tip
            }
            HubGroup(wordsTitle, footer: "Parakeet hears without instructions, so it doesn’t use the dictionary. "
                     + "Clean-up does: GPT-6 Luna tidies Parakeet’s text with it.") {
                if settings.dictionary.words.count >= Self.searchFrom {
                    HubSearchField(text: $search, prompt: "Search the dictionary", focused: $searchFocused)
                }
                Card(padding: Theme.Spacing.md) {
                    if settings.dictionary.words.isEmpty {
                        Text("Nothing here yet. Words you add show up here, newest first.")
                            .typeface(.callout)
                            .foregroundStyle(.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if shown.isEmpty {
                        Text("Nothing matches “\(search)”.")
                            .typeface(.callout)
                            .foregroundStyle(.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(shown, id: \.self) { word in
                                DictionaryChip(word: word) {
                                    withAnimation(Theme.Motion.snappy) { settings.dictionary.remove(word) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        // Typing again clears what the last Add said (the field emptied by an Add keeps it).
        .onChange(of: draft) { if !draft.isEmpty { feedback = tooLong ? Self.refusal(.tooLong) : nil } }
        // A search left behind when the field goes (words removed below `searchFrom`) would hide the rest.
        .onChange(of: settings.dictionary.words.count) { _, count in
            if count < Self.searchFrom { search = "" }
        }
    }

    private var wordsTitle: String {
        let count = settings.dictionary.words.count
        return count == 0 ? "Your words" : "Your words · \(count)"
    }

    /// Newest first, narrowed by the search while its field is there.
    private var shown: [String] {
        let words = settings.dictionary.words.reversed()
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, words.count >= Self.searchFrom else { return Array(words) }
        return words.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var canAdd: Bool { UserDictionary.normalized(draft, typed: true) != nil }

    /// Said as soon as it's typed, not only on Add: the button would just grey out.
    private var tooLong: Bool {
        if case .failure(.tooLong) = UserDictionary.validated(draft, typed: true) { true } else { false }
    }

    static func refusal(_ reason: UserDictionary.InvalidReason) -> String {
        switch reason {
        case .empty: ""
        case .lines: "One line at a time."
        case .tooLong: "Too long: up to \(UserDictionary.maxLength) characters."
        case .tags: "“<” and “>” can’t go in."
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.inkTertiary)
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .fieldPlaceholder("A word, a name or a term", isShown: draft.isEmpty)
                        .font(.system(size: 13))
                        .foregroundStyle(.ink)
                        .focused($fieldFocused)
                        .onSubmit(add)
                        .accessibilityLabel("Word to add")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(HubPalette.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(fieldFocused ? Color.accentRing : Color.strokeStrong,
                                      lineWidth: fieldFocused ? 1.5 : 1)
                }
                .animation(Theme.Motion.hover, value: fieldFocused)
                Button("Add", action: add)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .disabled(!canAdd)
            }
            if let feedback {
                Text(feedback)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .animation(Theme.Motion.fade, value: feedback)
    }

    /// The quick way, with the user's own keys: fn D over a word selected anywhere.
    @ViewBuilder private var tip: some View {
        if let keys = settings.shortcuts[.addToDictionary] {
            HStack(spacing: 6) {
                Text("Quicker: select a word in any app, start dictating and press")
                ShortcutChips(shortcut: keys, size: .small)
            }
            .typeface(.callout)
            .foregroundStyle(.inkSecondary)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        } else {
            Button("Add to dictionary has no shortcut. Set one in Shortcuts.") { hub.show(.shortcuts) }
                .buttonStyle(.plain)
                .typeface(.callout)
                .foregroundStyle(.accent)
                .padding(.horizontal, 4)
        }
    }

    private func add() {
        let outcome = settings.dictionary.add(draft, typed: true)
        switch outcome {
        case .added(_, let replaced):
            draft = ""
            feedback = replaced.map { "It replaces “\($0)”." }
            search = ""
        case .alreadyThere(let word):
            feedback = "“\(word)” is already there."
        case .invalid(let reason):
            feedback = reason == .empty ? nil : Self.refusal(reason)
        }
        if let feedback {
            AccessibilityNotification.Announcement(feedback).post()
        }
    }
}

/// A word of the dictionary: its text, and an × that takes it out.
private struct DictionaryChip: View {
    var word: String
    var remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(word)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.ink)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(hovering ? Color.ink : Color.inkTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove “\(word)”")
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(Capsule(style: .continuous).fill(hovering ? Color.hover : Color.bgSunken))
        .overlay { Capsule(style: .continuous).ring(1).fill(Color.stroke, style: FillStyle(eoFill: true)) }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

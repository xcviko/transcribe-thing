import SwiftUI

/// The user's dictionary (`UserDictionary`): words, names and terms Gemini 3.8 Flash gets as a hint.
/// Most come from fn D over selected text; the field here adds one by hand. Newest first, as chips that wrap.
struct DictionaryPage: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HubContext.self) private var hub

    @State private var draft = ""
    @State private var search = ""
    /// The group whose name is being typed: a new one, or one picked for Rename.
    @State private var renaming: UUID?
    /// What the last Add said, under the field: "Already there", or why it can't go in.
    @State private var feedback: String?
    @FocusState private var fieldFocused: Bool
    @FocusState private var searchFocused: Bool

    /// From this many words on, a search field filters them.
    static let searchFrom = 16

    var body: some View {
        HubPage("Dictionary", subtitle: "How you spell words and names: a hint for Gemini. Parakeet doesn’t use it.") {
            HubGroup("Add") {
                SettingsGroup {
                    addRow
                }
                tip
            }
            HubGroup(wordsTitle) {
                Button {
                    withAnimation(Theme.Motion.snappy) { renaming = settings.dictionary.addGroup() }
                } label: {
                    Label("New Group", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            } content: {
                if settings.dictionary.words.count >= Self.searchFrom {
                    HubSearchField(text: $search, prompt: "Search the dictionary", focused: $searchFocused)
                }
                if settings.dictionary.words.isEmpty && settings.dictionary.groups.isEmpty {
                    Card(padding: Theme.Spacing.md) {
                        Text("No words yet")
                            .typeface(.callout)
                            .foregroundStyle(.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if isSearching && sections.allSatisfy({ $0.words.isEmpty }) {
                    Card(padding: Theme.Spacing.md) {
                        Text("Nothing matches “\(search)”.")
                            .typeface(.callout)
                            .foregroundStyle(.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let ungrouped = shownSections.first(where: { $0.group == nil }) {
                    DictionarySection(model: ungrouped, renaming: $renaming)
                }
            }
            // The groups on a card of their own under Ungrouped's, a row each.
            if !groupSections.isEmpty {
                Section {
                    ForEach(groupSections) { section in
                        DictionarySection(model: section, renaming: $renaming)
                    }
                }
            }
        }
        // Typing again clears what the last Add said (the field emptied by an Add keeps it).
        .onChange(of: draft) { if !draft.isEmpty { feedback = problem.map(Self.refusal) } }
        // A search left behind when the field goes (words removed below `searchFrom`) would hide the rest.
        .onChange(of: settings.dictionary.words.count) { _, count in
            if count < Self.searchFrom { search = "" }
        }
    }

    private var wordsTitle: String {
        let count = settings.dictionary.words.count
        return count == 0 ? "Your words" : "Your words · \(count)"
    }

    private var isSearching: Bool {
        settings.dictionary.words.count >= Self.searchFrom && !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Ungrouped first (only named once there are groups), then each group, each newest first and narrowed by the
    /// search while its field is there.
    /// The sections that show: every one, or those with words matching the search.
    private var shownSections: [DictionarySection.Model] {
        sections.filter { !isSearching || !$0.words.isEmpty }
    }

    /// The groups' sections, unless there is nothing to show at all.
    private var groupSections: [DictionarySection.Model] {
        let empty = settings.dictionary.words.isEmpty && settings.dictionary.groups.isEmpty
        let noMatch = isSearching && sections.allSatisfy { $0.words.isEmpty }
        return empty || noMatch ? [] : shownSections.filter { $0.group != nil }
    }

    private var sections: [DictionarySection.Model] {
        let dictionary = settings.dictionary
        let query = search.trimmingCharacters(in: .whitespaces)
        func shown(_ words: [String]) -> [String] {
            isSearching ? words.filter { $0.localizedCaseInsensitiveContains(query) } : words
        }
        let ungrouped = dictionary.words(in: nil)
        var sections = [DictionarySection.Model(group: nil, words: shown(ungrouped), total: ungrouped.count,
                                                isOnly: dictionary.groups.isEmpty)]
        for group in dictionary.groups {
            let words = dictionary.words(in: group.id)
            sections.append(.init(group: group, words: shown(words), total: words.count))
        }
        return sections
    }

    private var canAdd: Bool { UserDictionary.normalized(draft, typed: true) != nil }

    /// Why the draft can't go in, said as soon as it's typed, not only on Add: the button would just grey out.
    private var problem: UserDictionary.InvalidReason? {
        if case .failure(let reason) = UserDictionary.validated(draft, typed: true), reason != .empty { reason } else { nil }
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
                        .labelsHidden()
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

    /// The quick way, with the user's own keys: fn D over a word selected anywhere; or what's missing for it.
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

/// What a drag on the Dictionary page carries: a word (its own text, so a word dragged in from another app adds it),
/// or a group, marked so no word can pass for one.
enum DictionaryDrag {
    private static let groupMark = "\u{E000}group:"

    static func payload(group id: UUID) -> String { groupMark + id.uuidString }

    static func group(in payload: String) -> UUID? {
        guard payload.hasPrefix(groupMark) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(groupMark.count)))
    }
}

/// Ungrouped, or one group: its words as chips that wrap, newest first. Words are dropped in from the others (or from
/// another app, which adds them), and a group is dragged by its handle to another place in the list. A group's name
/// is typed in place; its trash deletes it, with its words or leaving them ungrouped.
struct DictionarySection: View {
    struct Model: Identifiable {
        /// nil: Ungrouped.
        var group: UserDictionary.Group?
        /// Shown: the search narrows them.
        var words: [String]
        var total: Int
        /// Ungrouped with no groups beside it: the list of words, no header.
        var isOnly = false

        var id: String { group?.id.uuidString ?? "ungrouped" }
    }

    @Environment(AppSettings.self) private var settings
    var model: Model
    @Binding var renaming: UUID?

    @State private var targeted = false
    @State private var name = ""
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Card(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 10) {
                if !model.isOnly { header }
                if model.words.isEmpty {
                    Text(model.group == nil ? "No words" : "Drag words here")
                        .typeface(.callout)
                        .foregroundStyle(.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(model.words, id: \.self) { word in
                            DictionaryChip(word: word, group: model.group?.id) {
                                withAnimation(Theme.Motion.snappy) { settings.dictionary.remove(word) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.accentRing, lineWidth: 2)
                .opacity(targeted ? 1 : 0)
        }
        .animation(Theme.Motion.hover, value: targeted)
        .dropDestination(for: String.self) { items, _ in drop(items) } isTargeted: { targeted = $0 }
        .confirmationDialog("Delete “\(model.group?.name ?? "")”?", isPresented: $confirmingDelete) {
            Button("Delete the Group and Its \(model.total) Words", role: .destructive) { delete(keepingWords: false) }
            Button("Delete the Group, Keep the Words") { delete(keepingWords: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kept, its words move to Ungrouped.")
        }
    }

    @ViewBuilder private var header: some View {
        if let group = model.group {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.inkTertiary)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
                    .draggable(DictionaryDrag.payload(group: group.id)) {
                        Text(group.name)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule(style: .continuous).fill(Color.bgSunken))
                    }
                    .help("Drag to move the group")
                    .accessibilityHidden(true)
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .fieldPlaceholder("Group name", isShown: name.isEmpty)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .focused($nameFocused)
                    .onSubmit { commitName(group) }
                    .fixedSize()
                    .accessibilityLabel("Group name")
                Text("\(model.total)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.inkTertiary)
                Spacer(minLength: 0)
                Button {
                    if model.total == 0 { delete(keepingWords: true) } else { confirmingDelete = true }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.inkTertiary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete the group")
                .accessibilityLabel("Delete \(group.name)")
            }
            .onAppear {
                name = group.name
                if renaming == group.id { nameFocused = true }
            }
            .onChange(of: group.name) { _, new in if !nameFocused { name = new } }
            .onChange(of: renaming) { _, id in if id == group.id { nameFocused = true } }
            .onChange(of: nameFocused) { _, focused in
                if !focused { commitName(group) }
            }
            .contextMenu {
                Button("Rename") { renaming = group.id; nameFocused = true }
                Button("Move Up") { move(group.id, by: -1) }
                    .disabled(settings.dictionary.groups.first?.id == group.id)
                Button("Move Down") { move(group.id, by: 1) }
                    .disabled(settings.dictionary.groups.last?.id == group.id)
                Divider()
                Button("Delete…", role: .destructive) {
                    if model.total == 0 { delete(keepingWords: true) } else { confirmingDelete = true }
                }
            }
        } else {
            HStack(spacing: 8) {
                Text("Ungrouped")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
                Text("\(model.total)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.inkTertiary)
            }
            .frame(height: 22)
        }
    }

    private func commitName(_ group: UserDictionary.Group) {
        settings.dictionary.rename(group: group.id, to: name)
        name = settings.dictionary.groups.first { $0.id == group.id }?.name ?? name
        if renaming == group.id { renaming = nil }
    }

    private func delete(keepingWords: Bool) {
        guard let id = model.group?.id else { return }
        withAnimation(Theme.Motion.snappy) { settings.dictionary.deleteGroup(id, keepingWords: keepingWords) }
    }

    private func move(_ id: UUID, by step: Int) {
        let groups = settings.dictionary.groups
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let to = from + step
        guard groups.indices.contains(to) else { return }
        withAnimation(Theme.Motion.snappy) {
            settings.dictionary.moveGroup(id, before: step < 0 ? groups[to].id
                                                              : (to + 1 < groups.count ? groups[to + 1].id : nil))
        }
    }

    /// A group dropped here takes this group's place (Ungrouped: the first); a word moves into this group, and text
    /// from another app goes in as a new word.
    private func drop(_ items: [String]) -> Bool {
        var handled = false
        withAnimation(Theme.Motion.snappy) {
            for item in items {
                if let dragged = DictionaryDrag.group(in: item) {
                    let groups = settings.dictionary.groups
                    guard let from = groups.firstIndex(where: { $0.id == dragged }) else { continue }
                    guard let target = model.group?.id, let to = groups.firstIndex(where: { $0.id == target }) else {
                        settings.dictionary.moveGroup(dragged, before: groups.first?.id)
                        handled = true
                        continue
                    }
                    // Dragged down, it goes below the group it's dropped on; dragged up, above.
                    let before = from < to ? (to + 1 < groups.count ? groups[to + 1].id : nil) : target
                    settings.dictionary.moveGroup(dragged, before: before)
                    handled = true
                } else if settings.dictionary.words.contains(item) {
                    settings.dictionary.move(item, to: model.group?.id)
                    handled = true
                } else if case .added(let word, _) = settings.dictionary.add(item) {
                    settings.dictionary.move(word, to: model.group?.id)
                    handled = true
                }
            }
        }
        return handled
    }
}

/// A word of the dictionary: its text, and an × that takes it out. Dragged, it moves to another group; its menu moves
/// it too.
private struct DictionaryChip: View {
    @Environment(AppSettings.self) private var settings
    var word: String
    var group: UUID?
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
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .draggable(word) {
            Text(word)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule(style: .continuous).fill(Color.bgSunken))
        }
        .contextMenu {
            if !settings.dictionary.groups.isEmpty {
                Menu("Move To") {
                    Button("Ungrouped") { move(to: nil) }.disabled(group == nil)
                    ForEach(settings.dictionary.groups) { target in
                        Button(target.name) { move(to: target.id) }.disabled(group == target.id)
                    }
                }
            }
            Button("Remove", role: .destructive, action: remove)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func move(to target: UUID?) {
        withAnimation(Theme.Motion.snappy) { settings.dictionary.move(word, to: target) }
    }
}

import AppKit
import SwiftUI

/// Greeting, what needs attention, weekly stats and the searchable history. Audio or video dropped on it (or picked
/// with Transcribe File…) is transcribed into the history, by the model picked for it.
struct HomePage: View {
    @Environment(HubContext.self) private var hub
    @Environment(HistoryStore.self) private var history
    @Environment(AppSettings.self) private var settings
    @Environment(ModelStore.self) private var models
    @Environment(PermissionsCenter.self) private var permissions

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The transcript whose trash was clicked, waiting for Delete (Return) or Cancel (Escape).
    @State private var confirmingDelete: TranscriptEntry?
    @State private var recentlyDeleted: TranscriptEntry?
    @State private var undoToken = 0
    @State private var hoverGate = ScrollHoverGate()
    /// Files are being dragged over the page.
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                header
                attention
                StatsRow(stats: history.stats)
                HistorySection(
                    isEmpty: history.entries.isEmpty,
                    days: history.days(matching: query, now: hub.now),
                    query: query,
                    onDelete: { confirmingDelete = $0 },
                    onClearSearch: { query = "" })
            }
            .padding(.horizontal, HubLayout.pageHorizontal)
            .padding(.top, HubLayout.pageTop)
            .padding(.bottom, HubLayout.pageBottom + 20)
            .frame(maxWidth: HubLayout.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            // Under files dragged over it the page steps back, so the drop target reads alone.
            .opacity(showsDropTarget ? 0.06 : 1)
        }
        // Rows passing under a resting pointer don't light up one after another while the page moves.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in hoverGate.scrolled() }
        .environment(\.scrollHoverGate, hoverGate)
        // The window's own search field and the file button, in the toolbar as Finder has them.
        .searchable(text: $query, placement: .toolbar, prompt: "Search transcripts")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: pickFiles) {
                    Label("Transcribe a File…", systemImage: "arrow.down.doc")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Transcribe a File… (⌘O)")
            }
        }
        .background {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .overlay {
            if showsDropTarget {
                FileDropTarget(title: "Drop audio or video to transcribe", subtitle: "You’ll pick the model next.")
            }
        }
        .overlay(alignment: .bottom) { undoBar }
        .overlay(alignment: .bottom) { readingBar }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            // Files dropped while others are read, or while the model dialog is up, join them.
            hub.imports.add(files)
            return true
        } isTargeted: { targeted in
            withAnimation(Theme.Motion.fade) { dropTargeted = targeted }
        }
        // A sheet of the app's own: an alert shows three buttons at most, and drops the rest, Cancel too.
        .sheet(item: importBatch) { batch in
            ImportSheet(files: batch.files, imports: imports)
                .environment(settings)
        }
        .alert(imports.problem?.title ?? "", isPresented: Binding(get: { imports.prompt == .problem && imports.problem != nil },
                                                                 set: { if !$0 { imports.problemDismissed() } })) {
            // OK only closes it: the binding then moves on to what's next.
            Button("OK") {}
        } message: {
            Text(imports.problem?.message ?? "")
        }
        .alert("Delete This Transcript?", isPresented: Binding(get: { confirmingDelete != nil },
                                                              set: { if !$0 { confirmingDelete = nil } }),
               presenting: confirmingDelete) { entry in
            Button("Delete", role: .destructive) { delete(entry) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.audioFileName == nil ? "You can undo it for a few seconds."
                 : "Its recording goes too. You can undo it for a few seconds.")
        }
        .onAppear {
            if query.isEmpty { query = hub.initialSearch }
        }
    }

    private var showsDropTarget: Bool { dropTargeted || hub.previewDropTarget }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            TimelineView(.everyMinute) { context in
                Text(HubGreeting.text(for: hub.fixedNow ?? context.date, name: settings.userName.isEmpty ? hub.firstName : settings.displayName))
                    .typeface(.greeting)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Attention

    @ViewBuilder private var attention: some View {
        let items = HubAttention.items(.init(
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            accessibilityLikelyStale: permissions.accessibilityLikelyStale,
            fnKeyUsage: permissions.fnKeyUsage,
            pushToTalkUsesFn: settings.shortcuts[.pushToTalk]?.usesFunctionKey ?? false,
            engine: settings.mainEngine,
            localState: models.state(of: settings.mainEngine),
            keyStatus: hub.keyStatus(for: settings.mainEngine),
            localError: models.lastErrors[settings.mainEngine],
            provider: hub.provider(for: settings.mainEngine) ?? .openRouter,
            shortcutUnavailable: hub.dictation.isShortcutUnavailable))
        if !items.isEmpty {
            VStack(spacing: Theme.Spacing.xs) {
                ForEach(items) { item in
                    AttentionCard(item: item) { perform($0) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Theme.Motion.expand, value: items.map(\.id))
        }
    }

    private func perform(_ action: AttentionItem.Action) {
        switch action {
        case .requestMicrophone:
            let permissions = permissions
            Task { _ = await permissions.requestMicrophone() }
        case .requestAccessibility:
            permissions.requestAccessibility()
        case .openPane(let pane):
            permissions.open(pane)
        case .download(let engine):
            models.download(engine)
        case .openModels:
            hub.show(.models)
        case .openURL(let url):
            hub.open(url)
        }
    }

    // MARK: Transcribe a file

    /// Transcribe File…: audio or video, one or more.
    private func pickFiles() {
        guard !hub.isPreview else { return }
        FileImport.choose(message: "Choose audio or video to transcribe.") { [imports] urls in imports.add(urls) }
    }

    /// Reading the files and asking about them live with the Hub (`FileImport`), so leaving Home loses nothing.
    private var imports: FileImport { hub.imports }

    /// The files the dialog asks about while it's up. Going away (Esc, Cancel) leaves them untranscribed; a pick
    /// takes them first, so its dismissal finds nothing to drop. Read in the page's body, so the page follows them.
    private var importBatch: Binding<ImportBatch?> {
        let imports = imports
        let batch = imports.prompt == .models && !imports.pending.isEmpty ? ImportBatch(files: imports.pending) : nil
        return Binding(get: { batch }, set: { if $0 == nil { imports.dialogDismissed() } })
    }

    @ViewBuilder private var readingBar: some View {
        if let name = imports.reading.first {
            FileReadingBar(name: name)
        }
    }

    // MARK: Delete with undo

    private func delete(_ entry: TranscriptEntry) {
        withAnimation(Theme.Motion.collapse) {
            history.delete(entry.id)
            recentlyDeleted = entry
        }
        undoToken += 1
        let token = undoToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if token == undoToken {
                withAnimation(Theme.Motion.fade) { recentlyDeleted = nil }
            }
        }
    }

    @ViewBuilder private var undoBar: some View {
        if let entry = recentlyDeleted {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Transcript deleted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Button("Undo") {
                    withAnimation(Theme.Motion.expand) {
                        history.upsert(entry)
                        recentlyDeleted = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .underline()
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule(style: .continuous).fill(Color.pillFill))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}


// MARK: - Transcribe a file

/// The files one dialog asks about: another batch (files joined it) is another dialog.
private struct ImportBatch: Identifiable {
    var files: [ImportedAudio]
    var id: [UUID] { files.map(\.id) }
}

/// The dialog for `files`, its choices as things are now: a download finishing, or a key added, while it's up turns
/// its row on.
private struct ImportSheet: View {
    var files: [ImportedAudio]
    var imports: FileImport

    var body: some View {
        let choices = imports.choices(files.map(\.duration).max() ?? 0)
        ImportDialog(title: ImportChoices.title(fileNames: files.map(\.fileName)),
                     message: choices.message(seconds: files.reduce(0) { $0 + $1.duration }),
                     choices: choices,
                     start: { kind in imports.transcribe(files, as: kind) },
                     cancel: { imports.dialogDismissed() })
    }
}

// MARK: - Attention card

private struct AttentionCard: View {
    var item: AttentionItem
    var perform: (AttentionItem.Action) -> Void

    private var tint: Color {
        switch item.tone {
        case .error: .danger
        case .warning: .warning
        case .progress: .accent
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(item.body)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = item.progress {
                    ProgressBar(fraction: progress, height: 4)
                        .frame(maxWidth: 260)
                        .padding(.top, 4)
                } else if item.isIndeterminate {
                    ShimmerBar(height: 4)
                        .frame(maxWidth: 260)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            if let title = item.actionTitle, let action = item.action {
                Button(title) { perform(action) }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bgSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.055))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stats

private struct StatsRow: View {
    var stats: HistoryStats

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            StatTile(label: "Words this week", parts: [StatPart(value: Fmt.number(stats.wordsThisWeek), unit: "")]) {
                Sparkline(values: stats.dailyWords)
            }
            StatTile(label: "Average speed",
                     parts: [StatPart(value: stats.averageWPM.map { Fmt.number($0) } ?? StatPart.noValue, unit: "wpm")])
            StatTile(label: "Dictations", parts: [StatPart(value: Fmt.number(stats.totalDictations), unit: "total")])
        }
    }
}

private struct StatTile<Accessory: View>: View {
    var label: String
    var parts: [StatPart]
    var help: String?
    @ViewBuilder var accessory: Accessory

    init(label: String, parts: [StatPart], help: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        self.parts = parts
        self.help = help
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                if let help {
                    InfoHint(text: help)
                }
            }
            Spacer(minLength: 6)
            HStack(alignment: .bottom, spacing: 0) {
                value
                Spacer(minLength: 4)
                accessory
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .leading)
        .background(Color.sectionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(parts.map { "\($0.value) \($0.unit)" }.joined(separator: " "))
        .accessibilityHint(help ?? "")
    }

    private var value: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text(part.value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(part.value == StatPart.noValue ? Color.inkTertiary : Color.ink)
                    .contentTransition(.numericText())
                if !part.unit.isEmpty {
                    Text(part.unit)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.inkSecondary)
                        .padding(.trailing, index < parts.count - 1 ? 4 : 0)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .animation(Theme.Motion.snappy, value: parts)
    }
}

extension StatTile where Accessory == EmptyView {
    init(label: String, parts: [StatPart], help: String? = nil) {
        self.init(label: label, parts: parts, help: help) { EmptyView() }
    }
}

/// Seven 3 pt bars, oldest first; today in apricot.
private struct Sparkline: View {
    var values: [Int]

    var body: some View {
        let heights = StatFormat.sparkline(values)
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, h in
                Capsule(style: .continuous)
                    .fill(index == heights.count - 1 ? Color.ink : Color.ink.opacity(0.25))
                    .frame(width: 3, height: max(3, 22 * h))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .padding(.bottom, 3)
        .animation(Theme.Motion.expand, value: heights)
        .accessibilityHidden(true)
    }
}

import SwiftUI

/// Greeting, what needs attention, weekly stats and the searchable history.
struct HomePage: View {
    @Environment(HubContext.self) private var hub
    @Environment(HistoryStore.self) private var history
    @Environment(AppSettings.self) private var settings
    @Environment(ModelStore.self) private var models
    @Environment(OpenRouterAccount.self) private var account
    @Environment(PermissionsCenter.self) private var permissions

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var recentlyDeleted: TranscriptEntry?
    @State private var undoToken = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                header
                attention
                StatsRow(stats: history.stats)
                HistorySection(
                    entries: history.entries,
                    query: query,
                    now: hub.now,
                    onDelete: delete,
                    onClearSearch: { query = "" })
            }
            .padding(.horizontal, HubLayout.pageHorizontal)
            .padding(.top, HubLayout.pageTop)
            .padding(.bottom, HubLayout.pageBottom + 20)
            .frame(maxWidth: HubLayout.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) { undoBar }
        .onAppear {
            if query.isEmpty { query = hub.initialSearch }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.everyMinute) { context in
                    Text(HubGreeting.text(for: hub.fixedNow ?? context.date, name: hub.firstName))
                        .typeface(.greeting)
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                }
                hint
            }
            Spacer(minLength: Theme.Spacing.md)
            HubSearchField(text: $query, prompt: "Search transcripts", focused: $searchFocused)
                .frame(width: 220)
                .padding(.top, 4)
                .background {
                    Button("Search") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
        }
    }

    /// "Hold [fn] to dictate anywhere · [fn] [space] for hands-free"; the second half drops in narrow windows.
    private var hint: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                holdHint
                if let handsFree = settings.shortcuts[.handsFree] {
                    Text("·").foregroundStyle(.inkTertiary)
                    ShortcutChips(shortcut: handsFree, size: .small)
                    Text("for hands-free")
                }
            }
            HStack(spacing: 6) { holdHint }
        }
        .typeface(.callout)
        .foregroundStyle(.inkSecondary)
        .lineLimit(1)
    }

    @ViewBuilder private var holdHint: some View {
        Text("Hold")
        ShortcutChips(shortcut: settings.shortcuts[.pushToTalk], size: .small)
        Text("to dictate anywhere")
    }

    // MARK: Attention

    @ViewBuilder private var attention: some View {
        let items = HubAttention.items(.init(
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            accessibilityLikelyStale: permissions.accessibilityLikelyStale,
            fnKeyUsage: permissions.fnKeyUsage,
            pushToTalkUsesFn: settings.shortcuts[.pushToTalk]?.usesFunctionKey ?? false,
            engine: settings.selectedEngine,
            localState: models.state(of: settings.selectedEngine),
            keyStatus: account.status))
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
                .foregroundStyle(Color(nsColor: .hex(0xB3ACFF)))
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
            StatTile(label: "Time saved", parts: StatFormat.timeSaved(stats.timeSavedSeconds),
                     help: "Compared with typing at 40 wpm.")
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
                if help != nil {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.inkTertiary)
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
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1)
        }
        .cardShadow()
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(parts.map { "\($0.value) \($0.unit)" }.joined(separator: " "))
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
                    .fill(index == heights.count - 1 ? Color.warm : Color.accent.opacity(0.35))
                    .frame(width: 3, height: max(3, 22 * h))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .padding(.bottom, 3)
        .animation(Theme.Motion.expand, value: heights)
        .accessibilityHidden(true)
    }
}

import SwiftUI

/// History grouped by relative day, with sticky day headers, search and empty states.
struct HistorySection: View {
    var entries: [TranscriptEntry]
    var query: String
    var now: Date
    var onDelete: (TranscriptEntry) -> Void
    var onClearSearch: () -> Void

    var body: some View {
        let matches = HistoryGrouping.filter(entries, query: query)
        if entries.isEmpty {
            HistoryEmptyState()
        } else if matches.isEmpty {
            NoMatches(query: query, onClear: onClearSearch)
        } else {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md, pinnedViews: [.sectionHeaders]) {
                ForEach(HistoryGrouping.days(matches, now: now)) { day in
                    Section {
                        DayCard(entries: day.entries, onDelete: onDelete)
                    } header: {
                        SectionHeader(day.title) {
                            let words = day.entries.reduce(0) { $0 + $1.wordCount }
                            if words > 0 {
                                Text(Fmt.words(words))
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.inkTertiary)
                            }
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        .frame(maxWidth: .infinity)
                        .background(Color.bgCanvas)
                    }
                }
            }
        }
    }
}

private struct DayCard: View {
    var entries: [TranscriptEntry]
    var onDelete: (TranscriptEntry) -> Void

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    if entry.id != entries.first?.id {
                        RowDivider(inset: 92)
                    }
                    HistoryRow(entry: entry, onDelete: onDelete)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
}

// MARK: - Row

struct HistoryRow: View {
    var entry: TranscriptEntry
    var onDelete: (TranscriptEntry) -> Void
    @Environment(HubContext.self) private var hub
    @State private var hovering = false
    @State private var expanded = false

    private var hasAudio: Bool { entry.audioFileName != nil }
    private var isEmptySuccess: Bool { entry.status == .success && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The engine the recording is being transcribed with right now (Retry, Transcribe Again).
    private var transcribing: EngineID? { hub.transcribingEngine(for: entry.id) }
    private var showsActions: Bool { hovering || hub.previewHoveredEntry == entry.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Fmt.time(entry.createdAt))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.inkSecondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 1)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .background(showsActions ? Color.hover.opacity(0.7) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard entry.status == .success, !isEmptySuccess else { return }
            withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
        }
        .contextMenu { rowMenu }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.expand, value: transcribing)
        .accessibilityElement(children: .contain)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch entry.status {
        case .success where isEmptySuccess:
            Text("No speech detected (\(Fmt.duration(entry.audioDuration)))")
                .font(.system(size: 13))
                .foregroundStyle(.inkTertiary)
        case .success:
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineSpacing(2.5)
                    .foregroundStyle(.ink)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                if let transcribing {
                    TranscribingLine(engine: transcribing)
                        .transition(.opacity)
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // Centered on the cap height of the 13 pt label (≈4.5 pt above its baseline), not sitting on it.
                    Circle().fill(Color.danger).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1.5 }
                    Text("\(Text("Couldn’t transcribe").fontWeight(.medium).foregroundStyle(Color.ink)) · \(failureReason)")
                        .foregroundStyle(Color.inkSecondary)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                inlineRetry(title: "Retry", symbol: "arrow.clockwise")
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 6) {
                Text("Canceled recording (\(Fmt.duration(entry.audioDuration)))")
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.inkSecondary)
                inlineRetry(title: "Transcribe", symbol: "waveform")
            }
        }
    }

    private var failureReason: String {
        if let message = entry.errorMessage, !message.isEmpty {
            return message.hasSuffix(".") ? message : message + "."
        }
        return "\(entry.engine.shortName) ran into a problem."
    }

    @ViewBuilder private func inlineRetry(title: String, symbol: String) -> some View {
        if let transcribing {
            TranscribingLine(engine: transcribing)
                .padding(.vertical, 4)
        } else if hasAudio {
            Menu {
                VersionsMenuItems(entry: entry)
            } label: {
                Label(title, systemImage: symbol)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(QuietButtonStyle(size: .small))
            .fixedSize()
            .padding(.leading, -8)
        } else {
            Text("Recording no longer kept")
                .font(.system(size: 11.5))
                .foregroundStyle(.inkTertiary)
        }
    }

    // MARK: Trailing

    private var trailing: some View {
        ZStack(alignment: .topTrailing) {
            meta
                .padding(.top, 0.5)
                .opacity(showsActions ? 0 : 1)
            actions
                .padding(.top, -4)
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
        }
        .frame(minWidth: 88, alignment: .topTrailing)
    }

    /// Gemini is pinned to one provider, so only cloud Parakeet says who answered.
    private var servedBy: String? {
        guard entry.engine.cloudAPI == .transcriptions, let provider = entry.provider, !provider.isEmpty else { return nil }
        return provider
    }

    private var meta: some View {
        HStack(spacing: 7) {
            if let cost = entry.costUSD, cost > 0 {
                Text(Fmt.usd(cost))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.inkTertiary)
            }
            if let servedBy {
                Text("via \(servedBy)")
                    .font(.system(size: 11))
                    .foregroundStyle(.inkTertiary)
                    .lineLimit(1)
            }
            EngineGlyph(engine: entry.engine, provider: entry.provider)
            Text(Fmt.duration(entry.audioDuration))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.inkTertiary)
                .frame(minWidth: 28, alignment: .trailing)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if entry.status == .success && !isEmptySuccess {
                CopyButton(text: entry.text) { hub.copy($0) }
            }
            if entry.status != .success && hasAudio && transcribing == nil {
                Menu {
                    VersionsMenuItems(entry: entry)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(IconButtonStyle(size: 26))
                .fixedSize()
                .help("Retry with…")
            }
            Menu {
                rowMenu
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(IconButtonStyle(size: 26))
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions")
            Button {
                onDelete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Delete")
            .accessibilityLabel("Delete transcript")
        }
    }

    /// The right-click menu and the hover "…" menu.
    @ViewBuilder private var rowMenu: some View {
        if entry.status == .success && !isEmptySuccess {
            Button("Copy") { hub.copy(entry.text) }
        }
        let menu = hub.versionsMenu(for: entry)
        Menu(menu.title) {
            VersionsMenuItems(entry: entry)
        }
        Divider()
        Button("Delete", role: .destructive) { onDelete(entry) }
    }
}

/// "Transcribing with Gemini Flash…" under a row whose recording is being transcribed.
private struct TranscribingLine: View {
    var engine: EngineID

    var body: some View {
        HStack(spacing: 8) {
            ShimmerBar(height: 3)
                .frame(width: 40)
            Text("Transcribing with \(engine.shortName)…")
                .font(.system(size: 11.5))
                .foregroundStyle(.inkSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row's Versions menu (`VersionsMenu`): the versions it has, the current one checked, then "Transcribe With"
/// the engines (and clean-up) not used on it yet, unavailable ones disabled with the reason. A failed or canceled
/// dictation lists only the engines to retry with.
struct VersionsMenuItems: View {
    var entry: TranscriptEntry
    @Environment(HubContext.self) private var hub

    var body: some View {
        let menu = hub.versionsMenu(for: entry)
        if let running = menu.runningTitle {
            Button(running) {}
                .disabled(true)
        }
        if !menu.versions.isEmpty {
            Section(VersionsMenu.versionsSectionTitle) {
                ForEach(menu.versions) { version in
                    Toggle(isOn: Binding(get: { version.isCurrent },
                                         set: { _ in hub.dictation.showVersion(version.kind, of: entry.id) })) {
                        Text(version.summary.isEmpty ? version.title : "\(version.title) · \(version.summary)")
                    }
                }
            }
        }
        Section(menu.isRetry ? menu.title : VersionsMenu.actionsSectionTitle) {
            ForEach(menu.actions) { action in
                Button(action.title) {
                    hub.dictation.makeVersion(action.kind, of: entry)
                }
                .disabled(!action.isEnabled)
            }
        }
    }
}

// MARK: - Empty states

private struct HistoryEmptyState: View {
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                StageBackground(cornerRadius: 22)
                    .frame(width: 176, height: 84)
                MiniPill(phase: .listening, level: 0.7)
                    .scaleEffect(1.1)
            }
            .padding(.bottom, 4)
            Text("Nothing here yet")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(.ink)
            HStack(spacing: 5) {
                Text("Hold")
                ShortcutChips(shortcut: settings.shortcuts[.pushToTalk], size: .small)
                Text("in any app and start talking.")
            }
            .font(.system(size: 13))
            .foregroundStyle(.inkSecondary)
            Text("Your transcripts will show up here.")
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondary)
                .padding(.top, -8)
            Button("Practice in Onboarding") {
                settings.onboardingStep = OnboardingStepIndex.tryIt
                hub.windows.showOnboarding()
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }
}

/// Onboarding steps the Hub deep-links into, as stored in `settings.onboardingStep`.
enum OnboardingStepIndex {
    static let welcome = OnboardingStep.welcome.rawValue
    static let tryIt = OnboardingStep.tryIt.rawValue
}

private struct NoMatches: View {
    var query: String
    var onClear: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.inkTertiary)
            Text("No transcripts match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondary)
                .multilineTextAlignment(.center)
            Button("Clear Search", action: onClear)
                .buttonStyle(.appQuiet)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

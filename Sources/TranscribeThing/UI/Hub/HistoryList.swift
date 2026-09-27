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
        .background(hovering ? Color.hover.opacity(0.7) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard entry.status == .success, !isEmptySuccess else { return }
            withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
        }
        .contextMenu { contextMenu }
        .animation(Theme.Motion.hover, value: hovering)
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
            Text(entry.text)
                .font(.system(size: 13))
                .lineSpacing(2.5)
                .foregroundStyle(.ink)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
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
        if hasAudio {
            Menu {
                RetryMenuItems(entry: entry)
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
                .opacity(hovering ? 0 : 1)
            actions
                .padding(.top, -4)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
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
            if entry.status != .success && hasAudio {
                Menu {
                    RetryMenuItems(entry: entry)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(IconButtonStyle(size: 26))
                .fixedSize()
                .help("Retry with…")
            }
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

    @ViewBuilder private var contextMenu: some View {
        if entry.status == .success && !isEmptySuccess {
            Button("Copy") { hub.copy(entry.text) }
        }
        if hasAudio {
            Menu(entry.status == .success ? "Transcribe Again With" : "Retry With") {
                RetryMenuItems(entry: entry, includesHeader: false)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { onDelete(entry) }
    }
}

/// "Transcribe with" → every engine, the extra models included (a retry picks the model for that one recording),
/// grouped by where it runs (on this Mac, cloud speech, Gemini); unavailable ones are disabled with the reason.
struct RetryMenuItems: View {
    var entry: TranscriptEntry
    var includesHeader = true
    @Environment(HubContext.self) private var hub

    var body: some View {
        let engines = EngineID.allCases
        let items = ForEach(Array(engines.enumerated()), id: \.element) { index, engine in
            if index > 0, engines[index - 1].cloudAPI != engine.cloudAPI {
                Divider()
            }
            let readiness = hub.readiness(of: engine)
            Button {
                hub.dictation.retry(entry, with: engine)
            } label: {
                if let reason = readiness.unavailableReason {
                    Text("\(engine.displayName) · \(reason)")
                } else {
                    Text(engine.displayName)
                }
            }
            .disabled(!readiness.isUsable)
        }
        if includesHeader {
            Section("Transcribe with") { items }
        } else {
            items
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

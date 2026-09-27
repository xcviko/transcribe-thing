import SwiftUI

/// General › Software Update, after macOS's own pane: where this copy stands (up to date, an update to install,
/// the install's progress), the switch for automatic checks, and every release's notes.
struct SoftwareUpdatePage: View {
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings
    @Environment(UpdateCenter.self) private var updates

    var body: some View {
        @Bindable var settings = settings
        HubPage("Software Update", subtitle: "New versions of \(Brand.name) come from its GitHub releases.",
                back: HubBackLink(title: HubSection.general.title) { hub.show(.general) }) {
            SettingsGroup {
                UpdateStatusRow()
                SettingsRow(title: "Check for updates automatically",
                            subtitle: "Off means no reminders and no badges. You can still check here anytime.",
                            systemImage: "arrow.triangle.2.circlepath", iconTint: .inkSecondary) {
                    Toggle("", isOn: $settings.checkForUpdatesAutomatically)
                        .toggleStyle(.appSwitch)
                        .labelsHidden()
                }
            }
            HubGroup("What’s New") {
                Button {
                    hub.open(Brand.releasesPage)
                } label: {
                    HStack(spacing: 4) {
                        Text("View on GitHub")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(.appQuiet)
                .help(Brand.releasesPage.absoluteString)
            } content: {
                ChangelogList()
            }
        }
        // Opening the page is asking: a check older than a minute runs again, whatever the setting.
        .task {
            guard !hub.isPreview else { return }
            updates.refreshIfStale()
        }
    }
}

// MARK: - Status

/// App icon, what's going on, and the one action that fits: Check Now, Update Now, Cancel, Try Again.
private struct UpdateStatusRow: View {
    @Environment(HubContext.self) private var hub
    @Environment(UpdateCenter.self) private var updates

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .typeface(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
                progress
            }
            Spacer(minLength: Theme.Spacing.md)
            actions
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 14)
        .frame(minHeight: 84)
        .animation(Theme.Motion.snappy, value: updates.install)
        .animation(Theme.Motion.snappy, value: updates.isChecking)
        .accessibilityElement(children: .contain)
    }

    private var current: String { updates.currentVersion?.description ?? "unknown" }

    private var icon: some View {
        AppIconMark(size: 52)
            .overlay(alignment: .bottomTrailing) {
                if let glyph {
                    Image(systemName: glyph.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, glyph.color)
                        .background(Circle().fill(Color.bgSurface).padding(-1.5))
                        .offset(x: 4, y: 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .accessibilityHidden(true)
    }

    private var glyph: (symbol: String, color: Color)? {
        if case .failed = updates.install { return ("exclamationmark.circle.fill", .danger) }
        if case .needsRestart = updates.install { return ("checkmark.circle.fill", .success) }
        if updates.install.isBusy || updates.isChecking { return nil }
        if updates.availableUpdate != nil { return ("arrow.down.circle.fill", .accent) }
        if updates.checkError != nil { return ("exclamationmark.circle.fill", .warning) }
        return updates.lastChecked == nil ? nil : ("checkmark.circle.fill", .success)
    }

    private var title: String {
        switch updates.install {
        case .downloading(let version, _, _): return "Downloading \(Brand.name) \(version)…"
        case .verifying: return "Verifying…"
        case .waitingForDictation: return "Will restart when your dictation finishes"
        case .installing: return "Installing…"
        case .restarting: return "Restarting…"
        case .needsRestart: return "Reopen \(Brand.name) to finish"
        case .failed: return "Couldn’t install the update"
        case .idle: break
        }
        if updates.isChecking { return "Checking for updates…" }
        if updates.availableUpdate != nil { return "Update available" }
        if updates.checkError != nil { return "Couldn’t check for updates" }
        if updates.lastChecked != nil { return "\(Brand.name) is up to date" }
        return "\(Brand.name) \(current)"
    }

    private var detail: String? {
        switch updates.install {
        case .downloading(_, let received, let total):
            return UpdateFormat.progress(received: received, total: total)
        case .verifying(let version):
            return "Making sure \(version) is signed by \(Brand.name)’s developer."
        case .waitingForDictation(let version):
            return "\(Brand.name) \(version) is downloaded and ready."
        case .installing(let version):
            return "\(Brand.name) \(version)"
        case .restarting(let version):
            return "\(Brand.name) \(version) opens in a moment."
        case .needsRestart(let version):
            return "\(Brand.name) \(version) is installed but couldn’t reopen itself. Quit and open it again."
        case .failed(_, let error):
            return error.message
        case .idle:
            break
        }
        if updates.isChecking { return "Version \(current)" }
        if let available = updates.availableUpdate {
            var parts = ["\(Brand.name) \(available.version)"]
            if let size = available.installableAsset?.size, size > 0 { parts.append(Fmt.bytes(size)) }
            if let date = available.publishedAt { parts.append("Released \(UpdateFormat.date(date, now: hub.now))") }
            return parts.joined(separator: " · ")
        }
        if let error = updates.checkError { return error.message }
        if let checked = updates.lastChecked {
            return "Version \(current) · \(UpdateFormat.checkedLine(checked, now: hub.now))"
        }
        return "Check whether a newer version is out."
    }

    @ViewBuilder private var progress: some View {
        switch updates.install {
        case .downloading(_, let received, let total):
            ProgressBar(fraction: total.map { $0 > 0 ? Double(received) / Double($0) : 0 } ?? 0, height: 5)
                .frame(maxWidth: 280)
                .padding(.top, 5)
        case .verifying, .installing, .waitingForDictation:
            ShimmerBar(height: 5)
                .frame(maxWidth: 280)
                .padding(.top, 5)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        switch updates.install {
        case .downloading, .verifying, .waitingForDictation:
            Button("Cancel") { updates.cancelInstall() }
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .installing, .restarting:
            ProgressView()
                .controlSize(.small)
        case .needsRestart:
            Button("Quit \(Brand.name)") { updates.quitToFinishUpdate() }
                .buttonStyle(PrimaryButtonStyle(size: .small))
        case .failed(let version, let error):
            HStack(spacing: 8) {
                let release = updates.releases.first { $0.version == version }
                if error.isRetryable {
                    Button("Download from GitHub") { updates.openReleasePage(release) }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                    Button("Try Again") { updates.installUpdate() }
                        .buttonStyle(PrimaryButtonStyle(size: .small))
                } else {
                    Button("Download from GitHub") { updates.openReleasePage(release) }
                        .buttonStyle(PrimaryButtonStyle(size: .small))
                }
            }
        case .idle:
            if updates.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else if updates.availableUpdate != nil {
                Button("Update Now") { updates.installUpdate() }
                    .buttonStyle(PrimaryButtonStyle(size: .small))
            } else {
                Button("Check Now") { updates.checkNow() }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }
}

// MARK: - Changelog

/// Every release, newest first: newer than this copy highlighted, this copy marked "Installed", and the long
/// tail behind "Show older versions".
private struct ChangelogList: View {
    @Environment(HubContext.self) private var hub
    @Environment(UpdateCenter.self) private var updates
    @State private var showsOlder = false

    /// Newer releases, the installed one and one before it stay open.
    private var visibleCount: Int {
        let releases = updates.releases
        guard let current = updates.currentVersion else { return min(releases.count, 3) }
        let throughInstalled = releases.filter { $0.version >= current }.count
        return min(releases.count, max(3, throughInstalled + 1))
    }

    var body: some View {
        let releases = updates.releases
        if releases.isEmpty {
            emptyState
        } else {
            let shown = showsOlder ? releases : Array(releases.prefix(visibleCount))
            let hidden = releases.count - shown.count
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, release in
                        if index > 0 { RowDivider(inset: 0) }
                        ChangelogEntry(release: release, current: updates.currentVersion, now: hub.now)
                    }
                    if hidden > 0 {
                        RowDivider(inset: 0)
                        Button {
                            withAnimation(Theme.Motion.expand) { showsOlder = true }
                        } label: {
                            HStack(spacing: 5) {
                                Text(hidden == 1 ? "Show 1 older version" : "Show \(hidden) older versions")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(QuietButtonStyle(size: .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
    }

    private var emptyState: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(symbol: "shippingbox", tint: .inkSecondary, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No releases yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.ink)
                    Text(updates.lastChecked == nil ? "Release notes appear here once \(Brand.name) has checked GitHub."
                                                    : "Release notes appear here when the first version is published.")
                        .typeface(.callout)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ChangelogEntry: View {
    var release: Release
    var current: AppVersion?
    var now: Date

    private var isNew: Bool { current.map { release.version > $0 } ?? false }
    private var isInstalled: Bool { current == release.version }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(release.version.description)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.ink)
                if let title = release.title {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
                }
                if isNew {
                    Badge(text: "New", tint: .accent, systemImage: "sparkles")
                } else if isInstalled {
                    Badge(text: "Installed", tint: .success, systemImage: "checkmark")
                }
                Spacer(minLength: 8)
                if let date = release.publishedAt {
                    Text(UpdateFormat.date(date, now: now))
                        .typeface(.callout)
                        .foregroundStyle(.inkTertiary)
                }
            }
            if release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No notes for this release.")
                    .typeface(.callout)
                    .foregroundStyle(.inkTertiary)
            } else {
                ReleaseNotesView(markdown: release.notes)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isNew {
                Color.accentSoft.opacity(0.55)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.accent).frame(width: 3)
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isNew ? "Version \(release.version.description), new" : "Version \(release.version.description)")
    }
}

// MARK: - Release notes

/// GitHub-flavored release notes: headings, (nested) lists, paragraphs, code blocks and rules, with bold,
/// code and clickable links inline.
struct ReleaseNotesView: View {
    var markdown: String

    var body: some View {
        let blocks = ReleaseNotes.blocks(ReleaseNotes.tidy(markdown))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: ReleaseNotesBlock, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(ReleaseNotes.inline(text))
                .font(.system(size: level <= 2 ? 14 : 13, weight: .semibold))
                .foregroundStyle(.ink)
                .padding(.top, isFirst ? 0 : 4)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            NotesText(text: text)
        case .list(let list):
            NotesList(list: list, depth: 0)
        case .code(let code):
            NotesCode(code: code)
        case .rule:
            Rectangle()
                .fill(Color.stroke)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }
}

private struct NotesText: View {
    var text: String

    var body: some View {
        Text(ReleaseNotes.inline(text))
            .typeface(.body)
            .foregroundStyle(.ink.opacity(0.86))
            .tint(.accent)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NotesCode: View {
    var code: String

    var body: some View {
        Text(code)
            .font(Theme.Typeface.mono.font)
            .foregroundStyle(.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(HubPalette.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1)
            }
    }
}

private struct NotesList: View {
    var list: ReleaseNotesList
    var depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    marker(index)
                    VStack(alignment: .leading, spacing: 5) {
                        NotesText(text: item.text)
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            switch child {
                            case .list(let nested): NotesList(list: nested, depth: depth + 1)
                            case .code(let code): NotesCode(code: code)
                            default: EmptyView()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func marker(_ index: Int) -> some View {
        if list.ordered {
            Text("\(list.start + index).")
                .typeface(.body)
                .monospacedDigit()
                .foregroundStyle(.inkTertiary)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            Text(["•", "◦", "▪︎"][min(depth, 2)])
                .typeface(.body)
                .foregroundStyle(.inkTertiary)
                .frame(width: 10, alignment: .center)
        }
    }
}

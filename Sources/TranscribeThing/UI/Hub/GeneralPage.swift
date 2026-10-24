import AppKit
import SwiftUI

/// Software Update, startup, the pill and sounds, how text is pasted, History's Auto-delete, permissions, About, and
/// the logs to send when something breaks.
struct GeneralPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @Environment(PermissionsCenter.self) private var permissions
    @Environment(HistoryStore.self) private var history

    @State private var loginError: String?
    @State private var confirmingClear = false
    /// What the recordings take on disk, once measured.
    @State private var recordingsBytes: Int64?
    /// An Auto-delete period that would delete entries at once, waiting for the user to confirm it.
    @State private var pendingAutoDelete: Int?

    var body: some View {
        @Bindable var settings = settings
        HubPage("General") {
            // As System Settings → General opens: what this app is, then Software Update.
            Section {
                AboutCard()
                SoftwareUpdateRow()
            }
            HubGroup("You", footer: "Home greets you by it, and call transcripts name you with it. Empty: "
                     + "your Mac account’s name.") {
                SettingsGroup {
                    SettingsRow(title: "Your name", systemImage: "person.crop.circle", iconTint: .inkSecondary) {
                        TextField("Your name", text: $settings.userName, prompt: Text(AppSettings.macFirstName ?? "Name"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 220)
                    }
                }
            }
            HubGroup("Startup") {
                SettingsGroup {
                    SettingsRow(title: "Open \(Brand.name) at login", subtitle: loginSubtitle, systemImage: "power",
                                iconTint: .inkSecondary) {
                        HStack(spacing: 10) {
                            if launchAtLogin.requiresApproval {
                                Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                                    .buttonStyle(.appQuiet)
                            }
                            Toggle("", isOn: openAtLogin)
                                .toggleStyle(.appSwitch)
                                .labelsHidden()
                        }
                    }
                    SettingsRow(title: "Show \(Brand.name) in the Dock", systemImage: "dock.rectangle",
                                iconTint: .inkSecondary) {
                        Toggle("", isOn: showInDock)
                            .toggleStyle(.appSwitch)
                            .labelsHidden()
                    }
                }
            }
            HubGroup("Pill & Sounds") {
                SettingsGroup {
                    pillRow
                    SettingsRow(title: "Hints above the pill",
                                subtitle: "The model’s name when you switch, and tips about the keys.",
                                systemImage: "text.bubble", iconTint: .inkSecondary) {
                        Toggle("", isOn: $settings.showsPillHints)
                            .toggleStyle(.appSwitch)
                            .labelsHidden()
                    }
                    SettingsRow(title: "Play sounds", systemImage: settings.soundsEnabled ? "speaker.wave.2" : "speaker.slash",
                                iconTint: .inkSecondary) {
                        Toggle("", isOn: playSounds)
                            .toggleStyle(.appSwitch)
                            .labelsHidden()
                    }
                }
            }
            HubGroup("Pasting", footer: "A rule applies when both the model and the way you dictated are checked.") {
                PastingRules()
            }
            HubGroup("Translate", footer: "On Gemini, Translate writes your dictation in the other language; with text "
                        + "selected, it translates that. Any other language comes out in the second one.") {
                SettingsGroup {
                    SettingsRow(title: "Translate between", systemImage: "translate", iconTint: .inkSecondary) {
                        HStack(spacing: 8) {
                            HubMenuPicker(title: "First language", options: TranslationLanguage.allCases,
                                          selection: language(\.first), label: \.name)
                            Text("and")
                                .typeface(.callout)
                                .foregroundStyle(.inkSecondary)
                            HubMenuPicker(title: "Second language", options: TranslationLanguage.allCases,
                                          selection: language(\.second), label: \.name)
                        }
                    }
                }
            }
            CallsSettingsGroup()
            BrowserExtensionGroup()
            HubGroup("History") {
                SettingsGroup {
                    SettingsRow(title: "Auto-delete history", systemImage: "clock.arrow.circlepath",
                                iconTint: .inkSecondary) {
                        HubMenuPicker(title: "Auto-delete history", options: AutoDeleteChoice.days,
                                      selection: autoDeleteDays, label: AutoDeleteChoice.label)
                    }
                    SettingsRow(title: "Clear history", subtitle: clearSubtitle,
                                systemImage: "trash", iconTint: .danger) {
                        Button("Delete All…") { confirmingClear = true }
                            .buttonStyle(SecondaryButtonStyle(size: .small, isDestructive: true))
                            .disabled(history.entries.isEmpty)
                    }
                }
            }
            HubGroup("Permissions") {
                SettingsGroup {
                    PermissionRow(title: "Microphone", symbol: "mic.fill", state: permissions.microphone) {
                        if permissions.microphone == .notDetermined {
                            let permissions = permissions
                            Task { _ = await permissions.requestMicrophone() }
                        } else {
                            permissions.open(.microphone)
                        }
                    }
                    PermissionRow(title: "Accessibility", subtitle: accessibilitySubtitle,
                                  symbol: "accessibility", state: permissions.accessibility) {
                        if permissions.accessibility == .granted || permissions.accessibilityLikelyStale {
                            permissions.open(.accessibility)
                        } else {
                            permissions.requestAccessibility()
                        }
                    }
                }
            }
            HubGroup("Troubleshooting") {
                SettingsGroup {
                    LogsRow()
                }
            }
            HubGroup("Experimental") {
                SettingsGroup {
                    RaceRequestsRow()
                }
            }
        }
        // Approval in Login Items (or removal there) happens outside transcribe-thing.
        .onAppear { launchAtLogin.refresh() }
        .task(id: [history.entries.count, history.compressedRecordings]) {
            recordingsBytes = await history.recordingsByteCount()
        }
        .confirmationDialog("Delete all transcripts and recordings?", isPresented: $confirmingClear) {
            Button("Delete Everything", role: .destructive) {
                withAnimation(Theme.Motion.collapse) { history.clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog(autoDeleteQuestion, isPresented: confirmingAutoDelete) {
            Button("Delete", role: .destructive) {
                guard let days = pendingAutoDelete else { return }
                pendingAutoDelete = nil
                withAnimation(Theme.Motion.collapse) { settings.autoDeleteHistoryDays = days }
            }
            Button("Cancel", role: .cancel) { pendingAutoDelete = nil }
        } message: {
            Text("Their recordings go too. This can’t be undone.")
        }
    }

    /// One language of Translate's pair. Picking the one the other side has swaps them, so the two always differ.
    private func language(_ side: WritableKeyPath<TranslationPair, TranslationLanguage>) -> Binding<TranslationLanguage> {
        let settings = settings
        return Binding(get: { settings.translationPair[keyPath: side] }, set: { language in
            var pair = settings.translationPair
            let other: WritableKeyPath<TranslationPair, TranslationLanguage> = side == \.first ? \.second : \.first
            if pair[keyPath: other] == language { pair[keyPath: other] = pair[keyPath: side] }
            pair[keyPath: side] = language
            settings.translationPair = pair
        })
    }

    /// Auto-delete's period. One that deletes transcripts right away asks first (as Delete All does); a longer one,
    /// or Never, takes effect at once.
    private var autoDeleteDays: Binding<Int> {
        let settings = settings, history = history
        return Binding(get: { settings.autoDeleteHistoryDays }, set: { days in
            let expired = history.expiredEntries(afterDays: days).count
            if AutoDeleteChoice.confirmation(count: expired, days: days) != nil {
                pendingAutoDelete = days
            } else {
                settings.autoDeleteHistoryDays = days
            }
        })
    }

    private var autoDeleteQuestion: String {
        pendingAutoDelete.flatMap { days in
            AutoDeleteChoice.confirmation(count: history.expiredEntries(afterDays: days).count, days: days)
        } ?? "Delete older transcripts?"
    }

    private var confirmingAutoDelete: Binding<Bool> {
        Binding(get: { pendingAutoDelete != nil }, set: { if !$0 { pendingAutoDelete = nil } })
    }

    /// "Deletes 1,204 transcripts and their recordings (2.3 GB).", the size once it's known.
    /// "10 transcripts · 12 MB".
    private var clearSubtitle: String {
        guard !history.entries.isEmpty else { return "Empty" }
        let size = recordingsBytes.flatMap { $0 > 0 ? " · \(Fmt.bytes($0))" : nil } ?? ""
        return "\(Fmt.number(history.entries.count)) transcripts\(size)"
    }

    private var pillRow: some View {
        SettingsRow(title: "Show the pill", systemImage: "capsule", iconTint: .inkSecondary) {
            HubSegmentedPicker(title: "Show the pill", options: PillMode.allCases, selection: settings.pillMode,
                               label: \.title) { mode in
                settings.pillMode = mode
            }
        }
    }

    private var playSounds: Binding<Bool> {
        Binding(get: { settings.soundsEnabled }, set: { on in
            settings.soundsEnabled = on
            // Turning sounds on plays one, so you hear what you chose.
            if on, !hub.isPreview { hub.sounds.play(.start) }
        })
    }

    private var openAtLogin: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled }, set: { on in
            do {
                try launchAtLogin.set(on)
                loginError = nil
            } catch {
                loginError = error.localizedDescription
            }
        })
    }

    private var showInDock: Binding<Bool> {
        // The Hub itself keeps the Dock icon while it is open; the coordinator applies this when it closes.
        Binding(get: { settings.showDockIcon }, set: { settings.showDockIcon = $0 })
    }

    /// Only what needs doing: an error, or the approval macOS waits for.
    private var loginSubtitle: String? {
        if let loginError { return loginError }
        if launchAtLogin.requiresApproval { return "Waiting for your approval in Login Items." }
        return nil
    }

    private var accessibilitySubtitle: String? {
        if permissions.accessibility != .granted && permissions.accessibilityLikelyStale {
            return "\(Brand.name) was updated. Remove it from the list, then add it back."
        }
        return nil
    }
}

/// Opens General › Software Update, like the row in System Settings: what's new at a glance, a red badge while
/// an update waits (with reminders on), and a chevron.
private struct SoftwareUpdateRow: View {
    @Environment(HubContext.self) private var hub
    @Environment(UpdateCenter.self) private var updates

    /// A row that opens a pane, as System Settings' do: the whole row and its chevron. Not a Button around the row,
    /// which a form draws as a control of its own.
    var body: some View {
        SettingsRow(title: "Software Update", subtitle: UpdateFormat.summary(updates, now: hub.now),
                    systemImage: HubSection.softwareUpdate.symbolName,
                    iconTint: updates.showsBadge ? .accent : .inkSecondary) {
            HStack(spacing: 8) {
                if updates.showsBadge {
                    CountBadge(count: 1)
                }
                Button {
                    hub.show(.softwareUpdate)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open Software Update")
            }
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { hub.show(.softwareUpdate) }
        }
    }
}

/// Export Logs…: what the app did over the last days (`DiagnosticLog`), in one file on the Desktop, shown in Finder,
/// for the user to send when something breaks. A failure says why in a notice.
private struct LogsRow: View {
    @Environment(HubContext.self) private var hub
    @State private var isExporting = false

    var body: some View {
        SettingsRow(title: "Logs", subtitle: "Your dictations, selected text and key are never in them.",
                    systemImage: "doc.text.magnifyingglass", iconTint: .inkSecondary) {
            Button("Export Logs…", action: export)
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .disabled(isExporting)
        }
    }

    private func export() {
        guard !hub.isPreview, !isExporting else { return }
        isExporting = true
        let hub = hub
        Task {
            defer { isExporting = false }
            do {
                let url = try await hub.diagnostics.exportLogs()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                hub.toasts.post(Self.failureNotice(error))
            }
        }
    }

    /// The Desktop needs the user's yes the first time (Files & Folders); anything else says what went wrong.
    static func failureNotice(_ error: Error) -> Notice {
        let ns = error as NSError
        let denied = ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError
        return Notice(dedupeKey: "logs.export", style: .error, symbol: "exclamationmark.triangle.fill",
                      title: "Couldn’t save the logs",
                      body: denied
                          ? "Allow \(Brand.name) to use your Desktop in System Settings › Privacy & Security › "
                              + "Files & Folders, then try again."
                          : error.localizedDescription,
                      lifetime: .seconds(10), sound: .error)
    }
}

private struct PermissionRow: View {
    var title: String
    var subtitle: String?
    var symbol: String
    var state: PermissionState
    var action: () -> Void

    /// Icon and status share one tone. Off is red, like Home's attention card for the same problem.
    private var tone: Color {
        switch state {
        case .granted: .success
        case .denied: .danger
        case .notDetermined: .warning
        }
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, systemImage: symbol,
                    iconTint: tone) {
            HStack(spacing: 10) {
                switch state {
                case .granted:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Allowed")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.success)
                    Button("Open Settings", action: action)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                case .denied:
                    Text("Off")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tone)
                    Button("Open Settings", action: action)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                case .notDetermined:
                    Text("Not set up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tone)
                    Button("Allow", action: action)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                }
            }
        }
    }
}

private struct AboutCard: View {
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                AppIconMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Brand.name)
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(.ink)
                    Text(hub.versionLine.replacingOccurrences(of: "\(Brand.name) ", with: "Version "))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.inkSecondary)
                }
                Spacer(minLength: 8)
                Button {
                    settings.onboardingStep = OnboardingStepIndex.welcome
                    hub.windows.showOnboarding()
                } label: {
                    Label("Replay Onboarding", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }
}

/// General → Pasting as a table: a rule a row, a column for each model and each way of dictating, a checkbox where
/// they cross. A rule applies to text from a checked model dictated a checked way.
private struct PastingRules: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let order = settings.lineup.order
        Grid(alignment: .center, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(order) { choice in
                    columnHeader(choice.shortName, symbol: choice.symbolName)
                        .help(choice.title)
                }
                ForEach(Array(DictationMachine.Mode.allCases.enumerated()), id: \.element) { index, mode in
                    columnHeader(mode.chipTitle, symbol: mode.action.symbolName)
                        .padding(.leading, index == 0 ? Self.groupGap : 0)
                        .help(mode.action.title)
                }
            }
            rule("Add a space after the text", symbol: "space", order: order,
                 models: $settings.modelsAddingSpace, modes: $settings.modesAddingSpace)
            rule("Remove the final period", symbol: "delete.backward", order: order,
                 models: $settings.modelsRemovingFinalPeriod, modes: $settings.modesRemovingFinalPeriod)
        }
        .padding(.vertical, 2)
    }

    /// Between the models' columns and the ways of dictating.
    private static let groupGap: CGFloat = 14

    private func columnHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func rule(_ title: String, symbol: String, order: [ModelChoice], models: Binding<Set<ModelChoice>>,
                      modes: Binding<Set<DictationMachine.Mode>>) -> some View {
        GridRow {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.inkSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.inkSecondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                // Three models' columns leave a narrow window little room: the rule wraps rather than cut off.
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 110, alignment: .leading)
                Spacer(minLength: 0)
            }
            .gridColumnAlignment(.leading)
            ForEach(order) { choice in
                check(models, choice, label: "\(choice.shortName): \(title)")
            }
            ForEach(Array(DictationMachine.Mode.allCases.enumerated()), id: \.element) { index, mode in
                check(modes, mode, label: "\(mode.chipTitle): \(title)")
                    .padding(.leading, index == 0 ? Self.groupGap : 0)
            }
        }
    }

    private func check<Value: Hashable>(_ set: Binding<Set<Value>>, _ value: Value, label: String) -> some View {
        Toggle(label, isOn: Binding(get: { set.wrappedValue.contains(value) }, set: { on in
            if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
        }))
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
}

/// General → Calls: whether calls are noticed (and asked about), where, and the permission their other side needs.
struct CallsSettingsGroup: View {
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        HubGroup("Calls", footer: CallsCopy.settingsFooter) {
            SettingsGroup {
                SettingsRow(title: "Record calls", subtitle: modeSubtitle, systemImage: "phone",
                            iconTint: .inkSecondary) {
                    HubMenuPicker(title: "Record calls", options: CallRecordingMode.pickerOrder,
                                  selection: $settings.callRecording, label: \.title)
                }
                SettingsRow(title: "Show call notices",
                            subtitle: "A brief note above the pill when a call is noticed, when you mute or unmute, "
                                + "and when it ends.",
                            systemImage: "text.bubble", iconTint: .inkSecondary) {
                    Toggle("", isOn: $settings.showsCallNotices)
                        .toggleStyle(.appSwitch)
                        .labelsHidden()
                }
                SettingsRow(title: "System Audio Recording",
                            subtitle: systemAudioSubtitle,
                            systemImage: "speaker.wave.2", iconTint: .inkSecondary) {
                    Button("Open Settings") { hub.openSettings(.systemAudio) }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                }
                SettingsRow(title: "Never recorded", subtitle: CallsCopy.exclusionsSubtitle(empty: settings.callExclusions.isEmpty),
                            systemImage: "nosign", iconTint: .inkSecondary)
                ForEach(settings.callExclusions) { exclusion in
                    CallExclusionRow(exclusion: exclusion) { settings.removeCallExclusion(exclusion) }
                }
            }
        }
    }

    /// What macOS says about recording other apps' sound, read as the page draws.
    private var systemAudioSubtitle: String {
        switch SystemAudioPermission.current() {
        case .authorized: "Allowed: the app records the other side of a call."
        case .denied: "Not allowed: the other side of a call comes out silent. Turn it on in Privacy & Security."
        case .unknown: "Lets the app record the other side of a call. macOS asks the first time a call is recorded."
        }
    }

    private var modeSubtitle: String {
        switch settings.callRecording {
        case .off: "Only Start Call Recording in the menu bar records."
        case .ask: "A call is recorded, and you’re asked whether to transcribe it."
        case .automatic: "Every call is recorded and transcribed."
        }
    }
}

/// One app or site under Never recorded: its icon, its name, what it is, and − to notice its calls again.
private struct CallExclusionRow: View {
    var exclusion: CallExclusion
    var onRemove: () -> Void
    @Environment(\.inNativeForm) private var inNativeForm

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(exclusion.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(exclusion.kindTitle)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: Theme.Spacing.md)
            Button(action: onRemove) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Color.inkSecondary.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.inkSecondary)
            .help("Notice calls in \(exclusion.name) again")
            .accessibilityLabel("Remove \(exclusion.name)")
        }
        .padding(.horizontal, inNativeForm ? 0 : Theme.Spacing.md)
        .padding(.vertical, inNativeForm ? 2 : Theme.Spacing.sm)
        .frame(minHeight: inNativeForm ? 0 : 48)
    }

    @ViewBuilder
    private var icon: some View {
        if exclusion.kind == .app, let image = CallAppIcons.image(for: exclusion.key) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            IconTile(symbol: exclusion.kind == .app ? "app.dashed" : "globe", tint: .inkSecondary)
        }
    }
}

/// General → Experimental → Race requests: each Gemini dictation sent once (Off), or 2 or 3 times at once with the
/// first answer pasted (`RaceRequests`).
private struct RaceRequestsRow: View {
    @Environment(AppSettings.self) private var settings

    static let help = "Sends each Gemini dictation 2 or 3 times at once and pastes whichever answer comes first, "
        + "stopping the rest. Helps when Gemini stalls thinking on one of them. A dictation can cost up to 2 or 3 "
        + "times as much. Only dictations on Gemini."

    var body: some View {
        SettingsRow(title: "Race requests", systemImage: "arrow.triangle.branch", iconTint: .inkSecondary) {
            HStack(spacing: 10) {
                InfoHint(text: Self.help)
                HubSegmentedPicker(title: "Race requests", options: RaceRequests.allCases,
                                   selection: settings.raceRequests, label: \.title) { settings.raceRequests = $0 }
            }
        }
    }
}

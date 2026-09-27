import SwiftUI

/// Software Update, startup, the pill and sounds, recording limits, history retention, permissions and About.
struct GeneralPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @Environment(PermissionsCenter.self) private var permissions
    @Environment(HistoryStore.self) private var history

    @State private var loginError: String?
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var settings = settings
        HubPage("General", subtitle: "Updates, startup, pill and sounds, recording, history and permissions.") {
            HubGroup("Updates") {
                SettingsGroup {
                    SoftwareUpdateRow()
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
                    SettingsRow(title: "Show \(Brand.name) in the Dock",
                                subtitle: "\(Brand.name) always stays in the menu bar.",
                                systemImage: "dock.rectangle", iconTint: .inkSecondary) {
                        Toggle("", isOn: showInDock)
                            .toggleStyle(.appSwitch)
                            .labelsHidden()
                    }
                }
            }
            HubGroup("Pill & Sounds") {
                SettingsGroup {
                    pillRow
                    SettingsRow(title: "Play sounds", subtitle: "Soft clicks when recording starts, stops and pastes.",
                                systemImage: settings.soundsEnabled ? "speaker.wave.2" : "speaker.slash",
                                iconTint: .inkSecondary) {
                        Toggle("", isOn: playSounds)
                            .toggleStyle(.appSwitch)
                            .labelsHidden()
                    }
                }
            }
            HubGroup("Recording") {
                SettingsGroup {
                    SettingsRow(title: "Maximum recording length",
                                subtitle: "\(Brand.name) warns you a minute before, then transcribes. Gemini stops at 7 min.",
                                systemImage: "timer", iconTint: .inkSecondary) {
                        HubMenuPicker(options: AppSettings.maxRecordingChoices, selection: $settings.maxRecordingMinutes) {
                            "\($0) min"
                        }
                    }
                    SettingsRow(title: "Restore the clipboard after pasting",
                                subtitle: "Puts back what you had copied. Turn off to keep the transcript on the clipboard.",
                                systemImage: "doc.on.clipboard", iconTint: .inkSecondary) {
                        Toggle("", isOn: $settings.restoreClipboard)
                            .toggleStyle(.appSwitch)
                            .labelsHidden()
                    }
                }
            }
            HubGroup("History") {
                SettingsGroup {
                    SettingsRow(title: "Keep failed recordings",
                                subtitle: "Audio of dictations that fail or are canceled, so you can retry them.",
                                systemImage: "waveform.badge.exclamationmark", iconTint: .inkSecondary) {
                        HubMenuPicker(options: RetentionChoice.days, selection: $settings.keepFailedRecordingsDays,
                                      label: RetentionChoice.label)
                    }
                    SettingsRow(title: "Keep audio to transcribe again",
                                subtitle: "Send a recent dictation to another model from History. Audio stays on this Mac.",
                                systemImage: "arrow.triangle.2.circlepath", iconTint: .inkSecondary) {
                        HubMenuPicker(options: RetentionChoice.transcribeAgainDays,
                                      selection: $settings.keepSuccessfulRecordingsDays,
                                      label: RetentionChoice.transcribeAgainLabel)
                    }
                    SettingsRow(title: "Clear history",
                                subtitle: history.entries.isEmpty
                                    ? "History is empty."
                                    : "Deletes \(Fmt.number(history.entries.count)) transcripts and their recordings.",
                                systemImage: "trash", iconTint: .danger) {
                        Button("Delete All…") { confirmingClear = true }
                            .buttonStyle(SecondaryButtonStyle(size: .small, isDestructive: true))
                            .disabled(history.entries.isEmpty)
                    }
                }
            }
            HubGroup("Permissions") {
                SettingsGroup {
                    PermissionRow(title: "Microphone", subtitle: "Hears you while you hold the key.",
                                  symbol: "mic.fill", state: permissions.microphone) {
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
            HubGroup("About") {
                AboutCard()
            }
        }
        // Approval in Login Items (or removal there) happens outside transcribe-thing.
        .onAppear { launchAtLogin.refresh() }
        .confirmationDialog("Delete all transcripts and recordings?", isPresented: $confirmingClear) {
            Button("Delete Everything", role: .destructive) {
                withAnimation(Theme.Motion.collapse) { history.clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var pillRow: some View {
        SettingsRow(title: "Show the pill", subtitle: PillCaption.text(settings.pillMode),
                    systemImage: "capsule", iconTint: .inkSecondary) {
            HubSegmentedPicker(options: PillMode.allCases, selection: settings.pillMode, label: \.title) { mode in
                settings.pillMode = mode
            }
            .accessibilityLabel("Show the pill")
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

    private var loginSubtitle: String {
        if let loginError { return loginError }
        if launchAtLogin.requiresApproval { return "Waiting for your approval in Login Items." }
        return "Start quietly in the menu bar when you log in."
    }

    private var accessibilitySubtitle: String {
        if permissions.accessibility != .granted && permissions.accessibilityLikelyStale {
            return "\(Brand.name) was updated. Remove it from the list, then add it back."
        }
        return "Pastes text into other apps and listens for your shortcut."
    }
}

/// Opens General › Software Update, like the row in System Settings: what's new at a glance, a red badge while
/// an update waits (with reminders on), and a chevron.
private struct SoftwareUpdateRow: View {
    @Environment(HubContext.self) private var hub
    @Environment(UpdateCenter.self) private var updates
    @State private var hovering = false

    var body: some View {
        Button {
            hub.show(.softwareUpdate)
        } label: {
            SettingsRow(title: "Software Update", subtitle: UpdateFormat.summary(updates, now: hub.now),
                        systemImage: HubSection.softwareUpdate.symbolName,
                        iconTint: updates.showsBadge ? .accent : .inkSecondary) {
                HStack(spacing: 8) {
                    if updates.showsBadge {
                        CountBadge(count: 1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.inkTertiary)
                }
            }
            .background { RowHighlight(isSelected: false, isHovering: hovering) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Software Update, \(UpdateFormat.summary(updates, now: hub.now))")
    }
}

private struct PermissionRow: View {
    var title: String
    var subtitle: String
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
                    Text("Speak, and it types. Transcription only, no rewriting.")
                        .typeface(.callout)
                        .foregroundStyle(.inkTertiary)
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

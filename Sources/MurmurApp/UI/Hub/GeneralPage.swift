import SwiftUI

/// Startup, recording limits, history retention, permissions and About.
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
        HubPage("General", subtitle: "Startup, recording, history and permissions.") {
            HubGroup("Startup") {
                SettingsGroup {
                    SettingsRow(title: "Open Murmur at login", subtitle: loginSubtitle, systemImage: "power",
                                iconTint: .inkSecondary) {
                        HStack(spacing: 10) {
                            if launchAtLogin.requiresApproval {
                                Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                                    .buttonStyle(.murmurQuiet)
                            }
                            Toggle("", isOn: openAtLogin)
                                .toggleStyle(.murmurSwitch)
                                .labelsHidden()
                        }
                    }
                    SettingsRow(title: "Show Murmur in the Dock",
                                subtitle: "Murmur always stays in the menu bar.",
                                systemImage: "dock.rectangle", iconTint: .inkSecondary) {
                        Toggle("", isOn: showInDock)
                            .toggleStyle(.murmurSwitch)
                            .labelsHidden()
                    }
                }
            }
            HubGroup("Recording") {
                SettingsGroup {
                    SettingsRow(title: "Maximum recording length",
                                subtitle: "Murmur warns you a minute before, then transcribes what you have.",
                                systemImage: "timer", iconTint: .inkSecondary) {
                        HubMenuPicker(options: AppSettings.maxRecordingChoices, selection: $settings.maxRecordingMinutes) {
                            "\($0) min"
                        }
                    }
                    SettingsRow(title: "Restore the clipboard after pasting",
                                subtitle: "Puts back what you had copied. Turn off to keep the transcript on the clipboard.",
                                systemImage: "doc.on.clipboard", iconTint: .inkSecondary) {
                        Toggle("", isOn: $settings.restoreClipboard)
                            .toggleStyle(.murmurSwitch)
                            .labelsHidden()
                    }
                }
            }
            HubGroup("History") {
                SettingsGroup {
                    SettingsRow(title: "Keep failed recordings",
                                subtitle: "Audio is saved only when a dictation fails or is canceled, so you can retry it.",
                                systemImage: "waveform.badge.exclamationmark", iconTint: .inkSecondary) {
                        HubMenuPicker(options: RetentionChoice.days, selection: $settings.keepFailedRecordingsDays,
                                      label: RetentionChoice.label)
                    }
                    SettingsRow(title: "Clear history",
                                subtitle: history.entries.isEmpty
                                    ? "History is empty."
                                    : "Deletes \(Fmt.number(history.entries.count)) transcripts and their recordings.",
                                systemImage: "trash", iconTint: .danger) {
                        Button("Clear History…") { confirmingClear = true }
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
        .confirmationDialog("Delete all transcripts and recordings?", isPresented: $confirmingClear) {
            Button("Delete Everything", role: .destructive) {
                withAnimation(Theme.Motion.collapse) { history.clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
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
            return "Murmur was updated. Remove it from the list, then add it back."
        }
        return "Pastes text into other apps and listens for your shortcut."
    }
}

private struct PermissionRow: View {
    var title: String
    var subtitle: String
    var symbol: String
    var state: PermissionState
    var action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, systemImage: symbol,
                    iconTint: state == .granted ? .success : .warning) {
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
                        .buttonStyle(QuietButtonStyle(tint: .inkSecondary))
                case .denied:
                    Text("Off")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.danger)
                    Button("Open Settings", action: action)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                case .notDetermined:
                    Text("Not set up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.warning)
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
                    Text("Murmur")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(.ink)
                    Text(hub.versionLine.replacingOccurrences(of: "Murmur ", with: "Version "))
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
                    Label("Replay onboarding", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }
}

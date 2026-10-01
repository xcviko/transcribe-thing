import SwiftUI

/// Rebindable shortcuts, the double-press toggle and a Secure Input note.
struct ShortcutsPage: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SecureInputMonitor.self) private var secureInput

    var body: some View {
        @Bindable var settings = settings
        HubPage("Shortcuts", subtitle: "Hold, tap or combine. Works everywhere, even in full-screen apps.") {
            // Offered only when there is something to restore; a dimmed label here read as stray text.
            if settings.shortcuts != .defaults {
                Button("Restore Defaults") {
                    withAnimation(Theme.Motion.snappy) { settings.shortcuts = .defaults }
                }
                .buttonStyle(QuietButtonStyle())
                .padding(.trailing, -8)
                .transition(.opacity)
            }
        } content: {
            if secureInput.isActive {
                Callout(.warning, symbol: "lock.fill", text: secureInputText)
                    .transition(.opacity)
            }
            HubGroup("Dictation") {
                SettingsGroup {
                    row(.pushToTalk)
                    row(.handsFree)
                    SettingsRow(title: "Double-press to go hands-free",
                                subtitle: doublePressSubtitle,
                                systemImage: "hand.tap",
                                iconTint: .inkSecondary) {
                        Toggle("", isOn: $settings.doublePressForHandsFree)
                            .toggleStyle(.appSwitch)
                            .labelsHidden()
                    }
                    row(.switchModel)
                    row(.polish)
                }
            }
            HubGroup("Transcripts") {
                SettingsGroup {
                    row(.pasteLast)
                }
            }
        }
        .animation(Theme.Motion.fade, value: secureInput.isActive)
    }

    private func row(_ action: ShortcutAction) -> some View {
        SettingsRow(title: action.title, subtitle: action.subtitle(in: settings.shortcuts), systemImage: action.symbolName) {
            ShortcutRecorderView(shortcut: binding(for: action), action: action)
        }
    }

    private func binding(for action: ShortcutAction) -> Binding<Shortcut?> {
        Binding(get: { settings.shortcuts[action] }, set: { settings.shortcuts[action] = $0 })
    }

    private var doublePressSubtitle: String {
        let key = settings.shortcuts[.pushToTalk]?.compactDescription ?? "the push-to-talk key"
        return "Press \(key) twice quickly to start. Press it again to finish."
    }

    private var secureInputText: String {
        let app = secureInput.owningAppName.map { "in \($0)" } ?? "on this Mac"
        return "Secure typing is on \(app). Only hold-to-talk works until it’s off."
    }
}

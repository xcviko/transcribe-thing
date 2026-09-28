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
                    row(.cancel)
                    row(.switchModel)
                }
            }
            HubGroup("Transcripts") {
                SettingsGroup {
                    row(.pasteLast)
                }
            }
            HubGroup("Good to know") {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        tip(symbol: "arrow.up.and.down.and.arrow.left.and.right",
                            text: tipLockWhileHolding)
                        tip(symbol: "arrow.uturn.backward", text: "Canceled by accident? Undo in the notice brings the recording back.")
                        tip(symbol: "escape", text: cancelTip)
                        tip(symbol: "sparkles", text: switchModelTip)
                    }
                }
            }
        }
        .animation(Theme.Motion.fade, value: secureInput.isActive)
    }

    private func row(_ action: ShortcutAction) -> some View {
        SettingsRow(title: action.title, subtitle: action.subtitle, systemImage: action.symbolName) {
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

    private var tipLockWhileHolding: String {
        guard let ptt = settings.shortcuts[.pushToTalk]?.compactDescription,
              let handsFree = settings.shortcuts[.handsFree]?.compactDescription else {
            return "Start with push to talk and switch to hands-free without letting go."
        }
        return "Holding \(ptt) and want to keep going? Press \(handsFree) to lock hands-free without letting go."
    }

    private var cancelTip: String {
        let key = settings.shortcuts[.cancel]?.compactDescription ?? "The cancel key"
        return "\(key) only cancels while \(Brand.name) is recording. The rest of the time it works as usual."
    }

    private var switchModelTip: String {
        let key = settings.shortcuts[.switchModel]?.compactDescription ?? "Switch model"
        guard !settings.switchChoices.isEmpty else {
            return "Turn on clean-up or an extra model in Models to switch to it with \(key) while you dictate."
        }
        return "\(key) steps through clean-up and your extra models while you dictate. The next dictation starts on "
            + "\(settings.selectedEngine.shortName) again."
    }

    private var secureInputText: String {
        let app = secureInput.owningAppName.map { "in \($0)" } ?? "on this Mac"
        return "Secure typing is on \(app). Only hold-to-talk works until it’s off."
    }

    private func tip(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.accent)
                .frame(width: 16)
            Text(text)
                .typeface(.callout)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

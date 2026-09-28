import AppKit
import SwiftUI

/// The OpenRouter key: masked key with Replace/Remove, or a field to add one; live status; fixed routing facts.
struct OpenRouterKeyCard: View {
    /// Incremented by the page to scroll here and focus the field ("Add key", "Update key").
    var focusRequest: Int

    @Environment(HubContext.self) private var hub
    @Environment(OpenRouterAccount.self) private var account
    @Environment(AppSettings.self) private var settings
    @State private var replacing = false
    @State private var draft = ""
    @State private var saving = false
    @FocusState private var fieldFocused: Bool

    private var showsField: Bool { account.maskedKey == nil || replacing }
    private var draftTrimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draftLooksValid: Bool { draftTrimmed.hasPrefix("sk-or-") && draftTrimmed.count > 12 }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                header
                if showsField { field } else { storedKey }
                statusLine
                RowDivider(inset: 0)
                routing
            }
        }
        .onChange(of: focusRequest) {
            if account.maskedKey != nil, isProblem { replacing = true }
            fieldFocused = true
        }
    }

    private var isProblem: Bool {
        switch account.status {
        case .invalid, .noCredit: true
        default: false
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "key.fill", tint: HubPalette.apricotInk, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenRouter key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                Text("Cloud models run on your own OpenRouter account. You pay OpenRouter per use.")
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                hub.open(OpenRouterLinks.keys)
            } label: {
                HStack(spacing: 3) {
                    Text("Get a Key")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(.appQuiet)
        }
    }

    private var storedKey: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.inkTertiary)
                Text(account.maskedKey ?? "")
                    .typeface(.mono)
                    .foregroundStyle(.ink)
                    .textSelection(.disabled)
                Spacer(minLength: 0)
                Text("Keychain")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.inkTertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(HubPalette.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1)
            }
            Button("Replace") {
                replacing = true
                fieldFocused = true
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
            Button("Remove") {
                withAnimation(Theme.Motion.snappy) { account.removeKey() }
            }
            .buttonStyle(SecondaryButtonStyle(size: .small, isDestructive: true))
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField("", text: $draft)
                    .textFieldStyle(.plain)
                    .fieldPlaceholder("sk-or-v1-…", isShown: draft.isEmpty)
                    .typeface(.mono)
                    .foregroundStyle(.ink)
                    .focused($fieldFocused)
                    .onSubmit(save)
                    .accessibilityLabel("OpenRouter API key")
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(HubPalette.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(fieldFocused ? Color.accentRing : Color.strokeStrong,
                                          lineWidth: fieldFocused ? 1.5 : 1)
                    }
                Button("Paste", action: paste)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                if saving {
                    ProgressView().controlSize(.small).frame(width: 52)
                } else {
                    Button("Save", action: save)
                        .buttonStyle(PrimaryButtonStyle(size: .small))
                        .disabled(!draftLooksValid)
                }
                if account.maskedKey != nil {
                    Button("Cancel") {
                        replacing = false
                        draft = ""
                    }
                    .buttonStyle(.appQuiet)
                }
            }
            if !draftTrimmed.isEmpty && !draftTrimmed.hasPrefix("sk-or-") {
                Text("OpenRouter keys start with “sk-or-”.")
                    .typeface(.callout)
                    .foregroundStyle(.warning)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch account.status {
        case .missing:
            status("key.slash", .inkTertiary, "No key yet. The cloud models and Clean-up need one.")
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Checking key…").typeface(.callout).foregroundStyle(.inkSecondary)
            }
        case .valid(let info):
            status("checkmark.circle.fill", .success, connectedText(info))
        case .invalid:
            HStack(spacing: 8) {
                status("xmark.octagon.fill", .danger, "OpenRouter didn’t accept this key. Copy it again from openrouter.ai/keys.")
                checkAgain
            }
        case .noCredit:
            HStack(spacing: 8) {
                if account.status.isKeyLimitReached {
                    status("exclamationmark.triangle.fill", .warning, "This key reached its spending limit.")
                    Button("Raise Limit") { hub.open(OpenRouterLinks.keys) }
                        .buttonStyle(.appQuiet)
                } else {
                    status("exclamationmark.triangle.fill", .warning, "Key works, but the account has no credit.")
                    Button("Add Credit") { hub.open(OpenRouterLinks.credits) }
                        .buttonStyle(.appQuiet)
                }
                // After a top-up or a raised limit: nothing else re-checks until a dictation goes through.
                checkAgain
            }
        case .offline:
            status("wifi.slash", .inkTertiary, "You’re offline. We’ll check the key when you’re back.")
        case .failed(let message):
            HStack(spacing: 8) {
                status("exclamationmark.circle.fill", .warning,
                       message.isEmpty ? "Couldn’t check the key." : "Couldn’t check the key. \(message)")
                checkAgain
            }
        }
    }

    private var checkAgain: some View {
        Button("Check Again") {
            let account = account
            Task { await account.validate() }
        }
        .buttonStyle(.appQuiet)
        .fixedSize()
    }

    private func status(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .typeface(.callout)
                .monospacedDigit()
                .foregroundStyle(tint == .danger ? Color.danger : Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectedText(_ info: KeyInfo) -> String {
        var text = "Connected"
        if let remaining = info.limitRemaining {
            text += " · \(Fmt.usd(remaining)) credit left"
        } else {
            text += " · no spending limit"
        }
        if info.isFreeTier { text += " · free tier" }
        return text
    }

    /// Who hears the audio (and, with clean-up among the Switch model steps, reads the Parakeet text). Each model
    /// row names its provider; this says nothing else leaves the Mac.
    private var routing: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.success)
            Text(settings.switchChoices.contains(.cleanup)
                 ? "Only your audio, and Parakeet’s text for Clean-up by \(CleanupModel.default.shortName), goes to OpenRouter and the model’s provider."
                 : "Only your audio is sent, to OpenRouter and the model’s provider.")
                .typeface(.callout)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if draftLooksValid { save() }
    }

    private func save() {
        guard draftLooksValid, !saving else { return }
        let key = draftTrimmed
        let account = account
        saving = true
        Task { @MainActor in
            await account.setKey(key)
            saving = false
            draft = ""
            if account.maskedKey != nil { replacing = false }
        }
    }
}

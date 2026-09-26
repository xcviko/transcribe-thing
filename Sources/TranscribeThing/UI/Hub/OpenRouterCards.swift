import AppKit
import SwiftUI

/// The OpenRouter key: masked key with Replace/Remove, or a field to add one; live status; fixed routing facts.
struct OpenRouterKeyCard: View {
    /// Incremented by the page to scroll here and focus the field ("Add key", "Update key").
    var focusRequest: Int

    @Environment(HubContext.self) private var hub
    @Environment(OpenRouterAccount.self) private var account
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
            status("key.slash", .inkTertiary, "No key yet. The four cloud models need one.")
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

    /// Who hears the audio. Each model row names its provider; this says nothing else leaves the Mac.
    private var routing: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.success)
            Text("Only your audio is sent, to OpenRouter and the model’s provider.")
                .typeface(.callout)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text("Gemini reasoning").foregroundStyle(.inkSecondary)
                Text("High").fontWeight(.semibold).foregroundStyle(.ink)
                Image(systemName: "info.circle").font(.system(size: 9.5)).foregroundStyle(.inkTertiary)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Color.ink.opacity(0.05), in: Capsule(style: .continuous))
            .fixedSize()
            .help("Set for best accuracy. Parakeet and Whisper don’t reason.")
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

/// Optional system prompt for Gemini. Empty (the default) means the request carries only the audio. Parakeet
/// and Whisper take no prompt, so the card says it applies to Gemini alone.
struct GeminiInstructionsCard: View {
    @Environment(AppSettings.self) private var settings
    @FocusState private var focused: Bool

    static let example = "Transcribe the audio verbatim. Output only the transcript."

    private var isEmpty: Bool { settings.geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        @Bindable var settings = settings
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Instructions for Gemini")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.ink)
                    Text("optional")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.inkTertiary)
                    Spacer()
                    if isEmpty {
                        Badge(text: "Audio only", tint: .success, systemImage: "waveform")
                    } else {
                        Badge(text: "Sent as system prompt", tint: .accent, systemImage: "text.bubble")
                    }
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $settings.geminiSystemPrompt)
                        .typeface(.mono)
                        .foregroundStyle(.ink)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                    if settings.geminiSystemPrompt.isEmpty {
                        Text("Leave empty to send only your audio.")
                            .typeface(.mono)
                            .foregroundStyle(.inkTertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 112)
                .background(HubPalette.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(focused ? Color.accentRing : Color.stroke, lineWidth: focused ? 1.5 : 1)
                }
                .animation(Theme.Motion.hover, value: focused)
                Text("When this is empty, \(Brand.name) sends your recording with no text or system message and pastes Gemini’s reply exactly as it comes back. Anything you write here is sent as a system prompt and can change the output. Only Gemini reads it: Parakeet and Whisper transcribe without instructions.")
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 2) {
                    Button("Insert Example", action: insertExample)
                        .buttonStyle(.appQuiet)
                        .padding(.leading, -8)
                    Button("Clear") { settings.geminiSystemPrompt = "" }
                        .buttonStyle(QuietButtonStyle(tint: .inkSecondary))
                        .disabled(settings.geminiSystemPrompt.isEmpty)
                    Spacer()
                    Text(characterCount)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.inkTertiary)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    private var characterCount: String {
        let count = settings.geminiSystemPrompt.count
        return count == 1 ? "1 character" : "\(Fmt.number(count)) characters"
    }

    private func insertExample() {
        let current = settings.geminiSystemPrompt
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.geminiSystemPrompt = Self.example
        } else if !current.contains(Self.example) {
            settings.geminiSystemPrompt = current.hasSuffix("\n") ? current + Self.example : current + "\n" + Self.example
        }
    }
}

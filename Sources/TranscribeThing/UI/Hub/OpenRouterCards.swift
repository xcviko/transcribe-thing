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

    /// Who hears the audio (and, with clean-up among the Switch model steps, reads the Parakeet text). Each model row names its provider;
    /// this says nothing else leaves the Mac. How hard Gemini thinks is set on each model's row.
    private var routing: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.success)
            Text(settings.switchChoices.contains(.cleanup)
                 ? "Only your audio, and Parakeet’s text for Clean-up by \(settings.cleanupModel.shortName), goes to OpenRouter and the model’s provider."
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

/// Optional system prompt for Gemini, `AppSettings.defaultGeminiSystemPrompt` until the user changes it. Cleared
/// (empty), the request carries only the audio. Parakeet takes no prompt, so the card says it applies to Gemini alone.
struct GeminiInstructionsCard: View {
    @Environment(AppSettings.self) private var settings

    static let example = AppSettings.defaultGeminiSystemPrompt

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
                PromptEditor(text: $settings.geminiSystemPrompt,
                             placeholder: "Empty: Gemini gets only your audio.",
                             height: 150)
                Text("Sent as a system prompt with your recording, so it shapes the output. Clear it and \(Brand.name) sends your recording with no text or system message and pastes Gemini’s reply exactly as it comes back. Only Gemini reads it: Parakeet transcribes without instructions.")
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 2) {
                    Button("Use Example", action: insertExample)
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

/// The prompt the clean-up model follows to tidy a Parakeet transcript: `CleanupModel.examplePrompt` until the
/// user changes it. Cleared, Clean-up turns off until there is a prompt again: with no instruction the model would
/// reply to the transcript instead of cleaning it up. "Use Example" puts the example back, asking first when it
/// would replace a prompt of the user's own.
struct CleanupPromptCard: View {
    @Environment(AppSettings.self) private var settings
    @State private var confirmingReplace = false

    private var isEmpty: Bool { !settings.hasCleanupPrompt }
    private var isExample: Bool {
        settings.cleanupSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            == CleanupModel.examplePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var settings = settings
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Clean-up prompt")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.ink)
                    Spacer()
                    if isEmpty {
                        Badge(text: "Needed for Clean-up", tint: .warning, systemImage: "exclamationmark.triangle.fill")
                    } else {
                        Badge(text: "Sent as system prompt", tint: .accent, systemImage: "text.bubble")
                    }
                }
                PromptEditor(text: $settings.cleanupSystemPrompt,
                             placeholder: "Tell \(settings.cleanupModel.shortName) how to tidy a transcript, or start from the example.",
                             height: 150)
                Text("Sent as the system prompt. The transcript follows as the message, inside <transcript> tags, so \(settings.cleanupModel.shortName) treats it as text to edit rather than a request to answer. Ask for the cleaned text only: whatever comes back is pasted.")
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 2) {
                    Button("Use Example", action: useExample)
                        .buttonStyle(.appQuiet)
                        .padding(.leading, -8)
                        .disabled(isExample)
                        .popover(isPresented: $confirmingReplace, arrowEdge: .bottom) {
                            ReplacePromptConfirmation {
                                confirmingReplace = false
                                settings.cleanupSystemPrompt = CleanupModel.examplePrompt
                            } cancel: {
                                confirmingReplace = false
                            }
                        }
                    Button("Clear") { settings.cleanupSystemPrompt = "" }
                        .buttonStyle(QuietButtonStyle(tint: .inkSecondary))
                        .disabled(settings.cleanupSystemPrompt.isEmpty)
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
        let count = settings.cleanupSystemPrompt.count
        return count == 1 ? "1 character" : "\(Fmt.number(count)) characters"
    }

    /// Straight in when the prompt is empty; a prompt of the user's own is replaced only once they confirm.
    private func useExample() {
        if isEmpty {
            settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        } else {
            confirmingReplace = true
        }
    }
}

private struct ReplacePromptConfirmation: View {
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace your prompt?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.ink)
            Text("The example takes the place of what you wrote. Copy your prompt first to keep it.")
                .typeface(.callout)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .keyboardShortcut(.cancelAction)
                Button("Replace", action: confirm)
                    .buttonStyle(PrimaryButtonStyle(size: .small))
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

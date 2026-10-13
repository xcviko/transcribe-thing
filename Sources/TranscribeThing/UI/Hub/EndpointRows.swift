import AppKit
import SwiftUI

/// The user's own OpenAI-compatible endpoint, a row of Models' "API keys": its base URL and its key (each saved one
/// shown with Change or Replace and Remove, or a field to add it) and its live status.
struct EndpointRow: View {
    /// Incremented by the page to scroll here and focus the first field that needs filling.
    var focusRequest: Int

    @Environment(VertexProxyAccount.self) private var proxy
    @Environment(\.inNativeForm) private var inNativeForm
    @State private var urlDraft = ""
    @State private var urlProblem: VertexProxy.URLProblem?
    @State private var editingURL = false
    @State private var keyDraft = ""
    @State private var keyProblem: String?
    @State private var replacingKey = false
    @State private var saving = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case url, key }

    private var showsURLField: Bool { proxy.baseURL == nil || editingURL }
    private var showsKeyField: Bool { proxy.maskedKey == nil || replacingKey }
    private var keyTrimmed: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlTrimmed: String { urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The field holds something other than the saved base URL.
    private var urlChanged: Bool { !urlTrimmed.isEmpty && urlTrimmed != proxy.urlText }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 8) {
                labeled("Base URL") { if showsURLField { urlField } else { storedURL } }
                labeled("API key") { if showsKeyField { keyField } else { storedKey } }
            }
            statusLine
        }
        .keysRowPadding(inNativeForm: inNativeForm)
        .onAppear { urlDraft = proxy.urlText }
        .onChange(of: proxy.urlText) { _, saved in if focus != .url { urlDraft = saved } }
        .onChange(of: focusRequest) {
            if proxy.baseURL == nil {
                focus = .url
            } else if proxy.isConfigured, !isKeyProblem, proxy.status != .works {
                // Reachability or the endpoint itself: the base URL is what to look at.
                urlDraft = proxy.urlText
                editingURL = true
                focus = .url
            } else {
                if proxy.maskedKey != nil, isKeyProblem { replacingKey = true }
                focus = .key
            }
        }
    }

    private var isKeyProblem: Bool {
        switch proxy.status {
        case .keyRejected: true
        default: proxy.isKeyUnreadable
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "server.rack", tint: .inkSecondary, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenAI-compatible endpoint")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                // Who pays: worth saying every time, as OpenRouter's row does.
                Text("Any service with an OpenAI-compatible API that serves Gemini. Every Gemini request goes "
                     + "there, and you pay that service.")
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .typeface(.callout)
                .foregroundStyle(.inkSecondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("", text: $urlDraft)
                    .textFieldStyle(.plain)
                    .fieldPlaceholder("https://api.example.com/v1", isShown: urlDraft.isEmpty)
                    .typeface(.mono)
                    .foregroundStyle(.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .url)
                    .onSubmit(saveURL)
                    .onChange(of: urlDraft) { urlProblem = nil }
                    .accessibilityLabel("Endpoint base URL")
                    .modifier(FieldChrome(isFocused: focus == .url))
                Button("Save", action: saveURL)
                    .buttonStyle(PrimaryButtonStyle(size: .small))
                    .disabled(!urlChanged)
                if proxy.baseURL != nil {
                    Button("Cancel") {
                        editingURL = false
                        urlDraft = proxy.urlText
                    }
                    .buttonStyle(.appQuiet)
                }
            }
            if let urlProblem {
                Text(urlProblem.message)
                    .typeface(.callout)
                    .foregroundStyle(.warning)
            } else {
                Text(Self.urlHelp)
                    .typeface(.callout)
                    .foregroundStyle(.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What URL the field wants, and the one rule for a URL without a path (`VertexProxy.normalizedBaseURL`).
    static let urlHelp = "The URL that ends in /v1. One without a path is read as …/api/v1."

    private var storedURL: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.inkTertiary)
                Text(proxy.baseURL.map(VertexProxy.displayHost) ?? "")
                    .typeface(.mono)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .modifier(FieldChrome(isFocused: false, isStatic: true))
            Button("Change") {
                urlDraft = proxy.urlText
                editingURL = true
                focus = .url
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
            Button("Remove") {
                urlDraft = ""
                let proxy = proxy
                Task { await proxy.setURL("") }
            }
            .buttonStyle(SecondaryButtonStyle(size: .small, isDestructive: true))
        }
    }

    private var storedKey: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.inkTertiary)
                Text(proxy.maskedKey ?? "")
                    .typeface(.mono)
                    .foregroundStyle(.ink)
                    .textSelection(.disabled)
                Spacer(minLength: 0)
            }
            .modifier(FieldChrome(isFocused: false, isStatic: true))
            Button("Replace") {
                replacingKey = true
                focus = .key
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
            Button("Remove") {
                withAnimation(Theme.Motion.snappy) { proxy.removeKey() }
            }
            .buttonStyle(SecondaryButtonStyle(size: .small, isDestructive: true))
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField("", text: $keyDraft)
                    .textFieldStyle(.plain)
                    .fieldPlaceholder("Your endpoint’s API key", isShown: keyDraft.isEmpty)
                    .typeface(.mono)
                    .foregroundStyle(.ink)
                    .focused($focus, equals: .key)
                    .onSubmit(saveKey)
                    .onChange(of: keyDraft) { keyProblem = nil }
                    .accessibilityLabel("Endpoint API key")
                    .modifier(FieldChrome(isFocused: focus == .key))
                Button("Paste", action: pasteKey)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                if saving {
                    ProgressView().controlSize(.small).frame(width: 52)
                } else {
                    Button("Save", action: saveKey)
                        .buttonStyle(PrimaryButtonStyle(size: .small))
                        .disabled(!VertexProxy.looksLikeKey(keyTrimmed))
                }
                if proxy.maskedKey != nil {
                    Button("Cancel") {
                        replacingKey = false
                        keyDraft = ""
                    }
                    .buttonStyle(.appQuiet)
                }
            }
            if let keyProblem {
                Text(keyProblem)
                    .typeface(.callout)
                    .foregroundStyle(.warning)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch proxy.status {
        case .notSet:
            status("server.rack", .inkTertiary, notSetText)
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Checking your endpoint…").typeface(.callout).foregroundStyle(.inkSecondary)
            }
        case .works:
            status("checkmark.circle.fill", .success, "Works · Gemini goes through it")
        case .keyRejected:
            HStack(spacing: 8) {
                status("xmark.octagon.fill", .danger, "Your endpoint didn’t accept this key. Copy it again from where you got it.")
                checkAgain
            }
        case .spendLimit:
            HStack(spacing: 8) {
                status("exclamationmark.triangle.fill", .warning, "Your endpoint’s spend limit is reached. Raise it there.")
                checkAgain
            }
        case .unreachable:
            HStack(spacing: 8) {
                status("wifi.slash", .warning, "Can’t reach your endpoint at this URL.")
                checkAgain
            }
        case .failed(let message):
            HStack(spacing: 8) {
                status("exclamationmark.circle.fill", .warning,
                       message.isEmpty ? "Couldn’t check your endpoint." : "Couldn’t check your endpoint. \(message)")
                checkAgain
            }
        }
    }

    private var notSetText: String {
        switch (proxy.baseURL != nil, proxy.maskedKey != nil) {
        case (false, false): "Add its base URL and API key. Until then, Gemini can’t run."
        case (false, true): "Add its base URL. Until then, Gemini can’t run."
        default: "Add its API key. Until then, Gemini can’t run."
        }
    }

    private var checkAgain: some View {
        Button("Check Again") {
            let proxy = proxy
            Task { await proxy.validate() }
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
                .foregroundStyle(tint == .danger ? Color.danger : Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func saveURL() {
        guard urlChanged else { return }
        let proxy = proxy, raw = urlTrimmed
        Task { @MainActor in
            if let problem = await proxy.setURL(raw) {
                urlProblem = problem
            } else {
                urlDraft = proxy.urlText
                editingURL = false
                focus = proxy.maskedKey == nil ? .key : nil
            }
        }
    }

    private func pasteKey() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        keyDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if VertexProxy.looksLikeKey(keyTrimmed) { saveKey() }
    }

    private func saveKey() {
        guard VertexProxy.looksLikeKey(keyTrimmed), !saving else { return }
        let key = keyTrimmed, proxy = proxy
        saving = true
        Task { @MainActor in
            keyProblem = await proxy.setKey(key)
            saving = false
            if keyProblem == nil {
                keyDraft = ""
                replacingKey = false
            }
        }
    }
}

/// Which provider every cloud request goes to: OpenRouter or the custom endpoint, never both. The other's key and URL
/// stay saved.
struct ProviderPickerRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SettingsRow(title: "Provider", subtitle: "Where every Gemini request goes.", systemImage: "arrow.triangle.branch",
                    iconTint: .inkSecondary) {
            HubSegmentedPicker(title: "Provider", options: CloudProvider.allCases, selection: settings.cloudProvider,
                               label: \.name) { picked in
                withAnimation(Theme.Motion.snappy) { settings.cloudProvider = picked }
            }
        }
    }
}

extension View {
    /// A row of "API keys": in the page's form, the form's insets and a little air; elsewhere, a card's padding.
    func keysRowPadding(inNativeForm: Bool) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, inNativeForm ? 6 : Theme.Spacing.cardPadding)
            .padding(.horizontal, inNativeForm ? 0 : Theme.Spacing.cardPadding)
    }
}

/// The look of the endpoint's fields, as the OpenRouter key's.
private struct FieldChrome: ViewModifier {
    var isFocused: Bool
    var isStatic = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(HubPalette.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isStatic ? Color.stroke : (isFocused ? Color.accentRing : Color.strokeStrong),
                                  lineWidth: isFocused ? 1.5 : 1)
            }
    }
}

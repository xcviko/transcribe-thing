import AppKit
import SwiftUI

/// The user's own Vertex proxy: its address, its key (masked, with Replace and Remove, or a field to add one), its
/// live status, and "Use for Gemini", which sends Gemini through it instead of OpenRouter once it's set up.
struct VertexProxyCard: View {
    /// Incremented by the page to scroll here and focus the first field that needs filling.
    var focusRequest: Int

    @Environment(VertexProxyAccount.self) private var proxy
    @State private var urlDraft = ""
    @State private var urlProblem: VertexProxy.URLProblem?
    @State private var editingURL = false
    @State private var keyDraft = ""
    @State private var keyProblem: String?
    @State private var replacingKey = false
    @State private var saving = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case url, key }

    private var showsKeyField: Bool { proxy.maskedKey == nil || replacingKey }
    private var keyTrimmed: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlTrimmed: String { urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The field holds something other than the saved address.
    private var urlChanged: Bool { !urlTrimmed.isEmpty && urlTrimmed != proxy.urlText }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                header
                VStack(alignment: .leading, spacing: 8) {
                    labeled("Address") {
                        if proxy.baseURL == nil || editingURL { urlField } else { storedURL }
                    }
                    labeled("Key") { if showsKeyField { keyField } else { storedKey } }
                }
                statusLine
                Divider().overlay(Color.stroke)
                useForGemini
            }
        }
        .onAppear { urlDraft = proxy.urlText }
        .onChange(of: proxy.urlText) { _, saved in if focus != .url { urlDraft = saved } }
        .onChange(of: focusRequest) {
            if proxy.baseURL == nil {
                focus = .url
            } else if proxy.isConfigured, !isKeyProblem, proxy.status != .works {
                // Reachability or the proxy itself: the address is what to look at.
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
                Text("Vertex proxy")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                // Who pays: worth saying every time, as the OpenRouter card does.
                Text("Your own proxy to Vertex AI. Gemini runs on your Google Cloud credits instead of OpenRouter’s.")
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
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("", text: $urlDraft)
                    .textFieldStyle(.plain)
                    .fieldPlaceholder("https://vertex-proxy-….run.app", isShown: urlDraft.isEmpty)
                    .typeface(.mono)
                    .foregroundStyle(.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .url)
                    .onSubmit(saveURL)
                    .onChange(of: urlDraft) { urlProblem = nil }
                    .accessibilityLabel("Vertex proxy address")
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
            }
        }
    }

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
                    .fieldPlaceholder("\(VertexProxy.keyPrefix)…", isShown: keyDraft.isEmpty)
                    .typeface(.mono)
                    .foregroundStyle(.ink)
                    .focused($focus, equals: .key)
                    .onSubmit(saveKey)
                    .onChange(of: keyDraft) { keyProblem = nil }
                    .accessibilityLabel("Vertex proxy key")
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
            if let problem = keyProblem ?? VertexProxy.keyProblem(keyTrimmed) {
                Text(problem)
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
                Text("Checking the proxy…").typeface(.callout).foregroundStyle(.inkSecondary)
            }
        case .works:
            status("checkmark.circle.fill", .success, proxy.isEnabled
                ? "Works · paid from your Google Cloud credits"
                : "Works · Gemini goes through OpenRouter while Use for Gemini is off")
        case .keyRejected:
            HStack(spacing: 8) {
                status("xmark.octagon.fill", .danger, "The proxy didn’t accept this key. Copy it again from its dashboard.")
                checkAgain
            }
        case .spendLimit:
            HStack(spacing: 8) {
                status("exclamationmark.triangle.fill", .warning, "The proxy’s spend limit is reached. Raise it on the proxy.")
                checkAgain
            }
        case .unreachable:
            HStack(spacing: 8) {
                status("wifi.slash", .warning, "Can’t reach the proxy at this address.")
                checkAgain
            }
        case .failed(let message):
            HStack(spacing: 8) {
                status("exclamationmark.circle.fill", .warning,
                       message.isEmpty ? "Couldn’t check the proxy." : "Couldn’t check the proxy. \(message)")
                checkAgain
            }
        }
    }

    private var notSetText: String {
        switch (proxy.baseURL != nil, proxy.maskedKey != nil) {
        case (false, false): "Add its address and key to send Gemini through it."
        case (false, true): "Add its address to send Gemini through it."
        default: "Add its key to send Gemini through it."
        }
    }

    private var useForGemini: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use for Gemini")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(proxy.isConfigured ? Color.ink : Color.inkTertiary)
                Text("Gemini goes through your proxy instead of OpenRouter. "
                     + "\(EngineID.parakeetCloud.displayName) still uses OpenRouter.")
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: enabled)
                .toggleStyle(.appSwitch)
                .labelsHidden()
                .disabled(!proxy.isConfigured)
                .accessibilityLabel("Use the Vertex proxy for Gemini")
        }
    }

    private var enabled: Binding<Bool> {
        let proxy = proxy
        return Binding(get: { proxy.isConfigured && proxy.isEnabled },
                       set: { on in withAnimation(Theme.Motion.snappy) { proxy.isEnabled = on } })
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

/// The look of the card's fields, as the OpenRouter key's.
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

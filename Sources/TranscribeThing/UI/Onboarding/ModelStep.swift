import SwiftUI

struct ModelStep: View {
    let model: OnboardingModel

    /// Width of the cloud card row, so the key panel's notch can point at the selected card.
    @State private var cloudRowWidth: CGFloat = 0

    private var selected: EngineID { model.selectedEngine }

    private static let cloudSpacing: CGFloat = 10

    /// One line under the local cards that answers the question the selected one raises.
    private var localNote: (symbol: String, text: String)? {
        guard selected.isLocal else { return nil }
        let name = selected.shortName
        switch model.ctx.models.state(of: selected) {
        case .notInstalled:
            let size = selected.approxDownloadBytes.map(Fmt.bytes) ?? ""
            let free = model.freeDiskBytes < .max ? " \(Fmt.bytes(model.freeDiskBytes)) free on this Mac." : ""
            return ("internaldrive", "\(name) downloads once (\(size)), then works offline.\(free)")
        case .downloading:
            return ("arrow.down.circle", "The download keeps going if you continue. You can practice as soon as it’s done.")
        case .preparing, .installed:
            return ("cpu", "\(name) is being tuned for this Mac’s Neural Engine. This can take a few minutes.")
        case .ready:
            return ("lock.shield", "\(name) runs entirely on your Mac. Nothing you say leaves this computer.")
        case .failed(let message):
            return ("exclamationmark.triangle", message.isEmpty ? "Something went wrong. Try again." : message)
        }
    }

    /// 0...1 across the key panel: the center of the selected cloud card.
    private var notchX: CGFloat {
        let engines = EngineID.cloudEngines
        guard let index = engines.firstIndex(of: selected), cloudRowWidth > 0 else { return 0.5 }
        let count = CGFloat(engines.count)
        let cardWidth = (cloudRowWidth - Self.cloudSpacing * (count - 1)) / count
        return (CGFloat(index) * (cardWidth + Self.cloudSpacing) + cardWidth / 2) / cloudRowWidth
    }

    var body: some View {
        let cloudSelected = selected.isCloud
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Pick how \(Brand.name) listens",
                       subtitle: "On-device models stay private and work offline. You can switch anytime in Settings.",
                       titleSize: 28)
                .padding(.bottom, 16)

            SectionHeader("On your Mac")
                .padding(.bottom, 8)
            HStack(spacing: 12) {
                ForEach(EngineID.localEngines) { engine in
                    EngineCard(model: model, engine: engine, compact: cloudSelected)
                }
            }
            if !cloudSelected, let note = localNote {
                HStack(spacing: 7) {
                    Image(systemName: note.symbol)
                        .font(.system(size: 11, weight: .semibold))
                    Text(note.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(.inkSecondary)
                .padding(.top, 10)
                .padding(.leading, 4)
                .transition(.opacity)
                .id(note.text)
            }

            SectionHeader("Through OpenRouter") {
                CloudKeySummary(status: model.ctx.account.status, hasStoredKey: model.ctx.account.maskedKey != nil)
            }
            .padding(.top, cloudSelected ? 16 : 18)
            .padding(.bottom, 8)
            HStack(spacing: Self.cloudSpacing) {
                ForEach(EngineID.cloudEngines) { engine in
                    CloudEngineCard(model: model, engine: engine)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cloudRowWidth = $0 }

            if cloudSelected {
                OpenRouterKeyPanel(model: model, notchX: notchX)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.expand, value: cloudSelected)
        .animation(Theme.Motion.snappy, value: selected)
    }
}

/// Trailing text of the "Through OpenRouter" header: what the four cloud cards have in common, or the key's state.
private struct CloudKeySummary: View {
    var status: KeyStatus
    var hasStoredKey: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let symbol = content.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(content.tone.color)
            }
            Text(content.text)
                .foregroundStyle(content.tone == .negative ? Color.danger : Color.inkTertiary)
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .animation(Theme.Motion.fade, value: status)
    }

    private var content: (symbol: String?, text: String, tone: StatusTone) {
        switch status {
        case .valid(let info):
            let credit = info.limitRemaining.map { " · \(Fmt.usd($0)) left" } ?? ""
            return ("checkmark.circle.fill", "Key connected\(credit)", .positive)
        case .invalid:
            return ("xmark.octagon.fill", "Key rejected", .negative)
        case .noCredit:
            return ("exclamationmark.triangle.fill", status.isKeyLimitReached ? "Key limit reached" : "No credit left", .warning)
        case .missing, .checking, .offline, .failed:
            return (nil, hasStoredKey ? "One key for all four · pay per use" : "Needs an OpenRouter key · pay per use", .neutral)
        }
    }
}

// MARK: - Cloud card

/// Compact card for a model served through OpenRouter: name, who serves it, what it costs.
private struct CloudEngineCard: View {
    let model: OnboardingModel
    let engine: EngineID

    @State private var hovering = false

    private var isSelected: Bool { model.selectedEngine == engine }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                EngineIcon(engine: engine, size: 24)
                Spacer(minLength: 0)
                RadioMark(isOn: isSelected, size: 18)
            }
            .padding(.bottom, 7)
            Text(engine.cloudCardName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.ink)
                .lineLimit(1)
            Text("\(engine.cloudCardProvider) · \(engine.cloudCardPrice)")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.inkSecondary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .padding(.horizontal, 11)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            shape.fill(Color.bgSurface)
            shape.fill(isSelected ? Color.accentSoft : (hovering ? Color.hover : .clear))
        }
        .overlay {
            shape.strokeBorder(isSelected ? Color.accent : Color.stroke, lineWidth: isSelected ? 1.5 : 1)
        }
        .cardShadow(elevated: isSelected)
        .contentShape(shape)
        .onTapGesture { model.select(engine) }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.expand, value: isSelected)
        .help(engine.cloudCardHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(engine.displayName)
        .accessibilityValue("\(engine.cloudCardProvider), \(engine.cloudCardPrice)")
        .accessibilityAction { model.select(engine) }
    }
}

private extension EngineID {
    /// Under the "Through OpenRouter" header the "· Cloud" suffix is noise; Whisper takes its short name to fit.
    var cloudCardName: String {
        switch self {
        case .whisperCloud: "Whisper Turbo"
        default: modelName
        }
    }

    /// "via Together", "via Groq", "via Google". For Whisper this is the preferred provider; the key panel and the
    /// tooltip say OpenRouter may pick another.
    var cloudCardProvider: String {
        switch cloudAPI {
        case .chatCompletions: "via Google"
        case .transcriptions, nil: preferredProvider.map { "via \($0)" } ?? ""
        }
    }

    var cloudCardPrice: String {
        switch self {
        case .parakeetCloud: "≈ $0.09/hour"
        case .whisperCloud: "≈ $0.04/hour"
        case .geminiFlash, .geminiPro: "pay per use"
        case .parakeet, .whisper: ""
        }
    }

    var cloudCardHelp: String {
        [displayName, providerLine, factLine, providerRoutingNote].compactMap { $0 }.joined(separator: "\n")
    }
}

// MARK: - Local card

private struct EngineCard: View {
    let model: OnboardingModel
    let engine: EngineID
    var compact: Bool

    @State private var hovering = false

    private var isSelected: Bool { model.selectedEngine == engine }
    private var localState: LocalModelState { model.ctx.models.state(of: engine) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            if !compact {
                Spacer(minLength: 10)
                localFooter
                    .frame(minHeight: 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 12 : 14)
        .frame(maxWidth: .infinity, minHeight: compact ? 58 : 124, maxHeight: compact ? 58 : 124, alignment: .topLeading)
        .background {
            shape.fill(Color.bgSurface)
            shape.fill(isSelected ? Color.accentSoft : (hovering ? Color.hover : .clear))
        }
        .overlay {
            shape.strokeBorder(isSelected ? Color.accent : Color.stroke, lineWidth: isSelected ? 1.5 : 1)
        }
        .cardShadow(elevated: isSelected)
        .contentShape(shape)
        .onTapGesture { model.select(engine) }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.expand, value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(engine.displayName)
        .accessibilityAction { model.select(engine) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            // The slot keeps its width when the icon shrinks, so names line up down the grid.
            EngineIcon(engine: engine, size: compact ? 32 : 34)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                if compact {
                    compactStatus
                } else {
                    Text(engine.providerLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.inkSecondary)
                    Text(factLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            RadioMark(isOn: isSelected)
        }
    }

    private var factLine: String {
        guard let bytes = engine.approxDownloadBytes else { return engine.factLine }
        return "\(engine.factLine) · \(Fmt.bytes(bytes))"
    }

    @ViewBuilder private var compactStatus: some View {
        if case .downloading(let p) = localState {
            Text("Downloading \(p.percent)%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.inkSecondary)
        } else {
            ModelStatusText(state: localState, engine: engine, showsDot: false,
                            localError: model.ctx.models.lastErrors[engine])
        }
    }

    // MARK: Footer

    @ViewBuilder private var localFooter: some View {
        switch localState {
        case .downloading(let progress):
            DownloadProgressRow(engine: engine, progress: progress) { model.cancelDownload(engine) }
        case .preparing(let since):
            PreparingRow(since: since)
        case .failed:
            // A model that downloaded but won't load needs fresh files: "Try again" only loads the same ones.
            let loadFailed = ModelFailure(model.ctx.models.lastErrors[engine]) == .load
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.danger)
                Text(loadFailed ? "Couldn’t load" : "Download didn’t finish")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.danger)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Try Again") { model.download(engine) }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .fixedSize()
                if loadFailed {
                    Button("Download Again") { model.reinstall(engine) }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                        .fixedSize()
                }
            }
        case .notInstalled:
            if isSelected, !model.hasEnoughDisk(for: engine), let needed = model.requiredDiskBytes(for: engine) {
                DiskWarningRow(needed: needed, available: model.freeDiskBytes) { model.openStorageSettings() }
            } else {
                HStack(spacing: 8) {
                    badges
                    Spacer(minLength: 0)
                    Button("Download") { model.download(engine) }
                        .buttonStyle(downloadStyle)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
        case .installed:
            HStack(spacing: 8) {
                badges
                Spacer(minLength: 0)
                Text("On your Mac")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.inkSecondary)
            }
        case .ready:
            HStack(spacing: 8) {
                badges
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    DrawOnCheck(size: 16, animated: model.celebrateReady.contains(engine))
                    Text("Ready")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.success)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var downloadStyle: AnyButtonStyle {
        isSelected ? AnyButtonStyle(PrimaryButtonStyle(size: .small)) : AnyButtonStyle(SecondaryButtonStyle(size: .small))
    }

    private var badges: some View {
        HStack(spacing: 5) {
            ForEach(engine.badges, id: \.self) { Badge.engine($0) }
        }
    }
}

/// Type-erased button style so a card can swap primary/secondary without duplicating the button.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

private struct RadioMark: View {
    var isOn: Bool
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Color.accentFill)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.onAccent)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle().strokeBorder(Color.strokeStrong, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.28, bounce: 0.4), value: isOn)
        .accessibilityHidden(true)
    }
}

private struct DownloadProgressRow: View {
    var engine: EngineID
    var progress: DownloadProgress
    var onCancel: () -> Void

    var body: some View {
        let total = progress.totalBytes > 0 ? progress.totalBytes : (engine.approxDownloadBytes ?? 0)
        let received = progress.bytesReceived > 0 ? progress.bytesReceived : Int64(Double(total) * progress.fraction)
        let eta = progress.secondsRemaining.map { " · \(Fmt.eta($0))" } ?? ""
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                ProgressBar(fraction: progress.fraction)
                Text("\(Fmt.bytes(received)) of \(Fmt.bytes(total))\(eta)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.inkSecondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("Cancel download")
            .accessibilityLabel("Cancel download")
        }
    }
}

private struct PreparingRow: View {
    var since: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ShimmerBar()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(since)
                HStack(spacing: 0) {
                    Text("Optimizing for your Mac… can take a few minutes")
                    if elapsed >= 20 {
                        Text(" · \(Fmt.duration(elapsed))")
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.inkSecondary)
                .lineLimit(1)
            }
        }
    }
}

private struct DiskWarningRow: View {
    var needed: Int64
    var available: Int64
    var onManage: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.warning)
            // Both numbers stay whole: the line wraps rather than cutting off the free space.
            Text("Needs \(Fmt.bytes(needed)) · \(Fmt.bytes(available)) free")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.warning)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Manage Storage…", action: onManage)
                .buttonStyle(QuietButtonStyle(tint: .accent, size: .small))
                .fixedSize()
        }
    }
}

// MARK: - OpenRouter key

private struct OpenRouterKeyPanel: View {
    let model: OnboardingModel
    /// 0...1 across the panel: where the notch points up at the selected card.
    var notchX: CGFloat

    @FocusState private var fieldFocused: Bool
    @State private var revealKey = false
    @Environment(\.onboardingStillTime) private var stillTime

    private var account: OpenRouterAccount { model.ctx.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("OpenRouter API key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                Text("One key works for all four cloud models.")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkTertiary)
                Spacer(minLength: 0)
                Link(destination: OpenRouterLinks.keys) {
                    HStack(spacing: 3) {
                        Text("Get a key at openrouter.ai/keys")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.accent)
                }
                .pointerStyle(.link)
            }

            if model.showsKeyField {
                HStack(spacing: 8) {
                    keyField
                    Button {
                        model.pasteKey()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .regular))
                }
            } else {
                storedKeyRow
            }

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                KeyStatusLine(status: account.status, formatError: model.keyFormatError,
                              hasDraft: !model.keyDraft.isEmpty, showingStoredKey: !model.showsKeyField)
                Spacer(minLength: 12)
                Text(privacyLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.inkSecondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(KeyPanelShape(notchX: notchX).fill(Color.bgSurface))
        .overlay(KeyPanelShape(notchX: notchX).stroke(Color.accentRing, lineWidth: 1))
        .cardShadow(elevated: true)
        .animation(Theme.Motion.fade, value: model.showsKeyField)
        .onAppear {
            if stillTime == nil, model.showsKeyField, !model.ctx.isPreview { fieldFocused = true }
        }
    }

    /// Names who hears the audio for the selected model. Transcription requests can't pin a provider, so for
    /// Whisper it names every provider OpenRouter may pick.
    private var privacyLine: String {
        let engine = model.selectedEngine
        let providers = engine.knownProviders
        if engine.providerRoutingNote != nil, providers.count > 1 {
            return "Your audio goes to OpenRouter, then \(providers.joined(separator: " or ")) (OpenRouter picks each time). Nothing else is sent."
        }
        return "Your audio goes to OpenRouter and \(providers.first ?? "its provider") to be transcribed. Nothing else is sent."
    }

    private var keyField: some View {
        let text = Binding(get: { model.keyDraft }, set: { model.updateKeyDraft($0) })
        return HStack(spacing: 6) {
            Group {
                if revealKey {
                    TextField("", text: text)
                } else {
                    SecureField("", text: text)
                }
            }
            .textFieldStyle(.plain)
            .fieldPlaceholder("sk-or-v1-…", isShown: model.keyDraft.isEmpty)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(.ink)
            .autocorrectionDisabled()
            .focused($fieldFocused)
            .onSubmit { model.submitKeyDraft() }
            if !model.keyDraft.isEmpty {
                Button {
                    revealKey.toggle()
                } label: {
                    Image(systemName: revealKey ? "eye.slash" : "eye")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help(revealKey ? "Hide key" : "Show key")
                .accessibilityLabel(revealKey ? "Hide key" : "Show key")
            }
        }
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .frame(height: 32)
            .background(Color.bgSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(fieldFocused ? Color.accentRing : Color.stroke, lineWidth: fieldFocused ? 2 : 1)
            }
            .accessibilityLabel("OpenRouter API key")
    }

    private var storedKeyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.accent)
                .frame(width: 26, height: 26)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(account.maskedKey ?? "")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.ink)
            Text("Saved in your Keychain")
                .font(.system(size: 11.5))
                .foregroundStyle(.inkTertiary)
            Spacer(minLength: 0)
            Button("Replace") { model.replaceKey() }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            Button("Remove") { model.removeKey() }
                .buttonStyle(QuietButtonStyle(tint: .danger, size: .small))
        }
        .frame(height: 32)
    }
}

/// Status line under the key field, per wispr-ux §4.5.
private struct KeyStatusLine: View {
    var status: KeyStatus
    var formatError: String?
    var hasDraft: Bool
    var showingStoredKey: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon
            text
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Theme.Motion.fade, value: status)
    }

    private var content: (symbol: String?, text: String, tone: StatusTone) {
        if let formatError { return ("xmark.octagon.fill", formatError, .negative) }
        switch status {
        case .missing:
            return (nil, hasDraft ? "" : "Paste your key to connect.", .neutral)
        case .checking:
            return (nil, "Checking key…", .progress)
        case .valid(let info):
            if let remaining = info.limitRemaining {
                return ("checkmark.circle.fill", "Connected · \(Fmt.usd(remaining)) credit left", .positive)
            }
            return ("checkmark.circle.fill", "Connected · no spending limit", .positive)
        case .invalid:
            return ("xmark.octagon.fill", "OpenRouter didn’t accept this key. Copy it again from openrouter.ai/keys.", .negative)
        case .noCredit where status.isKeyLimitReached:
            return ("exclamationmark.triangle.fill", "Key works, but it reached its spending limit. Raise it at openrouter.ai/keys.", .warning)
        case .noCredit:
            return ("exclamationmark.triangle.fill", "Key works, but the account has no credit. Add credits at openrouter.ai/credits.", .warning)
        case .offline:
            return ("wifi.slash", "You’re offline. We’ll check the key when you’re back.", .neutral)
        case .failed(let message):
            return ("exclamationmark.triangle.fill", "Couldn’t check the key: \(message)", .warning)
        }
    }

    @ViewBuilder private var icon: some View {
        if case .checking = status, formatError == nil {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        } else if let symbol = content.symbol {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(content.tone.color)
        }
    }

    private var text: Text { Text(content.text) }

    private var color: Color {
        switch content.tone {
        case .negative: .danger
        case .warning: .warning
        case .positive: .success
        case .progress, .neutral: .inkSecondary
        }
    }
}

/// Rounded panel with a small notch pointing up at the selected cloud card.
private struct KeyPanelShape: Shape {
    /// 0...1 across the width.
    var notchX: CGFloat
    var radius: CGFloat = Theme.Radius.card
    var notchWidth: CGFloat = 18
    var notchHeight: CGFloat = 8

    var animatableData: CGFloat {
        get { notchX }
        set { notchX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        let cx = rect.minX + rect.width * notchX
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: cx - notchWidth / 2, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: cx, y: rect.minY - notchHeight),
                       control: CGPoint(x: cx - notchWidth / 4, y: rect.minY - notchHeight * 0.1))
        p.addQuadCurve(to: CGPoint(x: cx + notchWidth / 2, y: rect.minY),
                       control: CGPoint(x: cx + notchWidth / 4, y: rect.minY - notchHeight * 0.1))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

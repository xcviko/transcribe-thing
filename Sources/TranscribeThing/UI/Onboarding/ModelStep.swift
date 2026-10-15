import SwiftUI

struct ModelStep: View {
    let model: OnboardingModel

    /// The main model is Gemini (onboarding replayed after picking it in Models): its key is what the step needs.
    private var mainIsGemini: Bool { model.ctx.settings.lineup.main.isGemini }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Get \(EngineID.parakeet.modelName) on your Mac",
                       subtitle: "It transcribes on your Mac, private and offline, with no key. "
                           + "\(EngineID.geminiFlash.modelName), which hears the audio in the cloud with your own key, "
                           + "is in Settings → Models.",
                       titleSize: 28)
                .padding(.bottom, 16)

            SectionHeader("On your Mac")
                .padding(.bottom, 8)
            ForEach(EngineID.localEngines) { engine in
                LocalModelCard(model: model, engine: engine, compact: false)
            }

            if mainIsGemini, model.ctx.proxy?.routesGemini != true {
                OpenRouterKeyPanel(model: model)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            SwitchModelNote(text: model.lineupNote)
                .padding(.top, 14)
        }
        .animation(Theme.Motion.expand, value: mainIsGemini)
    }
}

/// One line under the models: Gemini isn't picked here, it's a key press away while dictating.
private struct SwitchModelNote: View {
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.inkSecondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

private extension EngineID {
    /// The local card's spec strip: what running on this Mac gets you. Only the local model has a card.
    var localFacts: [LocalFact] {
        guard self == .parakeet else { return [] }
        return [LocalFact(symbol: "bolt.fill", title: "Fastest", detail: "No upload, no waiting"),
                LocalFact(symbol: "globe", title: "25 languages", detail: "European, auto-detected"),
                LocalFact(symbol: "lock.fill", title: "Private", detail: "Audio stays on this Mac"),
                LocalFact(symbol: "wifi.slash", title: "Offline", detail: "No internet, no key")]
    }
}

private struct LocalFact: Hashable {
    var symbol: String
    var title: String
    var detail: String
}

// MARK: - Local card

/// The model that runs on this Mac, full width: what it offers, then a footer that downloads it, shows the
/// download or the first optimization, or says it's ready. `compact`: one row.
private struct LocalModelCard: View {
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
                facts
                    .padding(.top, 16)
                Rectangle()
                    .fill(Color.stroke)
                    .frame(height: 1)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                footer
                    .frame(minHeight: 28)
                    .id(footerID)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, compact ? 12 : 16)
        .padding(.bottom, 12)
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
        .animation(Theme.Motion.fade, value: footerID)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(engine.displayName)
        .accessibilityAction { model.select(engine) }
    }

    private var header: some View {
        HStack(alignment: compact ? .center : .top, spacing: 12) {
            // The slot keeps its width when the icon shrinks, so the name doesn't jump.
            EngineIcon(engine: engine, size: compact ? 32 : 40)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(engine.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    ForEach(engine.badges.filter { !EngineID.privacyBadges.contains($0) }, id: \.self) {
                        Badge.engine($0)
                    }
                }
                if compact {
                    compactStatus
                } else {
                    Text(engine.providerLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            RadioMark(isOn: isSelected)
        }
    }

    /// Equal columns across the card, hairlines between them.
    private var facts: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(engine.localFacts.enumerated()), id: \.element) { index, fact in
                if index > 0 {
                    Rectangle()
                        .fill(Color.stroke)
                        .frame(width: 1, height: 30)
                        .padding(.horizontal, 12)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: fact.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.accent)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.ink)
                        Text(fact.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.inkSecondary)
                    }
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
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

    /// Changes when the footer swaps layouts, so it cross-fades instead of morphing.
    private var footerID: String {
        switch localState {
        case .notInstalled: "notInstalled"
        case .downloading: "downloading"
        case .installed, .ready: "onDisk"
        case .preparing: "preparing"
        case .failed: "failed"
        }
    }

    @ViewBuilder private var footer: some View {
        switch localState {
        case .downloading(let progress):
            DownloadProgressRow(engine: engine, progress: progress) { model.cancelDownload(engine) }
        case .preparing(let since):
            PreparingRow(since: since)
        case .failed(let message):
            // A model that downloaded but won't load needs fresh files: "Try again" only loads the same ones.
            let loadFailed = ModelFailure(model.ctx.models.lastErrors[engine]) == .load
            HStack(spacing: 8) {
                FooterNote(symbol: "exclamationmark.triangle.fill", tint: .danger,
                           text: message.isEmpty ? "Something went wrong. Try again." : message)
                Spacer(minLength: 8)
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
                    FooterNote(symbol: "internaldrive", tint: .inkSecondary, text: downloadNote)
                    Spacer(minLength: 8)
                    Button {
                        model.download(engine)
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                    .buttonStyle(downloadStyle)
                    .fixedSize()
                    .layoutPriority(1)
                }
            }
        case .installed, .ready:
            HStack(spacing: 8) {
                FooterNote(symbol: "internaldrive", tint: .inkSecondary, text: onDiskNote)
                Spacer(minLength: 8)
                if localState == .ready {
                    HStack(spacing: 6) {
                        DrawOnCheck(size: 16, animated: model.celebrateReady.contains(engine))
                        Text("Ready")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.success)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Loads on first use")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.inkSecondary)
                }
            }
        }
    }

    /// "Downloads once · 632 MB · 212 GB free on this Mac"
    private var downloadNote: String {
        let size = engine.approxDownloadBytes.map { " · \(Fmt.bytes($0))" } ?? ""
        let free = model.freeDiskBytes < .max ? " · \(Fmt.bytes(model.freeDiskBytes)) free on this Mac" : ""
        return "Downloads once\(size)\(free)"
    }

    /// "Downloaded · 632 MB on this Mac"
    private var onDiskNote: String {
        engine.approxDownloadBytes.map { "Downloaded · \(Fmt.bytes($0)) on this Mac" } ?? "Downloaded"
    }

    private var downloadStyle: AnyButtonStyle {
        isSelected ? AnyButtonStyle(PrimaryButtonStyle(size: .small)) : AnyButtonStyle(SecondaryButtonStyle(size: .small))
    }
}

/// Symbol + one line of text on the left of the local card's footer.
private struct FooterNote: View {
    var symbol: String
    var tint: Color
    var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tint == .danger ? Color.danger : Color.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .monospacedDigit()
    }
}

/// Type-erased button style so the local card can swap primary/secondary without duplicating the button.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
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
                HStack(spacing: 0) {
                    Text("\(Fmt.bytes(received)) of \(Fmt.bytes(total))\(eta)")
                        .foregroundStyle(.inkSecondary)
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Text("Keeps going if you continue")
                        .foregroundStyle(.inkTertiary)
                }
                .font(.system(size: 11.5).monospacedDigit())
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
                    Text("Loading model into memory… usually under a minute")
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

/// The OpenRouter key, when the main model is Gemini (onboarding replayed after picking it in Models).
private struct OpenRouterKeyPanel: View {
    let model: OnboardingModel

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
                Text("For \(model.ctx.settings.lineup.main.modelName), your main model.")
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
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color.bgSurface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Color.accentRing, lineWidth: 1))
        .cardShadow(elevated: true)
        .animation(Theme.Motion.fade, value: model.showsKeyField)
        .onAppear {
            if stillTime == nil, model.showsKeyField, !model.ctx.isPreview { fieldFocused = true }
        }
    }

    /// Names who hears the audio for the main model.
    private var privacyLine: String {
        let provider = model.ctx.settings.mainEngine.provider ?? "its provider"
        return "Only your audio goes, to OpenRouter and \(provider), to be transcribed."
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
            Text("Stored on this Mac")
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
            return ("wifi.slash", "No connection. We’ll check the key when it’s back.", .neutral)
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

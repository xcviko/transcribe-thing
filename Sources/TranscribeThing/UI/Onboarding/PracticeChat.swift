import SwiftUI

/// A pretend conversation with a real, focused text field: the actual dictation pipeline pastes into it.
struct PracticeChat: View {
    let model: OnboardingModel

    @FocusState private var composerFocused: Bool
    @Environment(\.onboardingStillTime) private var stillTime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.stroke).frame(height: 1)
            messages
            composerArea
        }
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
        .cardShadow(elevated: true)
        .padding(18)
        .onAppear {
            guard stillTime == nil, !model.ctx.isPreview else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                composerFocused = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Text("A")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [Color.warm, Color(nsColor: .hex(0xE0708A))],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                Circle()
                    .fill(Color.success)
                    .frame(width: 9, height: 9)
                    .overlay { Circle().strokeBorder(Color.bgSurface, lineWidth: 2) }
                    .offset(x: 1, y: 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Alex")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                Text(model.alexIsTyping ? "typing…" : "Design · practice chat")
                    .font(.system(size: 11))
                    .foregroundStyle(model.alexIsTyping ? Color.accent : Color.inkTertiary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.inkTertiary)
                .help("Practice only. Nothing leaves this window.")
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    Text("Today")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.inkTertiary)
                        .padding(.bottom, 2)
                    ForEach(model.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                            .transition(bubbleTransition(for: message))
                    }
                    if model.alexIsTyping {
                        TypingBubble()
                            .id("typing")
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 0, alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.32), value: model.messages)
            .animation(Theme.Motion.fade, value: model.alexIsTyping)
            .onChange(of: model.messages.count) {
                if let last = model.messages.last { withAnimation(Theme.Motion.expand) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bubbleTransition(for message: ChatMessage) -> AnyTransition {
        if reduceMotion { return .opacity }
        switch message.sender {
        case .me: return .opacity.combined(with: .scale(scale: 0.55, anchor: .bottomTrailing))
        case .alex: return .opacity.combined(with: .scale(scale: 0.7, anchor: .bottomLeading))
        case .note: return .opacity.combined(with: .offset(y: 6))
        }
    }

    // MARK: Composer

    @ViewBuilder private var composerArea: some View {
        let readiness = model.practiceReadiness
        VStack(spacing: 0) {
            if case .warmingUp(let engine) = readiness {
                Text("\(engine.shortName) is getting ready. The first reply may take a moment.")
                    .font(.system(size: 11))
                    .foregroundStyle(.inkTertiary)
                    .padding(.bottom, 8)
            }
            if readiness.allowsPractice {
                composer
            } else {
                ReadinessBanner(model: model, readiness: readiness)
            }
        }
        .padding(12)
        .animation(Theme.Motion.fade, value: readiness)
    }

    private var composer: some View {
        let phase = model.ctx.pillModel.phase
        let prompt = "Hold \(model.pushToTalkLabel) and answer out loud…"
        return HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                TextField("", text: Binding(get: { model.draft }, set: { model.updateDraft($0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .fieldPlaceholder(prompt, isShown: model.draft.isEmpty, alignment: .topLeading)
                    .font(.system(size: 13))
                    .foregroundStyle(.ink)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit { model.submitDraft() }
                    .accessibilityLabel("Message to Alex")
                if phase.isRecording {
                    StageClock(paused: reduceMotion) { t in
                        PillBars(level: Double(model.ctx.levelMeter.level), time: t, color: .accent, maxHeight: 14)
                            .scaleEffect(0.8)
                    }
                    .frame(width: 58, height: 16)
                    .transition(.opacity)
                } else if phase == .processing {
                    TypingDots(color: .accent)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .background(Color.bgSunken, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                // Ring fill instead of strokeBorder: fully rounded strokes leave seams in snapshots.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .ring(composerFocused || phase.isActive ? 1.5 : 1)
                    .fill(composerFocused || phase.isActive ? Color.accentRing : Color.stroke, style: FillStyle(eoFill: true))
            }
            .animation(Theme.Motion.fade, value: phase)

            Button {
                model.submitDraft()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.accentFill, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
            .help("Send")
            .accessibilityLabel("Send")
        }
    }
}

// MARK: - Bubbles

private struct ChatBubble: View {
    var message: ChatMessage

    var body: some View {
        switch message.sender {
        case .alex:
            HStack {
                bubble(fill: Color.bubbleIncoming, text: .ink, tail: .bottomLeading)
                Spacer(minLength: 56)
            }
        case .me:
            HStack {
                Spacer(minLength: 56)
                bubble(fill: .accentFill, text: .onAccent, tail: .bottomTrailing)
            }
        case .note:
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 11))
                Text(message.text)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.ink.opacity(0.04), in: Capsule(style: .continuous))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
    }

    private func bubble(fill: Color, text: Color, tail: UnitPoint) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 17, bottomLeadingRadius: tail == .bottomLeading ? 5 : 17,
            bottomTrailingRadius: tail == .bottomTrailing ? 5 : 17, topTrailingRadius: 17, style: .continuous)
        return Text(message.text)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(fill, in: shape)
            .textSelection(.enabled)
    }
}

private extension Color {
    static let bubbleIncoming = Color(nsColor: Palette.dynamic("bubbleIncoming", light: .hex(0xF0ECE6), dark: .hex(0x2C2B28)))
}

private struct TypingBubble: View {
    var body: some View {
        HStack {
            TypingDots(color: .inkTertiary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.bubbleIncoming,
                            in: UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 5,
                                                       bottomTrailingRadius: 17, topTrailingRadius: 17, style: .continuous))
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Alex is typing")
    }
}

private struct TypingDots: View {
    var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StageClock(paused: reduceMotion) { t in
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let lift = max(0, sin(2 * .pi * (t / 1.1) - Double(i) * 0.9))
                    Circle()
                        .fill(color.opacity(0.5 + 0.5 * lift))
                        .frame(width: 6, height: 6)
                        .offset(y: reduceMotion ? 0 : -3 * lift)
                }
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Fallbacks

/// Replaces the composer when practice can't work yet, with the one action that fixes it.
private struct ReadinessBanner: View {
    let model: OnboardingModel
    var readiness: PracticeReadiness

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.accent)
                    .frame(width: 28, height: 28)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(message)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .downloading(_, let fraction) = readiness {
                ProgressBar(fraction: fraction)
            }
            if let action {
                HStack {
                    Spacer(minLength: 0)
                    Button(action.title, action: action.run)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                }
            }
        }
        .padding(12)
        .background(Color.bgSunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
    }

    private var symbol: String {
        switch readiness {
        case .needsMicrophone: "mic.fill"
        case .needsAccessibility: "accessibility"
        case .downloading: "arrow.down.circle"
        case .notDownloaded: "icloud.and.arrow.down"
        case .needsKey: "key.fill"
        case .ready, .warmingUp: "checkmark"
        }
    }

    private var message: String {
        switch readiness {
        case .needsMicrophone:
            "Allow the microphone and you can practice right here."
        case .needsAccessibility:
            "Turn on Accessibility so \(Brand.name) can hear your shortcut and paste into this box."
        case .downloading(let engine, let fraction):
            "\(engine.shortName) is still downloading (\(Fmt.percent(fraction))). You can practice as soon as it’s ready."
        case .notDownloaded(let engine):
            "\(engine.shortName) isn’t downloaded yet. Download it, or pick another model."
        case .needsKey(let engine):
            "\(engine.shortName) needs an OpenRouter key before you can practice."
        case .ready, .warmingUp:
            ""
        }
    }

    private var action: (title: String, run: () -> Void)? {
        switch readiness {
        case .needsMicrophone:
            ("Allow Microphone", { model.requestMicrophone() })
        case .needsAccessibility:
            ("Open Settings", { model.requestAccessibility() })
        case .notDownloaded(let engine):
            ("Download", { model.download(engine) })
        case .needsKey:
            ("Add Key", { model.go(to: .model) })
        case .downloading, .ready, .warmingUp:
            nil
        }
    }
}

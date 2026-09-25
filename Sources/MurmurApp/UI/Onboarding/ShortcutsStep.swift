import SwiftUI

struct ShortcutsStep: View {
    let model: OnboardingModel

    private var settings: AppSettings { model.ctx.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Two ways to talk",
                       subtitle: "Hold the key for a quick thought, or go hands-free for longer ones. Try it now: the keyboard lights up.")
                .padding(.bottom, 18)

            VStack(spacing: 0) {
                row(.pushToTalk, detail: "Hold, speak, let go.")
                RowDivider(inset: 14)
                row(.handsFree, detail: settings.doublePressForHandsFree
                    ? "Tap to start, tap again to finish. Or double-press \(model.pushToTalkLabel)."
                    : "Tap to start, tap again to finish.")
                RowDivider(inset: 14)
                row(.cancel, detail: "Throw away what you just said.")
                RowDivider(inset: 14)
                row(.pasteLast, detail: "Missed a text field? Paste it again.")
            }
            .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
            .cardShadow()
            .padding(.bottom, 16)

            HStack(spacing: 8) {
                ChecklistChip(title: "Held \(model.pushToTalkLabel)", done: model.heldPushToTalk)
                ChecklistChip(title: "Tried hands-free", done: model.triedHandsFree)
            }

            if model.showKeyboardHint {
                StepNote(symbol: "keyboard", tint: .accent,
                         text: Text("fn not lighting up? Some external keyboards keep fn to themselves. You can pick another key, like right ⌥.")) {
                    Button("Use right ⌥ to talk") {
                        settings.shortcuts[.pushToTalk] = .rightOption
                    }
                    .buttonStyle(QuietButtonStyle(tint: .accent, size: .small))
                    .padding(.leading, -8)
                    .frame(height: 20)
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.expand, value: model.showKeyboardHint)
    }

    private func row(_ action: ShortcutAction, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 8) {
                Text(action == .pasteLast ? "Paste last" : action.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                ShortcutRecorderView(shortcut: binding(for: action), action: action)
                    .layoutPriority(2)
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private func binding(for action: ShortcutAction) -> Binding<Shortcut?> {
        let settings = settings
        return Binding(get: { settings.shortcuts[action] }, set: { settings.shortcuts[action] = $0 })
    }
}

struct ChecklistChip: View {
    var title: String
    var done: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if done {
                    DrawOnCheck(size: 15)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .strokeBorder(Color.inkTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
                        .frame(width: 15, height: 15)
                }
            }
            .frame(width: 15, height: 15)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(done ? Color.ink : Color.inkSecondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 11)
        .frame(height: 28)
        .background(done ? Color.success.opacity(0.10) : Color.ink.opacity(0.04), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).ring(1)
                .fill(done ? Color.success.opacity(0.25) : Color.stroke, style: FillStyle(eoFill: true))
        }
        .animation(.spring(duration: 0.35, bounce: 0.35), value: done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(done ? "\(title), done" : title)
    }
}

// MARK: - Stage

/// A mini pill above a keyboard fragment. Both answer to the physical keys and to the real pill.
struct ShortcutsStage: View {
    let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var stageFocused: Bool

    var body: some View {
        let phase = model.shortcutsPillPhase
        let meter = model.ctx.levelMeter
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            StageClock(paused: !phase.isActive || reduceMotion) { t in
                let live = phase.isRecording && meter.hasReceivedAudio && model.ctx.pillModel.phase.isRecording
                let level = live ? Double(meter.level) : 0.45 + 0.45 * HeroTimeline.voice(t * 0.8)
                ZStack {
                    StageGlow(color: .accent, radius: 110, opacity: phase.isActive ? 0.26 : 0.08)
                    StagePill(phase: phase, level: reduceMotion ? 0.5 : level, time: reduceMotion ? 0 : t)
                        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.28), value: phase)
                }
            }
            .frame(height: 90)
            CoachLine(model: model, phase: phase)
                .frame(height: 44)
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
                .frame(maxHeight: 56)
            KeyboardIllustration(pressed: model.pressedKeys, emphasized: model.pushToTalkKeys.union(model.handsFreeKeys))
                .fixedSize()
                .frame(width: OnboardingLayout.stageWidth - 28, alignment: .leading)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8),
                                           .init(color: .black.opacity(0), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .padding(.leading, 28)
            Spacer(minLength: 0)
        }
        // Trying out fn + space or esc here shouldn't beep: nothing else in this window wants those keys.
        .focusable()
        .focusEffectDisabled()
        .focused($stageFocused)
        .onKeyPress(keys: [.space, .escape]) { _ in .handled }
        .onAppear {
            guard !model.ctx.isPreview else { return }
            Task { @MainActor in stageFocused = true }
        }
    }
}

/// One line of coaching that follows what the user is doing.
private struct CoachLine: View {
    let model: OnboardingModel
    var phase: PillPhase

    private var settings: AppSettings { model.ctx.settings }

    var body: some View {
        let (lead, keys, tail) = message
        HStack(spacing: 6) {
            Text(lead)
            if let keys { ShortcutChips(shortcut: keys, size: .small) }
            if let tail { Text(tail) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.inkSecondary)
        .lineLimit(1)
        .id(lead + (tail ?? ""))
        .transition(.opacity)
        .animation(Theme.Motion.fade, value: lead + (tail ?? ""))
    }

    private var message: (String, Shortcut?, String?) {
        let ptt = settings.shortcuts[.pushToTalk]
        let handsFree = settings.shortcuts[.handsFree]
        switch phase {
        case .listening:
            return model.heldPushToTalk ? ("Listening. Let go when you're done", nil, nil) : ("Keep holding…", nil, nil)
        case .locked:
            return ("Hands-free. Press", ptt, "to finish")
        case .processing:
            return ("Getting your words…", nil, nil)
        case .success:
            return ("Nice.", nil, nil)
        case .error:
            return ("Didn't catch that. Try again", nil, nil)
        case .hidden, .rest:
            if !model.heldPushToTalk { return ("Hold", ptt, "and say something") }
            if !model.triedHandsFree { return ("Now tap", handsFree, "to go hands-free") }
            return ("You've got it.", settings.shortcuts[.cancel], "cancels anytime")
        }
    }
}

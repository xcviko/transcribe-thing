import SwiftUI

struct WelcomeStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppMark(size: 22)
                Text("Murmur")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
            }
            .padding(.bottom, 18)

            Text("Speak.\nIt types.")
                .font(.system(size: 42, weight: .semibold, design: .serif))
                .tracking(-0.8)
                .lineSpacing(-2)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 14)

            Text("Hold \(Text(model.pushToTalkLabel).fontWeight(.semibold).foregroundColor(.ink)), say what you mean, let go. Murmur puts the words wherever your cursor is: any app, any text field.")
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 14) {
                feature("lock.shield.fill", tint: .success, title: "Private by default",
                        detail: "Parakeet runs on your Mac. Your voice never leaves it.")
                feature("macwindow.on.rectangle", tint: .accent, title: "Works everywhere",
                        detail: "Mail, chat, your editor, any text field.")
                feature("text.quote", tint: .warm, title: "Your words, verbatim",
                        detail: "Transcription only. No rewriting, no surprises.")
            }
        }
    }

    private func feature(_ symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hero loop

/// A pill blooms, its bars dance to a synthetic voice and a line types itself into a message above.
struct WelcomeStage: View {
    var shortcut: Shortcut?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let caps = (shortcut ?? .fn).keycaps
        StageClock(fixedTime: reduceMotion ? HeroTimeline.restingFrameTime : nil) { t in
            WelcomeScene(frame: HeroTimeline.frame(at: t), keycaps: caps)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animation: holding fn shows the Murmur pill, and spoken words appear as text.")
    }
}

struct HeroFrame: Equatable {
    var sceneIndex: Int
    var typed: Int
    var textOpacity: Double
    var caretOpacity: Double
    var pillPhase: PillPhase
    var pillSize: CGSize
    var pillScale: Double
    var pillOpacity: Double
    var level: Double
    var checkProgress: Double
    var fnPressed: Bool
    var glow: Double
    var time: Double
}

enum HeroTimeline {
    struct Scene {
        var symbol: String
        var label: String
        var text: String
    }

    static let scenes: [Scene] = [
        Scene(symbol: "bubble.left.fill", label: "Maya", text: "Running ten minutes late, save me a seat by the window?"),
        Scene(symbol: "envelope.fill", label: "Re: Launch plan", text: "Let's push the review to Thursday and ship on Monday."),
        Scene(symbol: "note.text", label: "Groceries", text: "Oat milk, lemons, fresh basil and a good sourdough."),
        Scene(symbol: "bubble.left.fill", label: "Лена", text: "Созвонимся завтра в десять, я пришлю ссылку."),
    ]

    static let period = 5.6
    /// Reduce Motion shows one calm, complete frame.
    static let restingFrameTime = 3.0

    private static let pressAt = 0.3
    private static let bloom = (0.34, 0.66)
    private static let typing = (0.72, 3.0)
    private static let releaseAt = 3.12
    private static let shrink = (3.52, 3.74)
    private static let draw = (3.68, 3.94)
    private static let collapse = (4.36, 4.64)
    private static let fade = (5.05, 5.45)

    static func frame(at t: Double) -> HeroFrame {
        let cycle = Int(t / period)
        let lt = t - Double(cycle) * period
        let scene = scenes[cycle % scenes.count]
        let count = scene.text.count

        let typedProgress = Ease.progress(lt, typing.0, typing.1)
        // Words land in small bursts, like speech.
        let bursty = typedProgress + 0.035 * sin(typedProgress * .pi * 9)
        let typed = Int((Double(count) * Ease.clamp(bursty)).rounded(.down))

        let listening = lt >= bloom.0 && lt < releaseAt
        let processing = lt >= releaseAt && lt < shrink.0
        let success = lt >= shrink.0

        var phase: PillPhase = .hidden
        var size = StagePill.size(for: .listening)
        if listening { phase = .listening }
        if processing { phase = .processing }
        if success {
            phase = .success
            let p = Ease.smooth(Ease.progress(lt, shrink.0, shrink.1))
            size = CGSize(width: Ease.lerp(104, 32, p), height: 32)
        }

        let bloomProgress = Ease.progress(lt, bloom.0, bloom.1)
        let collapseProgress = Ease.progress(lt, collapse.0, collapse.1)
        var scale = Ease.lerp(0.55, 1, Ease.outBack(bloomProgress, overshoot: 1.2))
        scale *= Ease.lerp(1, 0.8, Ease.smooth(collapseProgress))
        let opacity = min(Ease.progress(lt, bloom.0, bloom.0 + 0.14), 1 - Ease.smooth(collapseProgress))

        let rampIn = Ease.progress(lt, bloom.0, bloom.1)
        let rampOut = 1 - Ease.progress(lt, releaseAt - 0.2, releaseAt)
        let level = listening ? voice(lt) * rampIn * max(0.15, rampOut) : 0

        let typingNow = lt >= typing.0 && lt < typing.1
        let blink = (lt * 1.9).truncatingRemainder(dividingBy: 1) < 0.55 ? 1.0 : 0.0
        let textOpacity = 1 - Ease.smooth(Ease.progress(lt, fade.0, fade.1))
        let caret = lt < typing.0 ? (lt > 0.1 ? blink : 0) : (typingNow ? 1 : blink)

        return HeroFrame(
            sceneIndex: cycle % scenes.count,
            typed: typed,
            textOpacity: textOpacity,
            caretOpacity: caret * textOpacity,
            pillPhase: phase,
            pillSize: size,
            pillScale: scale,
            pillOpacity: max(0, opacity),
            level: level,
            checkProgress: Ease.progress(lt, draw.0, draw.1),
            fnPressed: lt >= pressAt && lt < releaseAt,
            glow: listening ? 0.55 + 0.45 * level : (processing ? 0.4 : max(0, 0.4 * (1 - collapseProgress))),
            time: t)
    }

    /// Syllable-ish envelope with word gaps: loud, soft, breath.
    static func voice(_ t: Double) -> Double {
        let syllables = pow(abs(sin(t * 2 * .pi * 2.1)), 0.55)
        let phrase = 0.62 + 0.38 * sin(t * 2 * .pi * 0.43 + 0.8)
        let gap = 1 - 0.7 * pow(max(0, sin(t * 2 * .pi * 0.9 - 1.1)), 12)
        return Ease.clamp(0.16 + 0.84 * syllables * phrase * gap)
    }
}

private struct WelcomeScene: View {
    var frame: HeroFrame
    var keycaps: [Keycap]

    var body: some View {
        let scene = HeroTimeline.scenes[frame.sceneIndex]
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ComposeCard(scene: scene, frame: frame)
                .padding(.horizontal, 36)
            Spacer(minLength: 0)
                .frame(maxHeight: 64)
            ZStack {
                StageGlow(color: .accent, radius: 110, opacity: 0.20 * frame.glow)
                StagePill(phase: frame.pillPhase == .hidden ? .listening : frame.pillPhase,
                          level: frame.level, time: frame.time, checkProgress: frame.checkProgress,
                          size: frame.pillSize)
                    .scaleEffect(frame.pillScale, anchor: .bottom)
                    .opacity(frame.pillOpacity)
            }
            .frame(height: 64)
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                        KeyChip(cap, size: .large, isPressed: frame.fnPressed)
                    }
                }
                Text(frame.fnPressed ? "holding" : "hold to talk")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.inkTertiary)
                    .contentTransition(.opacity)
            }
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }
}

private struct ComposeCard: View {
    var scene: HeroTimeline.Scene
    var frame: HeroFrame

    var body: some View {
        let shown = String(scene.text.prefix(frame.typed))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: scene.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.accent)
                    .frame(width: 22, height: 22)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(scene.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.ink)
                Spacer(minLength: 0)
                Text("now")
                    .font(.system(size: 11))
                    .foregroundStyle(.inkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Rectangle().fill(Color.stroke).frame(height: 1)
            Text("\(Text(verbatim: shown).foregroundColor(.ink))\(Text(verbatim: "|").foregroundColor(Color.accent.opacity(frame.caretOpacity)).fontWeight(.light))")
                .font(.system(size: 15))
                .lineSpacing(4)
                .opacity(frame.textOpacity)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 14)
        }
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1)
        }
        .cardShadow(elevated: true)
    }
}

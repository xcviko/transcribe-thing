import SwiftUI

// MARK: - Frozen time for snapshots

private struct OnboardingStillTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// Snapshots render every looping scene at this time instead of running a timeline.
    var onboardingStillTime: Double? {
        get { self[OnboardingStillTimeKey.self] }
        set { self[OnboardingStillTimeKey.self] = newValue }
    }
}

/// Seconds since the scene appeared, at up to 60 fps, or a fixed time in snapshots.
struct StageClock<Content: View>: View {
    var paused = false
    var framesPerSecond: Double = 60
    /// Used instead of a running clock (snapshots, Reduce Motion).
    var fixedTime: Double?
    @ViewBuilder var content: (Double) -> Content

    @Environment(\.onboardingStillTime) private var stillTime
    @State private var start = Date()

    var body: some View {
        if let time = fixedTime ?? stillTime {
            content(time)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / framesPerSecond, paused: paused)) { context in
                content(max(0, context.date.timeIntervalSince(start)))
            }
        }
    }
}

// MARK: - Easing

enum Ease {
    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }

    /// 0...1 progress of `t` through [a, b].
    static func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }

    static func smooth(_ x: Double) -> Double {
        let c = clamp(x)
        return c * c * (3 - 2 * c)
    }

    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }

    /// Springy overshoot for blooms (settles at 1).
    static func outBack(_ x: Double, overshoot: Double = 1.4) -> Double {
        let c = clamp(x) - 1
        return 1 + c * c * ((overshoot + 1) * c + overshoot)
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

// MARK: - Illustration pill

/// A faithful, time-driven drawing of the transcribe-thing pill for onboarding stages. Pure function of its inputs,
/// so scenes can script it frame by frame and snapshots are deterministic.
struct StagePill: View {
    var phase: PillPhase
    /// 0...1 voice level for the bars.
    var level: Double = 0.6
    /// Scene time in seconds (bar wobble, processing wave).
    var time: Double = 0
    /// 0...1 for the success check.
    var checkProgress: Double = 1
    /// Overrides the phase geometry while a scene morphs between states.
    var size: CGSize?

    static let barCount = 13

    static func size(for phase: PillPhase) -> CGSize {
        switch phase {
        case .hidden, .rest: CGSize(width: 40, height: 10)
        case .listening, .processing, .error: CGSize(width: 104, height: 32)
        case .locked: CGSize(width: 168, height: 36)
        case .success: CGSize(width: 32, height: 32)
        }
    }

    var body: some View {
        let frame = size ?? Self.size(for: phase)
        ZStack {
            PillSurface(isResting: phase == .rest || phase == .hidden)
            content
                .opacity(frame.height >= 24 ? 1 : 0)
        }
        .frame(width: frame.width, height: frame.height)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .hidden, .rest:
            EmptyView()
        case .listening:
            PillBars(level: level, time: time)
        case .locked:
            HStack(spacing: 0) {
                cancelButton
                Spacer(minLength: 0)
                PillBars(level: level, time: time)
                Spacer(minLength: 0)
                stopButton
            }
            .padding(.horizontal, 7)
        case .processing:
            PillProcessingDots(time: time)
        case .success:
            CheckmarkShape()
                .trim(from: 0, to: checkProgress)
                .stroke(Color(nsColor: .hex(0x34C759)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 10)
        case .error:
            Image(systemName: "exclamationmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(nsColor: .hex(0xFF6B5E)))
        }
    }

    private var cancelButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 22, height: 22)
            .background(.white.opacity(0.12), in: Circle())
    }

    private var stopButton: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white)
            .frame(width: 8, height: 8)
            .frame(width: 22, height: 22)
            .background(Color(nsColor: .hex(0xFF453A)), in: Circle())
    }
}

/// Always-dark capsule with a lit top edge and a two-layer shadow (wispr-ux §1.3).
struct PillSurface: View {
    var isResting = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.pillFill)
            .overlay {
                Capsule(style: .continuous).ring(0.75)
                    .fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.07)],
                                         startPoint: .top, endPoint: .bottom), style: FillStyle(eoFill: true))
            }
            .shadow(color: .black.opacity(isResting ? 0.11 : 0.22), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(isResting ? 0.14 : 0.28), radius: 9, x: 0, y: 6)
    }
}

/// 13 bars, centre-weighted, each wobbling at its own pace so they read as a voice, not a meter.
struct PillBars: View {
    var level: Double
    var time: Double
    var color: Color = .white.opacity(0.96)
    var maxHeight: CGFloat = 20

    private static let frequencies: [(Double, Double, Double, Double)] = (0..<StagePill.barCount).map { i in
        let a = Double((i * 37 + 11) % 97) / 97
        let b = Double((i * 53 + 29) % 89) / 89
        return (1.3 + 1.8 * a, 1.3 + 1.8 * b, a * 6.28, b * 6.28)
    }

    static func height(bar i: Int, level: Double, time t: Double, maxHeight: CGFloat) -> CGFloat {
        let centered = Double(i - StagePill.barCount / 2)
        let envelope = 0.35 + 0.65 * pow(cos(.pi * centered / 14), 2)
        let (f1, f2, p1, p2) = frequencies[i]
        let wobble = 0.78 + 0.22 * (0.5 * sin(2 * .pi * f1 * t + p1) + 0.5 * sin(2 * .pi * f2 * t + p2))
        let value = Ease.clamp(level) * envelope * wobble
        return 3 + (maxHeight - 3) * CGFloat(value)
    }

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<StagePill.barCount, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: Self.height(bar: i, level: level, time: time, maxHeight: maxHeight))
            }
        }
        .frame(height: maxHeight)
    }
}

/// Travelling wave of dots while the words are on their way.
struct PillProcessingDots: View {
    var time: Double

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<StagePill.barCount, id: \.self) { i in
                let lift = max(0, sin(2 * .pi * time / 1.1 - Double(i) * 0.45))
                Circle()
                    .fill(.white.opacity(0.45 + 0.5 * lift))
                    .frame(width: 3, height: 3)
                    .offset(y: -3 * lift)
            }
        }
    }
}

// MARK: - Check

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Green disc whose check draws on when it appears (instantly in snapshots and under Reduce Motion).
struct DrawOnCheck: View {
    var size: CGFloat = 16
    var tint: Color = .success
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingStillTime) private var stillTime
    @State private var progress: CGFloat = 0
    @State private var disc: CGFloat = 0

    var body: some View {
        let still = !animated || reduceMotion || stillTime != nil
        ZStack {
            Circle().fill(tint)
                .scaleEffect(still ? 1 : disc)
            CheckmarkShape()
                .trim(from: 0, to: still ? 1 : progress)
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.5, size * 0.12), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.46, height: size * 0.36)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !still else { return }
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) { disc = 1 }
            withAnimation(.easeOut(duration: 0.32).delay(0.12)) { progress = 1 }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - App mark

/// transcribe-thing's mark drawn in code: iris squircle, white capsule, five bars.
struct AppMark: View {
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(nsColor: .hex(0x2A2358)), Color(nsColor: .hex(0x5B4FE0)),
                                               Color(nsColor: .hex(0x8F86FF))],
                                      startPoint: .bottomLeading, endPoint: .topTrailing))
            shape.fill(RadialGradient(colors: [.white.opacity(0.28), .clear], center: .topTrailing,
                                      startRadius: 0, endRadius: size * 0.9))
            Capsule(style: .continuous)
                .fill(.white)
                .frame(width: size * 0.62, height: size * 0.3)
                .overlay {
                    HStack(spacing: size * 0.035) {
                        ForEach([0.35, 0.7, 1.0, 0.62, 0.3], id: \.self) { h in
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .hex(0x3B2FB8)))
                                .frame(width: size * 0.045, height: size * 0.19 * h)
                        }
                    }
                }
                .shadow(color: Color(nsColor: .hex(0x8F86FF)).opacity(0.7), radius: size * 0.08)
            shape.strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size / 64))
        }
        .frame(width: size, height: size)
        .shadow(color: Color(nsColor: .hex(0x3B2FB8)).opacity(0.28), radius: size * 0.12, x: 0, y: size * 0.06)
        .accessibilityHidden(true)
    }
}

// MARK: - Stage container

/// The warm, airy illustration panel on the right of most steps.
struct OnboardingStage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            StageBackground(cornerRadius: 22)
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// A soft glow disc used behind hero elements.
struct StageGlow: View {
    var color: Color = .accent
    var radius: CGFloat = 120
    var opacity: Double = 0.22

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)], center: .center,
                                 startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

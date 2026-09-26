import SwiftUI

/// Thirteen center-weighted bars driven by the live level (wispr-ux §1.4). Honest by design: before the first
/// audio buffer the bars are dim "connecting" dots, and after 1.5 s of silence they breathe instead of faking
/// a waveform. The timeline only exists while this view is on screen, so an idle pill costs nothing.
struct WaveformView: View {
    let meter: LevelMeter
    var maxBarHeight: CGFloat = PillMetrics.barMaxHeight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pillStaticRendering) private var isStatic
    @State private var engine = WaveformEngine()

    var body: some View {
        // 60 fps cap: 120 Hz costs ~40% more CPU for no visible gain (macos-app §4).
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isStatic)) { timeline in
            let date = timeline.date
            Canvas(rendersAsynchronously: false) { context, size in
                engine.draw(in: &context, size: size, date: date, meter: meter,
                            reduceMotion: reduceMotion, isStatic: isStatic)
            }
        }
        .frame(width: PillMetrics.barFieldWidth, height: maxBarHeight)
        .accessibilityHidden(true)
    }
}

/// Per-frame state lives in a reference type so advancing it never invalidates the view.
final class WaveformEngine {
    private var smoothed: CGFloat = 0
    private var silenceBlend: CGFloat = 0
    private var lastTime: TimeInterval?
    private let f1: [Double]
    private let f2: [Double]
    private let p1: [Double]
    private let p2: [Double]

    init() {
        // Fixed pseudo-random wobble per bar (1.3–3.1 Hz) so the bars never move in lockstep.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let n = PillMetrics.barCount
        var f1 = [Double](), f2 = [Double](), p1 = [Double](), p2 = [Double]()
        for _ in 0..<n {
            f1.append(1.3 + 1.8 * next())
            f2.append(1.3 + 1.8 * next())
            p1.append(2 * .pi * next())
            p2.append(2 * .pi * next())
        }
        (self.f1, self.f2, self.p1, self.p2) = (f1, f2, p1, p2)
    }

    /// Center weighting: env(i) = 0.35 + 0.65 · cos²(π(i − 6)/14).
    static func envelope(_ i: Int) -> CGFloat {
        let c = cos(Double.pi * Double(i - PillMetrics.barCount / 2) / 14)
        return CGFloat(0.35 + 0.65 * c * c)
    }

    func draw(in context: inout GraphicsContext, size: CGSize, date: Date, meter: LevelMeter,
              reduceMotion: Bool, isStatic: Bool) {
        let t = date.timeIntervalSinceReferenceDate
        let dt = lastTime.map { min(0.1, max(0, t - $0)) } ?? (1.0 / 60)
        lastTime = t

        let hasAudio = meter.hasReceivedAudio
        let target = CGFloat(min(max(meter.level, 0), 1))
        if isStatic {
            smoothed = target
        } else {
            // The meter already smooths (attack 40 ms / release 140 ms); this only interpolates its ~10 Hz steps.
            let tau: CGFloat = target > smoothed ? 0.025 : 0.08
            smoothed += (target - smoothed) * (1 - exp(-CGFloat(dt) / tau))
        }
        let silent = hasAudio && meter.secondsSinceVoice > 1.5 && smoothed < 0.12
        let silenceTarget: CGFloat = silent && !reduceMotion ? 1 : 0
        silenceBlend = isStatic ? silenceTarget : silenceBlend + (silenceTarget - silenceBlend) * (1 - exp(-CGFloat(dt) / 0.3))

        let w = PillMetrics.barWidth
        let step = w + PillMetrics.barGap
        let minH = PillMetrics.barMinHeight
        let maxH = size.height
        let midY = size.height / 2

        for i in 0..<PillMetrics.barCount {
            let x = CGFloat(i) * step
            if !hasAudio {
                // Connecting: a slow ripple of dim dots, never a fake waveform.
                let ripple = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(2 * .pi * t / 1.4 - 0.5 * Double(i))
                let rect = CGRect(x: x, y: midY - minH / 2, width: w, height: minH)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.24 + 0.3 * ripple)))
                continue
            }
            let wobble = reduceMotion ? 1 : 0.78 + 0.22 * (0.5 * sin(2 * .pi * f1[i] * t + p1[i])
                                                        + 0.5 * sin(2 * .pi * f2[i] * t + p2[i]))
            let h = minH + (maxH - minH) * smoothed * Self.envelope(i) * CGFloat(wobble)
            let lift = min(1, (h - minH) / 5)
            let opacity = 0.45 + 0.51 * Double(lift)
            if h <= minH + 0.4 {
                // Silence: dots breathe left to right (scale 1 → 1.3, 2.4 s period) to show the mic is live.
                let breathe = 0.5 + 0.5 * sin(2 * .pi * t / 2.4 - 0.35 * Double(i))
                let d = minH * (1 + 0.3 * CGFloat(breathe) * silenceBlend)
                let rect = CGRect(x: x + w / 2 - d / 2, y: midY - d / 2, width: d, height: d)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.45 + 0.12 * breathe * Double(silenceBlend))))
            } else {
                let rect = CGRect(x: x, y: midY - h / 2, width: w, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(.white.opacity(opacity)))
            }
        }
    }
}

/// Processing: the dots travel as a wave (y = −3 · max(0, sin(2πt/1.1 − 0.45 i))) under a soft shimmer that
/// sweeps the capsule every 1.4 s. Reduce Motion swaps both for a 1 Hz opacity pulse.
struct ProcessingWaveView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pillStaticRendering) private var isStatic
    @State private var appearedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isStatic)) { timeline in
            let date = timeline.date
            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size, date: date)
            }
        }
        .onAppear { appearedAt = Date() }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, date: Date) {
        // Static snapshots freeze a pleasant mid-wave moment.
        let t = isStatic ? 0.62 : date.timeIntervalSince(appearedAt)
        // Bars settle into dots over 140 ms, then the wave swells in.
        let ramp = isStatic ? 1 : min(1, max(0, (t - 0.14) / 0.3))

        let w = PillMetrics.barWidth
        let step = w + PillMetrics.barGap
        let originX = (size.width - PillMetrics.barFieldWidth) / 2
        let midY = size.height / 2

        if !reduceMotion {
            // A glint travels along the lit upper rim every 1.4 s, with the faintest wash inside.
            let phase = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
            let band = size.width * 0.42
            let centerX = -band / 2 + (size.width + band) * phase
            let bounds = CGRect(origin: .zero, size: size)
            func sweep(_ peak: Double) -> GraphicsContext.Shading {
                .linearGradient(Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(peak * ramp), location: 0.5),
                    .init(color: .white.opacity(0), location: 1),
                ]), startPoint: CGPoint(x: centerX - band / 2, y: 0), endPoint: CGPoint(x: centerX + band / 2, y: 0))
            }
            var rim = Path()
            rim.addPath(Capsule(style: .continuous).path(in: bounds))
            rim.addPath(Capsule(style: .continuous).path(in: bounds.insetBy(dx: 0.8, dy: 0.8)))
            var upper = context
            upper.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.62)))
            upper.fill(rim, with: sweep(0.5), style: FillStyle(eoFill: true))
            var inside = context
            inside.clip(to: Capsule(style: .continuous).path(in: bounds))
            inside.fill(Path(bounds), with: sweep(0.035))
        }

        for i in 0..<PillMetrics.barCount {
            let x = originX + CGFloat(i) * step
            let lift: Double
            let opacity: Double
            if reduceMotion {
                lift = 0
                opacity = 0.45 + 0.4 * (0.5 + 0.5 * sin(2 * .pi * t))
            } else {
                lift = max(0, sin(2 * .pi * t / 1.1 - 0.45 * Double(i))) * ramp
                opacity = 0.5 + 0.46 * lift
            }
            let rect = CGRect(x: x, y: midY - w / 2 - 3 * lift, width: w, height: w)
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
        }
    }
}

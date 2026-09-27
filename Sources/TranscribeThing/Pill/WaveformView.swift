import SwiftUI

/// The voice as a Telegram-style scrolling amplitude history (wispr-ux §1.4), like debilgpt's composer: the
/// field starts empty, and every 87 ms the voice-gated amplitude lands at the right edge as a new column: a dim
/// dot when nobody speaks, a bar rising out of that dot when someone does. The whole history glides left at one
/// slot per column for as long as the recording lasts, filling the field from the right, and the oldest column
/// fades out past the left edge. Honest by design: nothing is drawn before the first audio buffer, and anything
/// that isn't speech (room noise, a fan, a key click) is dots. The timeline only exists while this view is on
/// screen, so an idle pill costs nothing.
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
                // Capturing the date redraws the canvas every frame; the engine itself runs on the meter's clock.
                _ = date
                engine.draw(in: &context, size: size, meter: meter, reduceMotion: reduceMotion, isStatic: isStatic)
            }
        }
        .frame(width: PillMetrics.barFieldWidth, height: maxBarHeight)
        .accessibilityHidden(true)
    }
}

/// History state lives in a reference type so advancing it never invalidates the view. The geometry is a pure
/// function of the meter's clock and the recorded columns, so a dropped frame never makes the bars jump.
final class WaveformEngine {
    /// A new column every 87 ms: ~11 bars a second reads as speech, not as a meter.
    static let columnInterval: TimeInterval = 0.087
    /// A voiced column rises out of its dot to its height over this long (ease-out).
    static let growDuration: TimeInterval = 0.1
    /// A column fades in at the right edge over this long as it lands (while a voiced one grows), so it never pops
    /// into view.
    static let appearDuration: TimeInterval = growDuration
    /// Static snapshots freeze the preview voice at this moment: a pause, then a phrase.
    static let staticTime: TimeInterval = 4.2
    /// One column per slot; the oldest glides out past the left edge while the next one lands.
    static var columnCount: Int { PillMetrics.barCount }

    struct Bar: Equatable {
        var rect: CGRect
        var opacity: Double
    }

    /// Amplitudes 0...1, newest first.
    private(set) var columns = [CGFloat](repeating: 0, count: WaveformEngine.columnCount)
    /// How many of the newest columns have landed since the recording started: the field fills from the right,
    /// and nothing stands left of them.
    private(set) var filled = 0
    /// How each column's height eases toward its amplitude, newest first. A new column grows from a dot at its
    /// landing; one whose audio fills in or changes later eases from where it stands at that frame, so no bar
    /// ever pops.
    private var eases = [Ease](repeating: Ease(from: 0, light: 0, start: -.infinity),
                               count: WaveformEngine.columnCount)
    /// Meter time at which the newest column's audio ends (and it landed).
    private(set) var newestEnd: TimeInterval?
    /// The newest columns whose audio isn't final yet (a late chunk, or an onset the gate hasn't confirmed):
    /// they are read again every frame until the meter settles them, instead of freezing as dots.
    private var unsettled = 0

    private struct Ease {
        /// Amplitude the height eases from (0 for a dot).
        var from: CGFloat
        /// Amplitude the brightness eases from. It runs linearly rather than easing out like the height, so
        /// a dot filling in with a loud bar brightens over a few frames instead of in one.
        var light: CGFloat
        /// Meter time it starts.
        var start: TimeInterval
    }

    /// Starts an empty field at `now` (meter time): the first column lands `columnInterval` later.
    func start(at now: TimeInterval) {
        newestEnd = now
        filled = 0
        unsettled = 0
        columns = Array(repeating: 0, count: Self.columnCount)
        eases = Array(repeating: Ease(from: 0, light: 0, start: -.infinity), count: Self.columnCount)
    }

    /// Rebuilds a full field from the meter, the newest column landing at `now`: snapshots, and a return from a
    /// stall longer than the history.
    func fill(meter: LevelMeter, at now: TimeInterval) {
        start(at: now)
        filled = Self.columnCount
        unsettled = Self.columnCount
        eases = (0..<Self.columnCount).map { Ease(from: 0, light: 0, start: now - Double($0) * Self.columnInterval) }
        settle(meter: meter, now: now, landed: Self.columnCount)
    }

    /// Lands the columns whose audio has ended by `now` (meter time). The first call starts an empty field, as
    /// does a clock that went backwards; a stall longer than the history rebuilds it from the meter.
    func advance(meter: LevelMeter, to now: TimeInterval) {
        let interval = Self.columnInterval
        guard let end = newestEnd, now >= end - 0.5 else { return start(at: now) }
        guard now - end < interval * Double(Self.columnCount) else { return fill(meter: meter, at: now) }
        var newest = end
        var landed = 0
        while now >= newest + interval {
            newest += interval
            landed += 1
            columns.removeLast()
            columns.insert(0, at: 0)
            eases.removeLast()
            eases.insert(Ease(from: 0, light: 0, start: newest), at: 0)
            filled = min(Self.columnCount, filled + 1)
            unsettled = min(Self.columnCount, unsettled + 1)
        }
        newestEnd = newest
        settle(meter: meter, now: now, landed: landed)
    }

    /// Reads the unsettled columns. A column already on screen (not one of the `landed` newest) that changes
    /// eases from its height and brightness at `now`.
    private func settle(meter: LevelMeter, now: TimeInterval, landed: Int) {
        guard unsettled > 0, let newest = newestEnd else { return }
        let settledTime = meter.settledTime ?? -.infinity
        var open = 0
        for k in 0..<unsettled {
            let end = newest - Double(k) * Self.columnInterval
            let value = CGFloat(meter.voiceAmplitude(from: end - Self.columnInterval, to: end))
            if value != columns[k] {
                if k >= landed { eases[k] = Ease(from: amplitude(k, at: now), light: light(k, at: now), start: now) }
                columns[k] = value
            }
            if end > settledTime { open = k + 1 }
        }
        unsettled = open
    }

    /// How far column k's ease has run at `now`, 0...1.
    private func progress(_ k: Int, at now: TimeInterval) -> CGFloat {
        CGFloat(min(1, max(0, (now - eases[k].start) / Self.growDuration)))
    }

    /// Column k's drawn height as an amplitude at `now`: its ease, cubic ease-out over `growDuration`.
    private func amplitude(_ k: Int, at now: TimeInterval) -> CGFloat {
        eases[k].from + (columns[k] - eases[k].from) * (1 - pow(1 - progress(k, at: now), 3))
    }

    /// The amplitude column k's brightness follows at `now`: the same ease, run linearly.
    private func light(_ k: Int, at now: TimeInterval) -> CGFloat {
        eases[k].light + (columns[k] - eases[k].light) * progress(k, at: now)
    }

    /// How far a bar of `amplitude` stands above a dot, 0...1 over its first 5 pt in the pill's field.
    private static func lift(_ amplitude: CGFloat) -> CGFloat {
        min(1, amplitude * (PillMetrics.barMaxHeight - PillMetrics.barMinHeight) / 5)
    }

    /// Geometry at `now` for a field of `size`, one shape per landed column, newest first. Column k sits k +
    /// phase slots left of the rightmost one, the phase running 0 → 1 between landings, so the whole history
    /// glides left at one slot per column and never stops; Reduce Motion and snapshots step a whole slot at a
    /// time, fully grown. A dot is dim and a bar brightens with its height.
    func bars(size: CGSize, now: TimeInterval, reduceMotion: Bool, isStatic: Bool) -> [Bar] {
        guard let newest = newestEnd else { return [] }
        let w = PillMetrics.barWidth
        let step = w + PillMetrics.barGap
        let minH = PillMetrics.barMinHeight
        let midY = size.height / 2
        let settled = reduceMotion || isStatic
        let phase = settled ? 0 : CGFloat(min(1, max(0, (now - newest) / Self.columnInterval)))

        var bars: [Bar] = []
        bars.reserveCapacity(filled)
        for k in 0..<filled {
            let x = size.width - w - (CGFloat(k) + phase) * step
            guard x > -w else { continue }
            let h = minH + (size.height - minH) * (settled ? columns[k] : amplitude(k, at: now))
            let lift = Self.lift(settled ? columns[k] : light(k, at: now))
            let landing = newest - Double(k) * Self.columnInterval
            let appear = settled ? 1 : min(1, max(0, (now - landing) / Self.appearDuration))
            // The history dissolves over its last two steps on the left.
            let tail = min(1, max(0, (x + step) / (2 * step)))
            let opacity = (0.45 + 0.51 * Double(lift)) * appear * Double(tail)
            guard opacity > 0 else { continue }
            bars.append(Bar(rect: CGRect(x: x, y: midY - h / 2, width: w, height: h), opacity: opacity))
        }
        return bars
    }

    /// The frame at `now` (meter time): nothing before the first audio buffer, or after the meter was reset for
    /// a new recording, so the next one starts empty too. Snapshots show a full field.
    func frame(size: CGSize, meter: LevelMeter, now: TimeInterval, reduceMotion: Bool, isStatic: Bool) -> [Bar] {
        guard meter.hasReceivedAudio else {
            newestEnd = nil
            return []
        }
        if isStatic { fill(meter: meter, at: now) } else { advance(meter: meter, to: now) }
        return bars(size: size, now: now, reduceMotion: reduceMotion, isStatic: isStatic)
    }

    func draw(in context: inout GraphicsContext, size: CGSize, meter: LevelMeter, reduceMotion: Bool, isStatic: Bool) {
        let now = isStatic ? Self.staticTime : meter.readTime
        let radius = PillMetrics.barWidth / 2
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        for bar in frame(size: size, meter: meter, now: now, reduceMotion: reduceMotion, isStatic: isStatic) {
            context.fill(Path(roundedRect: bar.rect, cornerRadius: radius), with: .color(.white.opacity(bar.opacity)))
        }
    }
}

/// Processing: the dots travel as a wave (y = −3 · max(0, sin(2πt/1.1 − 0.45 i))) under a soft shimmer that
/// sweeps the capsule every 1.4 s. Reduce Motion swaps both for a 1 Hz opacity pulse.
struct ProcessingWaveView: View {
    /// Where the recording bars stood, relative to the center (hands-free keeps them left of the timer): the
    /// dots appear there, so they don't hop sideways in the crossfade, then glide to the center.
    var startOffset: CGFloat = 0

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

    /// Glide from `startOffset` to the center: it waits out the crossfade's first 60 ms, then eases over 0.4 s
    /// while the wave swells in.
    static let glide: ClosedRange<TimeInterval> = 0.06 ... 0.46

    /// X center of the dot row, `time` seconds after the view appeared in a field `width` wide. Reduce Motion
    /// crossfades straight to the center (an opacity-only swap), so the dots never sit off-center.
    static func dotsCenterX(width: CGFloat, time: TimeInterval, startOffset: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return width / 2 }
        let u = CGFloat(min(1, max(0, (time - glide.lowerBound) / (glide.upperBound - glide.lowerBound))))
        return width / 2 + startOffset * (1 - u * u * (3 - 2 * u))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, date: Date) {
        // Static snapshots freeze a pleasant mid-wave moment.
        let t = isStatic ? 0.62 : date.timeIntervalSince(appearedAt)
        // Bars settle into dots over 140 ms, then the wave swells in.
        let ramp = isStatic ? 1 : min(1, max(0, (t - 0.14) / 0.3))

        let w = PillMetrics.barWidth
        let step = w + PillMetrics.barGap
        let originX = Self.dotsCenterX(width: size.width, time: t, startOffset: startOffset, reduceMotion: reduceMotion)
            - PillMetrics.barFieldWidth / 2
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

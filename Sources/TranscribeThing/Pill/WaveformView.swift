import SwiftUI

/// The voice as a Telegram-style scrolling amplitude history (wispr-ux §1.4): every 87 ms the
/// voice-gated amplitude becomes a new bar that grows in at the right edge while older ones drift left and
/// fade out. Honest by design: before the first audio buffer the bars are dim "connecting" dots, and anything
/// that isn't speech (room noise, a fan, a key click) is perfectly still dots. The timeline only exists while
/// this view is on screen, so an idle pill costs nothing.
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

/// History state lives in a reference type so advancing it never invalidates the view. The geometry is a pure
/// function of the meter's clock and the recorded columns, so a dropped frame never makes the bars jump.
final class WaveformEngine {
    /// A new column every 87 ms: ~11 bars a second reads as speech, not as a meter.
    static let columnInterval: TimeInterval = 0.087
    /// A new column lands at the right edge as a dot and grows to its height over this long (ease-out).
    static let growDuration: TimeInterval = 0.1
    /// Static snapshots freeze the preview voice at this moment: a pause, then a phrase.
    static let staticTime: TimeInterval = 4.2
    /// One column per bar slot; the oldest slides out past the left edge while the next one lands.
    static var columnCount: Int { PillMetrics.barCount }
    /// Columns kept: one more than the slots, so a row that trails its slide (see `slideLag`) still has its
    /// oldest dot standing at the left edge when the next column lands, instead of dropping it in view.
    static var storedCount: Int { columnCount + 1 }
    /// A row that starts sliding between landings eases into the pace over this long (see `slideLag`).
    static let lagDuration: TimeInterval = 0.4

    struct Bar: Equatable {
        var rect: CGRect
        var opacity: Double
    }

    /// Amplitudes 0...1, newest first.
    private(set) var columns = [CGFloat](repeating: 0, count: WaveformEngine.storedCount)
    /// How each column's height eases toward its amplitude, newest first. A new column grows from a dot at its
    /// landing; one whose audio fills in or changes later eases from where it stands at that frame, so no bar
    /// ever pops.
    private var eases = [Ease](repeating: Ease(from: 0, start: -.infinity), count: WaveformEngine.storedCount)
    /// Meter time at which the newest column's audio ends (and it landed).
    private(set) var newestEnd: TimeInterval?
    /// Whether the columns slide this interval: only while a voiced column is on screen, so silence is a
    /// fixed row of dots rather than a drifting one. Decided when a column lands, where the slide offset is 0
    /// either way, so starting or stopping never jumps; a late fill-in starts it in between (see `slideLag`).
    private var isScrolling = false
    /// A late fill-in starts the slide mid-interval, where the offset is already part of a step: the row trails
    /// its nominal position by `slideLag` steps then, easing it out over `lagDuration` from `slideLagStart`, so
    /// it sets off from where it stands instead of jumping sideways.
    private var slideLag: CGFloat = 0
    private var slideLagStart: TimeInterval = 0
    /// The newest columns whose audio isn't final yet (a late chunk, or an onset the gate hasn't confirmed):
    /// they are read again every frame until the meter settles them, instead of freezing as dots.
    private var unsettled = 0

    private struct Ease {
        /// Amplitude the ease starts from (0 for a dot).
        var from: CGFloat
        /// Meter time it starts.
        var start: TimeInterval
    }

    /// Records the columns whose audio has ended by `now` (meter time). Rebuilds the history from the meter
    /// on the first frame, after a stall longer than the history, or when the clock went backwards.
    func advance(meter: LevelMeter, to now: TimeInterval) {
        let interval = Self.columnInterval
        guard let end = newestEnd, now >= end - 0.5, now - end < interval * Double(Self.columnCount) else {
            newestEnd = now
            unsettled = Self.columnCount
            eases = (0..<Self.storedCount).map { Ease(from: 0, start: now - Double($0) * interval) }
            settle(meter: meter, now: now, landed: Self.columnCount)
            isScrolling = hasVoiceInView
            slideLag = 0
            return
        }
        var newest = end
        var landed = 0
        while now >= newest + interval {
            newest += interval
            landed += 1
            columns.removeLast()
            columns.insert(0, at: 0)
            eases.removeLast()
            eases.insert(Ease(from: 0, start: newest), at: 0)
            unsettled = min(Self.columnCount, unsettled + 1)
        }
        if landed > 0 {
            newestEnd = newest
            settle(meter: meter, now: now, landed: landed)
            // Stopping waits for the lag to run out, so the row comes to rest exactly on the slots.
            isScrolling = hasVoiceInView || lag(at: newest) > 0
        } else if settle(meter: meter, now: now, landed: 0), !isScrolling {
            // Voice filled in a still row between landings: slide from now on, from where the row stands.
            isScrolling = true
            slideLag = CGFloat(min(1, max(0, (now - end) / interval)))
            slideLagStart = now
        }
    }

    /// A voiced column in one of the slots: the extra one is past the left edge whenever the row keeps pace.
    private var hasVoiceInView: Bool { columns.prefix(Self.columnCount).contains { $0 > 0 } }

    /// Reads the unsettled columns; true when one of them rose from a dot. A column already on screen (not one
    /// of the `landed` newest) that changes eases from its height at `now`.
    @discardableResult
    private func settle(meter: LevelMeter, now: TimeInterval, landed: Int) -> Bool {
        guard unsettled > 0, let newest = newestEnd else { return false }
        let settledTime = meter.settledTime ?? -.infinity
        var rose = false
        var open = 0
        for k in 0..<unsettled {
            let end = newest - Double(k) * Self.columnInterval
            let value = CGFloat(meter.voiceAmplitude(from: end - Self.columnInterval, to: end))
            if value != columns[k] {
                if value > 0, columns[k] == 0 { rose = true }
                if k >= landed { eases[k] = Ease(from: amplitude(k, at: now), start: now) }
                columns[k] = value
            }
            if end > settledTime { open = k + 1 }
        }
        unsettled = open
        return rose
    }

    /// Column k's drawn amplitude at `now`: its ease, cubic ease-out over `growDuration`.
    private func amplitude(_ k: Int, at now: TimeInterval) -> CGFloat {
        let p = CGFloat(min(1, max(0, (now - eases[k].start) / Self.growDuration)))
        return eases[k].from + (columns[k] - eases[k].from) * (1 - pow(1 - p, 3))
    }

    /// Steps the row still trails its nominal slide at `now`: the lag runs out along a smoothstep, so the row
    /// sets off at the normal pace like after a landing, speeds up a little mid-way and settles without a kink.
    private func lag(at now: TimeInterval) -> CGFloat {
        guard slideLag > 0 else { return 0 }
        let u = CGFloat(min(1, max(0, (now - slideLagStart) / Self.lagDuration)))
        return slideLag * (1 - u * u * (3 - 2 * u))
    }

    /// Bar geometry at `now` for a field of `size`. Column k sits k + offset steps left of the rightmost slot,
    /// the offset running 0 → 1 between landings, so the history drifts left at one step per column.
    func bars(size: CGSize, now: TimeInterval, reduceMotion: Bool, isStatic: Bool) -> [Bar] {
        let w = PillMetrics.barWidth
        let step = w + PillMetrics.barGap
        let minH = PillMetrics.barMinHeight
        let midY = size.height / 2
        let end = newestEnd ?? now
        // Reduce Motion and snapshots step a whole column at a time, fully grown.
        let settled = reduceMotion || isStatic
        let phase = CGFloat(min(1, max(0, (now - end) / Self.columnInterval)))
        let offset: CGFloat = settled || !isScrolling ? 0 : phase - lag(at: now)

        var bars: [Bar] = []
        bars.reserveCapacity(columns.count)
        for k in columns.indices {
            let x = size.width - w - (CGFloat(k) + offset) * step
            guard x > -w else { continue }
            let h = minH + (size.height - minH) * (settled ? columns[k] : amplitude(k, at: now))
            let lift = min(1, (h - minH) / 5)
            // The history dissolves over its last two steps on the left.
            let tail = min(1, max(0, (x + step) / (2 * step)))
            let opacity = (0.45 + 0.51 * Double(lift)) * Double(tail)
            bars.append(Bar(rect: CGRect(x: x, y: midY - h / 2, width: w, height: h), opacity: opacity))
        }
        return bars
    }

    func draw(in context: inout GraphicsContext, size: CGSize, date: Date, meter: LevelMeter,
              reduceMotion: Bool, isStatic: Bool) {
        let w = PillMetrics.barWidth
        guard meter.hasReceivedAudio else {
            // Connecting: a slow ripple of dim dots, never a fake waveform. Snapshots freeze it at one phase.
            let t = isStatic ? Self.staticTime : date.timeIntervalSinceReferenceDate
            let minH = PillMetrics.barMinHeight
            for i in 0..<PillMetrics.barCount {
                let ripple = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(2 * .pi * t / 1.4 - 0.5 * Double(i))
                let rect = CGRect(x: CGFloat(i) * (w + PillMetrics.barGap), y: size.height / 2 - minH / 2,
                                  width: w, height: minH)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.24 + 0.3 * ripple)))
            }
            return
        }

        let now = isStatic ? Self.staticTime : meter.readTime
        if isStatic { newestEnd = nil }
        advance(meter: meter, to: now)
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        for bar in bars(size: size, now: now, reduceMotion: reduceMotion, isStatic: isStatic) {
            context.fill(Path(roundedRect: bar.rect, cornerRadius: w / 2), with: .color(.white.opacity(bar.opacity)))
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

import SwiftUI

// MARK: - Logic

/// What the call page's waveform shows: a bar every 4 pt across its width, each in the color of whoever speaks at its
/// time (as their name is in the transcript), gray where nobody does, as tall as the call is loud there
/// (`CallPeaks`). Before the loudness is read, the bars are flat: taller where someone speaks.
enum CallWaveform {
    /// Points from one bar to the next, and a bar's width.
    static let step: CGFloat = 4
    static let barWidth: CGFloat = 2.4
    /// The bars' track; the playhead stands out of it by `overhang` above and below.
    static let trackHeight: CGFloat = 64
    static let overhang: CGFloat = 4
    static let minimumBars = 24
    /// Heights before the loudness is known: where someone speaks, where nobody does.
    static let flatSpeech: Float = 0.42
    static let flatSilence: Float = 0.06

    /// Whose a bar is.
    enum Tone: Hashable {
        /// Nobody speaks then.
        case silence
        /// Not transcribed (yet): who speaks isn't known.
        case unknown
        case speaker(CallSpeakerSlot?, muted: Bool)
    }

    /// How many bars fit `width`.
    static func barCount(width: CGFloat) -> Int {
        max(minimumBars, Int((width / step).rounded(.down)))
    }

    /// The phrase being said at `time`: the one that covers it (from its start, up to its end), the one that started
    /// last when phrases overlap. A phrase without an end (an end not after its start) lasts until the next one starts.
    static func segment(at time: TimeInterval, in segments: [CallTranscript.Segment]) -> CallTranscript.Segment? {
        self.segments(at: [time], in: segments)[0]
    }

    /// `segment(at:in:)` for each of `times`, which go up: one sweep through the phrases.
    static func segments(at times: [TimeInterval],
                         in segments: [CallTranscript.Segment]) -> [CallTranscript.Segment?] {
        // By start, in transcript order among equal starts: the later of two that started together wins.
        let sorted = segments.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        let ends: [TimeInterval] = sorted.indices.map { index in
            let segment = sorted[index]
            if segment.end > segment.start { return segment.end }
            return sorted[(index + 1)...].first { $0.start > segment.start }?.start ?? .infinity
        }
        var next = 0
        /// Started by now and maybe not ended, by start.
        var open: [Int] = []
        return times.map { time in
            while next < sorted.count, sorted[next].start <= time {
                open.append(next)
                next += 1
            }
            open.removeAll { ends[$0] <= time }
            return open.last.map { sorted[$0] }
        }
    }

    /// Each of `count` bars' tone, at the middle of its stretch of a call `duration` long.
    static func tones(count: Int, duration: TimeInterval, transcript: CallTranscript?) -> [Tone] {
        guard count > 0 else { return [] }
        guard let transcript else { return [Tone](repeating: .unknown, count: count) }
        guard !transcript.segments.isEmpty, duration > 0 else { return [Tone](repeating: .silence, count: count) }
        let slots = CallSpeakerPalette.slots(transcript)
        let times = (0..<count).map { (Double($0) + 0.5) / Double(count) * duration }
        return segments(at: times, in: transcript.segments).map { segment in
            segment.map { .speaker(slots[$0.speaker], muted: $0.duringMute) } ?? .silence
        }
    }

    /// The bars' heights, 0...1: from the loudness once it's known, else flat by who speaks.
    static func heights(tones: [Tone], peaks: CallPeaks?, duration: TimeInterval) -> [Float] {
        if let peaks { return peaks.bars(tones.count, duration: duration) }
        return flat(tones)
    }

    static func flat(_ tones: [Tone]) -> [Float] {
        tones.map { if case .speaker = $0 { flatSpeech } else { flatSilence } }
    }

    /// The speakers the legend names, in the order they first speak, each with their color.
    static func legend(_ call: CallRecord) -> [(speaker: String, name: String, slot: CallSpeakerSlot?)] {
        guard let transcript = call.transcript else { return [] }
        let slots = CallSpeakerPalette.slots(transcript)
        return transcript.speakers.map { ($0, call.name(of: $0), slots[$0]) }
    }

    static func color(_ tone: Tone) -> Color {
        switch tone {
        // The ink, faint: a hairline gray in light and dark that still shows at the unplayed part's opacity.
        case .silence: Color.ink.opacity(0.22)
        // A call's sound before its transcript: gray, but as plain as speech.
        case .unknown: Color.inkTertiary
        case let .speaker(slot, muted): CallSpeakerColors.color(slot).opacity(muted ? 0.45 : 1)
        }
    }
}

// MARK: - View

/// The call as bars in its speakers' colors, played part bright, the rest faint, a playhead between. A click or a drag
/// moves it (the first click plays), and the arrows skip 5 seconds; to VoiceOver, it's a slider.
struct CallWaveformView: View {
    var call: CallRecord
    var player: CallPlayer
    /// The loudness, once read; nil: flat bars.
    var peaks: CallPeaks?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where it's held while dragged; the player moves on release.
    @Binding var scrubbing: Double?
    /// 0: flat, 1: as loud as the call is; between, while the bars grow.
    @State private var grown: Double = 0
    @State private var hoverX: CGFloat?
    @State private var width: CGFloat = 0
    @FocusState private var focused: Bool

    private var duration: TimeInterval { max(player.duration, 0.001) }

    var body: some View {
        let count = CallWaveform.barCount(width: width)
        let tones = CallWaveform.tones(count: count, duration: player.duration, transcript: call.transcript)
        let heights = peaks.map { $0.bars(count, duration: player.duration) }
        TimelineView(.animation(paused: !player.isPlaying || scrubbing != nil)) { _ in
            CallWaveformCanvas(tones: tones, flat: CallWaveform.flat(tones), loud: heights,
                               played: fraction(scrubbing ?? player.livePosition),
                               hoverX: player.canPlay ? hoverX : nil, grown: grown)
        }
        .frame(height: CallWaveform.trackHeight + 2 * CallWaveform.overhang)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .overlay(alignment: .topLeading) { hoverLabel }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentRing, lineWidth: 2)
                .padding(-3)
                .opacity(focused ? 1 : 0)
        }
        .contentShape(Rectangle())
        .gesture(scrub, isEnabled: player.canPlay)
        .onContinuousHover { phase in
            switch phase {
            case let .active(point): hoverX = point.x
            case .ended: hoverX = nil
            }
        }
        .focusable(player.canPlay)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end, .return]) { press in
            key(press.key) ? .handled : .ignored
        }
        .onChange(of: peaks != nil, initial: true) { old, loaded in
            // Known from the first frame (a snapshot): no growing.
            if !loaded || old == loaded || reduceMotion {
                grown = loaded ? 1 : 0
            } else {
                withAnimation(.easeInOut(duration: 0.5)) { grown = 1 }
            }
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0, play: player.isPlaying) }),
                   in: 0...duration, step: 5) {
                Text("Position in the call")
            }
            .accessibilityValue("\(Fmt.duration(player.currentTime)) of \(Fmt.duration(player.duration))")
        }
    }

    private func fraction(_ time: TimeInterval) -> CGFloat {
        CGFloat(min(1, max(0, time / duration)))
    }

    private func time(at x: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * player.duration
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { scrubbing = time(at: $0.location.x) }
            .onEnded { value in
                focused = true
                scrubbing = nil
                // The first click asks to listen: it plays from there.
                player.seek(to: time(at: value.location.x), play: player.isPlaying || player.isIdle)
            }
    }

    private func key(_ key: KeyEquivalent) -> Bool {
        let now = player.currentTime
        switch key {
        case .leftArrow, .downArrow: player.seek(to: now - 5, play: player.isPlaying)
        case .rightArrow, .upArrow: player.seek(to: now + 5, play: player.isPlaying)
        case .home: player.seek(to: 0, play: player.isPlaying)
        case .end: player.seek(to: player.duration, play: player.isPlaying)
        // Space is the Play button's, wherever the focus is.
        case .return: player.toggle()
        default: return false
        }
        return true
    }

    /// The time under the pointer, over the bars.
    @ViewBuilder private var hoverLabel: some View {
        if let hoverX, player.canPlay, width > 0 {
            let label = Text(Fmt.duration(scrubbing ?? time(at: hoverX)))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.ink)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.bgElevated, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.stroke))
                .fixedSize()
            let x = scrubbing.map { CGFloat($0 / duration) * width } ?? hoverX
            label
                .alignmentGuide(.leading) { d in
                    -min(max(0, x - d.width / 2), max(0, width - d.width))
                }
                .offset(y: -8)
                .allowsHitTesting(false)
        }
    }
}

/// The bars themselves, drawn at `grown` of the way from flat to loud (animated as the loudness arrives).
private struct CallWaveformCanvas: View, Animatable {
    var tones: [CallWaveform.Tone]
    var flat: [Float]
    var loud: [Float]?
    /// How much of the call has played, 0...1.
    var played: CGFloat
    var hoverX: CGFloat?
    var grown: Double

    var animatableData: Double {
        get { grown }
        set { grown = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let count = tones.count
            guard count > 0, size.width > 0 else { return }
            let step = size.width / CGFloat(count)
            let bar = min(CallWaveform.barWidth, step * 0.6)
            let track = CallWaveform.trackHeight
            let top = CallWaveform.overhang
            // One path per color: a few fills, however many bars.
            var paths: [CallWaveform.Tone: Path] = [:]
            for index in 0..<count {
                let flatHeight = Double(flat[index])
                let amplitude = loud.map { flatHeight + (Double($0[index]) - flatHeight) * grown } ?? flatHeight
                let height = max(bar, track * CGFloat(amplitude))
                let rect = CGRect(x: CGFloat(index) * step + (step - bar) / 2, y: top + (track - height) / 2,
                                  width: bar, height: height)
                paths[tones[index], default: Path()].addRoundedRect(in: rect, cornerSize: CGSize(width: bar / 2, height: bar / 2))
            }
            let split = size.width * played
            for (clip, opacity) in [(CGRect(x: split, y: 0, width: size.width - split, height: size.height), 0.35),
                                    (CGRect(x: 0, y: 0, width: split, height: size.height), 1.0)] where clip.width > 0 {
                context.drawLayer { layer in
                    layer.clip(to: Path(clip))
                    layer.opacity = opacity
                    for (tone, path) in paths { layer.fill(path, with: .color(CallWaveform.color(tone))) }
                }
            }
            if let hoverX {
                context.fill(Path(CGRect(x: hoverX - 0.5, y: top, width: 1, height: track)),
                             with: .color(Color.ink.opacity(0.3)))
            }
            let x = min(max(split, 1), size.width - 1)
            context.fill(Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
                         with: .color(.ink))
        }
    }
}

/// The speakers under the waveform: a dot in each one's color and their name, as renamed.
struct CallWaveformLegend: View {
    var call: CallRecord

    var body: some View {
        let speakers = CallWaveform.legend(call)
        if !speakers.isEmpty {
            FlowLayout(spacing: 12, lineSpacing: 4) {
                ForEach(speakers, id: \.speaker) { speaker in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(CallSpeakerColors.color(speaker.slot))
                            .frame(width: 7, height: 7)
                        Text(speaker.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Speakers: \(speakers.map(\.name).joined(separator: ", "))")
        }
    }
}

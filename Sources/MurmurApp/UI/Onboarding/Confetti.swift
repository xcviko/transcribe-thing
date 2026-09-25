import SwiftUI

/// A short, soft burst of paper in the accent, apricot and lilac palette (about 1.6 s), drawn in one Canvas.
/// Nothing is drawn under Reduce Motion, and the timeline stops once the last piece has faded.
struct ConfettiBurst: View {
    /// Burst origin in unit coordinates of the view.
    var origin: UnitPoint = UnitPoint(x: 0.5, y: 0.42)
    var count = 90

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingStillTime) private var stillTime
    @State private var finished = false

    static let duration = 1.9

    var body: some View {
        if !reduceMotion && !finished {
            StageClock(fixedTime: stillTime.map { min($0, Self.duration) }) { t in
                Canvas { context, size in
                    let pieces = ConfettiPiece.make(count: count)
                    let o = CGPoint(x: size.width * origin.x, y: size.height * origin.y)
                    for piece in pieces {
                        piece.draw(in: &context, origin: o, time: t)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                guard stillTime == nil else { return }
                try? await Task.sleep(for: .seconds(Self.duration + 0.1))
                finished = true
            }
        }
    }
}

struct ConfettiPiece {
    enum Kind { case strip, dot, squiggle }

    var kind: Kind
    var color: Color
    var angle: Double
    var speed: Double
    var spin: Double
    var size: CGFloat
    var delay: Double
    var sway: Double

    private static let palette: [Color] = [
        Color(nsColor: .hex(0x5B4FE0)), Color(nsColor: .hex(0x8F86FF)), Color(nsColor: .hex(0xFF9F6E)),
        Color(nsColor: .hex(0xFFC4A3)), Color(nsColor: .hex(0xC9C1FF)), Color(nsColor: .hex(0xFFD27A)),
    ]

    /// Deterministic pseudo-random pieces: identical every frame and in every snapshot.
    static func make(count: Int) -> [ConfettiPiece] {
        (0..<count).map { i in
            func r(_ salt: Int) -> Double {
                let x = sin(Double(i * 7919 + salt * 104_729) * 12.9898) * 43_758.5453
                return x - floor(x)
            }
            let kinds: [Kind] = [.strip, .strip, .dot, .squiggle]
            // Mostly upward, fanning out to both sides.
            let angle = -.pi / 2 + (r(1) - 0.5) * .pi * 1.25
            return ConfettiPiece(
                kind: kinds[Int(r(2) * Double(kinds.count)) % kinds.count],
                color: palette[Int(r(3) * Double(palette.count)) % palette.count],
                angle: angle,
                speed: 230 + r(4) * 330,
                spin: (r(5) - 0.5) * 14,
                size: 5 + CGFloat(r(6)) * 4,
                delay: r(7) * 0.12,
                sway: r(8) * 6.28)
        }
    }

    func draw(in context: inout GraphicsContext, origin: CGPoint, time: Double) {
        let t = time - delay
        guard t > 0 else { return }
        let drag = 1.8
        let decay = (1 - exp(-drag * t)) / drag
        let gravity = 520.0
        let x = origin.x + CGFloat(cos(angle) * speed * decay + 10 * sin(t * 5 + sway))
        let y = origin.y + CGFloat(sin(angle) * speed * decay + 0.5 * gravity * t * t)
        let fade = 1 - Ease.smooth(Ease.progress(t, 1.05, ConfettiBurst.duration - delay))
        guard fade > 0.01 else { return }
        let appear = Ease.progress(t, 0, 0.06)

        var piece = context
        piece.opacity = fade * appear
        piece.translateBy(x: x, y: y)
        piece.rotate(by: .radians(spin * t + sway))
        // Paper flips: the visible width breathes as it tumbles.
        let flip = CGFloat(abs(cos(t * 7 + sway)))
        switch kind {
        case .strip:
            let rect = CGRect(x: -size * 0.35 * flip, y: -size * 0.8, width: max(0.8, size * 0.7 * flip), height: size * 1.6)
            piece.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(color))
        case .dot:
            let d = size * 0.8
            piece.fill(Path(ellipseIn: CGRect(x: -d / 2, y: -d / 2 * flip, width: d, height: max(0.8, d * flip))), with: .color(color))
        case .squiggle:
            var path = Path()
            let w = size * 1.9
            path.move(to: CGPoint(x: -w / 2, y: 0))
            path.addCurve(to: CGPoint(x: w / 2, y: 0),
                          control1: CGPoint(x: -w / 6, y: -size * 0.9), control2: CGPoint(x: w / 6, y: size * 0.9))
            piece.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

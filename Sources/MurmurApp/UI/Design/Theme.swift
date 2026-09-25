import AppKit
import SwiftUI

// "Paper, ink and a quiet glow" (wispr-ux.md §6.2): warm oat canvas, ink text, an iris accent.
// Colors resolve per appearance at draw time, so they follow window/system appearance changes.

// MARK: - Palette

enum Palette {
    static let bgCanvas = dynamic("bgCanvas", light: .hex(0xFAF7F2), dark: .hex(0x161514))
    static let bgSurface = dynamic("bgSurface", light: .hex(0xFFFFFF), dark: .hex(0x1F1E1C))
    static let bgSunken = dynamic("bgSunken", light: .hex(0xF3EFE8), dark: .hex(0x121110))
    static let bgElevated = dynamic("bgElevated", light: .hex(0xFFFFFF), dark: .hex(0x2A2927))
    static let stroke = dynamic("stroke", light: .hex(0x1C1A17, alpha: 0.08), dark: .hex(0xFFFFFF, alpha: 0.09))
    static let strokeStrong = dynamic("strokeStrong", light: .hex(0x1C1A17, alpha: 0.14), dark: .hex(0xFFFFFF, alpha: 0.16))
    static let hover = dynamic("hover", light: .hex(0x1C1A17, alpha: 0.05), dark: .hex(0xFFFFFF, alpha: 0.06))
    static let pressed = dynamic("pressed", light: .hex(0x1C1A17, alpha: 0.09), dark: .hex(0xFFFFFF, alpha: 0.10))

    static let ink = dynamic("ink", light: .hex(0x1C1A17), dark: .hex(0xF4F1EC))
    static let inkSecondary = dynamic("inkSecondary", light: .hex(0x1C1A17, alpha: 0.62), dark: .hex(0xF4F1EC, alpha: 0.64))
    static let inkTertiary = dynamic("inkTertiary", light: .hex(0x1C1A17, alpha: 0.40), dark: .hex(0xF4F1EC, alpha: 0.42))

    static let accent = dynamic("accent", light: .hex(0x5B4FE0), dark: .hex(0x8F86FF))
    /// Button fills: a touch deeper than `accent` in dark mode so white labels keep 4.5:1 contrast.
    static let accentFill = dynamic("accentFill", light: .hex(0x5B4FE0), dark: .hex(0x6C61F2))
    static let accentSoft = dynamic("accentSoft", light: .hex(0x5B4FE0, alpha: 0.10), dark: .hex(0x8F86FF, alpha: 0.16))
    static let accentRing = dynamic("accentRing", light: .hex(0x5B4FE0, alpha: 0.35), dark: .hex(0x8F86FF, alpha: 0.45))
    static let onAccent = NSColor.white

    static let warm = dynamic("warm", light: .hex(0xFF9F6E), dark: .hex(0xFFB38F))
    static let lilacWash = dynamic("lilacWash", light: .hex(0xEFEAFF), dark: .hex(0x2A2640))
    static let success = dynamic("success", light: .hex(0x2F9E57), dark: .hex(0x3CCB6C))
    static let warning = dynamic("warning", light: .hex(0xC97A00), dark: .hex(0xFFB340))
    static let danger = dynamic("danger", light: .hex(0xD93B30), dark: .hex(0xFF6B5E))

    /// The pill is always dark, in both appearances.
    static let pillFill = NSColor.hex(0x101012, alpha: 0.92)
    static let chipFill = dynamic("chipFill", light: .hex(0xFFFFFF), dark: .hex(0x2A2927))
    static let chipStroke = dynamic("chipStroke", light: .hex(0x1C1A17, alpha: 0.12), dark: .hex(0xFFFFFF, alpha: 0.12))
    static let chipBase = dynamic("chipBase", light: .hex(0x1C1A17, alpha: 0.10), dark: .hex(0x000000, alpha: 0.45))

    static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("murmur.\(name)")) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension NSColor {
    static func hex(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: alpha)
    }
}

extension Color {
    static let bgCanvas = Color(nsColor: Palette.bgCanvas)
    static let bgSurface = Color(nsColor: Palette.bgSurface)
    static let bgSunken = Color(nsColor: Palette.bgSunken)
    static let bgElevated = Color(nsColor: Palette.bgElevated)
    static let stroke = Color(nsColor: Palette.stroke)
    static let strokeStrong = Color(nsColor: Palette.strokeStrong)
    static let hover = Color(nsColor: Palette.hover)
    static let pressed = Color(nsColor: Palette.pressed)
    static let ink = Color(nsColor: Palette.ink)
    static let inkSecondary = Color(nsColor: Palette.inkSecondary)
    static let inkTertiary = Color(nsColor: Palette.inkTertiary)
    static let accent = Color(nsColor: Palette.accent)
    static let accentFill = Color(nsColor: Palette.accentFill)
    static let accentSoft = Color(nsColor: Palette.accentSoft)
    static let accentRing = Color(nsColor: Palette.accentRing)
    static let onAccent = Color(nsColor: Palette.onAccent)
    static let warm = Color(nsColor: Palette.warm)
    static let lilacWash = Color(nsColor: Palette.lilacWash)
    static let success = Color(nsColor: Palette.success)
    static let warning = Color(nsColor: Palette.warning)
    static let danger = Color(nsColor: Palette.danger)
    static let pillFill = Color(nsColor: Palette.pillFill)
    static let chipFill = Color(nsColor: Palette.chipFill)
    static let chipStroke = Color(nsColor: Palette.chipStroke)
    static let chipBase = Color(nsColor: Palette.chipBase)
}

// Leading-dot syntax in `.foregroundStyle(.ink)`, `.background(.bgCanvas)`, `.fill(.accentSoft)`.
extension ShapeStyle where Self == Color {
    static var bgCanvas: Color { Color.bgCanvas }
    static var bgSurface: Color { Color.bgSurface }
    static var bgSunken: Color { Color.bgSunken }
    static var bgElevated: Color { Color.bgElevated }
    static var stroke: Color { Color.stroke }
    static var strokeStrong: Color { Color.strokeStrong }
    static var hover: Color { Color.hover }
    static var pressed: Color { Color.pressed }
    static var ink: Color { Color.ink }
    static var inkSecondary: Color { Color.inkSecondary }
    static var inkTertiary: Color { Color.inkTertiary }
    static var accent: Color { Color.accent }
    static var accentFill: Color { Color.accentFill }
    static var accentSoft: Color { Color.accentSoft }
    static var accentRing: Color { Color.accentRing }
    static var onAccent: Color { Color.onAccent }
    static var warm: Color { Color.warm }
    static var lilacWash: Color { Color.lilacWash }
    static var success: Color { Color.success }
    static var warning: Color { Color.warning }
    static var danger: Color { Color.danger }
    static var pillFill: Color { Color.pillFill }
    static var chipFill: Color { Color.chipFill }
    static var chipStroke: Color { Color.chipStroke }
}

// MARK: - Tokens

enum Theme {
    enum Typeface: CaseIterable, Sendable {
        case display, greeting, title, headline, body, bodyMedium, callout, calloutMedium, caption, numeric, key, mono

        var size: CGFloat {
            switch self {
            case .display: 30
            case .greeting: 28
            case .title: 20
            case .headline: 15
            case .body, .bodyMedium: 13
            case .callout, .calloutMedium, .key, .mono: 12
            case .caption: 11
            case .numeric: 22
            }
        }

        var lineHeight: CGFloat {
            switch self {
            case .display: 36
            case .greeting: 34
            case .title: 26
            case .headline: 20
            case .body, .bodyMedium: 18
            case .callout, .calloutMedium, .mono: 16
            case .caption, .key: 14
            case .numeric: 26
            }
        }

        var font: Font {
            switch self {
            case .display: .system(size: 30, weight: .semibold, design: .serif)
            case .greeting: .system(size: 28, weight: .semibold, design: .serif)
            case .title: .system(size: 20, weight: .semibold)
            case .headline: .system(size: 15, weight: .semibold)
            case .body: .system(size: 13, weight: .regular)
            case .bodyMedium: .system(size: 13, weight: .medium)
            case .callout: .system(size: 12, weight: .regular)
            case .calloutMedium: .system(size: 12, weight: .medium)
            case .caption: .system(size: 11, weight: .medium)
            case .numeric: .system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
            case .key: .system(size: 12, weight: .medium, design: .rounded)
            case .mono: .system(size: 12, weight: .regular, design: .monospaced)
            }
        }

        /// Serif display faces read better slightly tightened; captions are tracked out.
        var tracking: CGFloat {
            switch self {
            case .display, .greeting: -0.3
            case .title: -0.2
            case .caption: 0.2
            default: 0
            }
        }
    }

    enum Radius {
        static let card: CGFloat = 16
        static let row: CGFloat = 12
        static let control: CGFloat = 8
        static let chip: CGFloat = 6
        static let toast: CGFloat = 18
    }

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 40
        static let page: CGFloat = 28
        static let cardPadding: CGFloat = 16
        static let section: CGFloat = 24
        static let rowHorizontal: CGFloat = 12
        static let rowVertical: CGFloat = 10
    }

    enum Metrics {
        static let buttonHeight: CGFloat = 32
        static let largeButtonHeight: CGFloat = 40
        static let smallButtonHeight: CGFloat = 26
        static let progressHeight: CGFloat = 6
        static let hairline: CGFloat = 1
    }

    enum Motion {
        /// Growing states (bloom, expand): 0.32 s.
        static let expand = Animation.spring(response: 0.32, dampingFraction: 0.82)
        /// Shrinking states get out of the way faster: 0.28 s.
        static let collapse = Animation.spring(response: 0.28, dampingFraction: 0.9)
        static let snappy = Animation.snappy(duration: 0.22)
        static let fade = Animation.easeOut(duration: 0.18)
        static let hover = Animation.easeOut(duration: 0.12)
        static let progress = Animation.easeInOut(duration: 0.35)
    }
}

extension Font {
    static func murmur(_ typeface: Theme.Typeface) -> Font { typeface.font }
}

extension View {
    /// Window-root styling: iris tint for switches, sliders, pickers and focus rings.
    /// Applied to every Murmur window root and every snapshot.
    func murmurTheme() -> some View {
        tint(.accent)
    }

    /// Font + line height + tracking of a type token.
    func typeface(_ typeface: Theme.Typeface) -> some View {
        font(typeface.font)
            .tracking(typeface.tracking)
            .lineSpacing(max(0, typeface.lineHeight - typeface.size * 1.2))
    }

    /// Two-layer soft shadow for cards on the canvas (barely-there in dark mode, where the hairline carries the edge).
    func cardShadow(elevated: Bool = false) -> some View {
        modifier(CardShadow(elevated: elevated))
    }
}

private struct CardShadow: ViewModifier {
    var elevated: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .shadow(color: .black.opacity(dark ? 0.35 : 0.045), radius: dark ? 1 : 1, x: 0, y: 1)
            .shadow(color: .black.opacity(dark ? 0.28 : (elevated ? 0.10 : 0.055)),
                    radius: elevated ? 22 : 14, x: 0, y: elevated ? 10 : 6)
    }
}

// MARK: - Borders

/// The band between a shape and its inset copy. Fill it with `FillStyle(eoFill: true)` to draw a border.
/// Prefer this over `strokeBorder` on fully rounded shapes (capsules, `cornerRadius == height / 2`): their
/// strokes render stray vertical lines at the flat ends in `cacheDisplay`-based snapshots.
struct RingShape<Base: InsettableShape>: Shape {
    var base: Base
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = base.path(in: rect)
        path.addPath(base.inset(by: width).path(in: rect))
        return path
    }
}

extension InsettableShape {
    /// `Capsule().ring(1).fill(Color.stroke, style: FillStyle(eoFill: true))`
    func ring(_ width: CGFloat) -> RingShape<Self> {
        RingShape(base: self, width: width)
    }
}

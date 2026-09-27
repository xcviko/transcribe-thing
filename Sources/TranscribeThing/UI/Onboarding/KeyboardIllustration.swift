import SwiftUI

/// The corner of a Mac keyboard the shortcuts live on (esc above, fn to ⌘ and the space bar below), drawn in
/// code. Keys sink and glow while physically held.
struct KeyboardIllustration: View {
    var pressed: Set<IllustratedKey>
    /// Keys used by the current bindings: their legends are tinted so the eye finds them.
    var emphasized: Set<IllustratedKey>
    var unit: CGFloat = 30
    var gap: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                cap(.escape, width: unit * 1.5, height: unit * 0.56, bottomLeft: "esc")
                ForEach(Self.functionIcons, id: \.self) { icon in
                    DecorKeycap(width: unit, height: unit * 0.56, symbol: icon)
                }
            }
            HStack(spacing: gap) {
                cap(.fn, width: unit, height: unit, topRight: "fn", bottomLeftSymbol: "globe")
                cap(.control, width: unit, height: unit, topRight: "⌃")
                cap(.option, width: unit, height: unit, topRight: "⌥")
                cap(.command, width: unit * 1.25, height: unit, topRight: "⌘")
                // Runs on past the crop: the host fades it out.
                cap(.space, width: unit * 6.5, height: unit)
            }
        }
        .padding(9)
        .background(KeyboardDeck())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private static let functionIcons = ["sun.min", "sun.max", "rectangle.3.group", "magnifyingglass", "mic", "moon",
                                        "backward", "playpause", "forward"]

    private func cap(_ key: IllustratedKey, width: CGFloat, height: CGFloat, topLeft: String? = nil,
                     topRight: String? = nil, bottomLeft: String? = nil, bottomLeftSymbol: String? = nil) -> some View {
        IllustratedKeycap(width: width, height: height, isPressed: pressed.contains(key),
                          isEmphasized: emphasized.contains(key), topLeft: topLeft, topRight: topRight,
                          bottomLeft: bottomLeft, bottomLeftSymbol: bottomLeftSymbol)
    }

    private var accessibilityDescription: String {
        let names: [IllustratedKey: String] = [.escape: "esc", .fn: "fn", .control: "control", .option: "option",
                                               .command: "command", .shift: "shift", .space: "space"]
        let held = IllustratedKey.allCases.filter(pressed.contains).compactMap { names[$0] }
        return held.isEmpty ? "Keyboard" : "Keyboard, holding \(held.joined(separator: " and "))"
    }
}

private struct KeyboardDeck: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let dark = scheme == .dark
        shape
            .fill(LinearGradient(colors: dark ? [Color(nsColor: .hex(0x242321)), Color(nsColor: .hex(0x1B1A19))]
                                     : [Color(nsColor: .hex(0xE9E5DF)), Color(nsColor: .hex(0xDFDAD2))],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.08 : 0.7), .black.opacity(dark ? 0.3 : 0.06)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(dark ? 0.4 : 0.08), radius: 16, x: 0, y: 10)
    }
}

/// A key that reacts to presses.
private struct IllustratedKeycap: View {
    var width: CGFloat
    var height: CGFloat
    var isPressed: Bool
    var isEmphasized: Bool
    var topLeft: String?
    var topRight: String?
    var bottomLeft: String?
    var bottomLeftSymbol: String?

    @Environment(\.colorScheme) private var scheme

    private let depth: CGFloat = 2.5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let legend: Color = isPressed ? .accent : (isEmphasized ? .ink : .inkSecondary)
        ZStack {
            KeycapFace(isPressed: isPressed)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if let topLeft { legendText(topLeft, size: 11, color: legend) }
                    Spacer(minLength: 0)
                    if let topRight { legendText(topRight, size: topRight.count > 1 ? 9 : 11, color: legend) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    if let bottomLeftSymbol {
                        Image(systemName: bottomLeftSymbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(legend)
                    }
                    if let bottomLeft { legendText(bottomLeft, size: 8.5, color: legend) }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, height < 30 ? 4 : 5)
            if isPressed {
                shape.strokeBorder(Color.accent.opacity(0.65), lineWidth: 1.5)
            } else if isEmphasized {
                shape.strokeBorder(Color.accentRing.opacity(0.7), lineWidth: 1)
            }
        }
        .frame(width: width, height: height)
        .offset(y: isPressed ? depth * 0.8 : 0)
        .background {
            shape.fill(Color.black.opacity(scheme == .dark ? 0.55 : 0.16)).offset(y: depth)
        }
        .shadow(color: Color.accent.opacity(isPressed ? (scheme == .dark ? 0.7 : 0.5) : 0), radius: 12, x: 0, y: 2)
        .shadow(color: Color.accent.opacity(isPressed ? 0.35 : 0), radius: 26, x: 0, y: 0)
        .padding(.bottom, depth)
        .animation(.spring(duration: 0.16, bounce: 0.2), value: isPressed)
    }

    private func legendText(_ text: String, size: CGFloat, color: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct KeycapFace: View {
    var isPressed: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let dark = scheme == .dark
        shape
            .fill(LinearGradient(colors: dark ? [Color(nsColor: .hex(0x3A3936)), Color(nsColor: .hex(0x302F2C))]
                                     : [Color(nsColor: .hex(0xFFFFFF)), Color(nsColor: .hex(0xF5F3EF))],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                if isPressed {
                    shape.fill(LinearGradient(colors: [Color.accent.opacity(dark ? 0.34 : 0.16), Color.accent.opacity(dark ? 0.22 : 0.26)],
                                              startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.10 : 0.9), .black.opacity(dark ? 0.25 : 0.07)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }
}

/// Context keys that never light up.
private struct DecorKeycap: View {
    var width: CGFloat
    var height: CGFloat
    var letter: String?
    var symbol: String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack {
            KeycapFace(isPressed: false)
            if let letter {
                Text(verbatim: letter)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.inkTertiary)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.inkTertiary)
            }
        }
        .frame(width: width, height: height)
        .background { shape.fill(Color.black.opacity(scheme == .dark ? 0.55 : 0.16)).offset(y: 2.5) }
        .padding(.bottom, 2.5)
        .opacity(0.85)
    }
}

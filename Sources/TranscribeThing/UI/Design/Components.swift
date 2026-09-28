import SwiftUI

// Reusable building blocks for the Hub, onboarding and pill previews. Everything reads Theme tokens.

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat
    var elevated: Bool
    @ViewBuilder var content: Content

    init(padding: CGFloat = Theme.Spacing.cardPadding, elevated: Bool = false, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.elevated = elevated
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bgSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(.stroke, lineWidth: Theme.Metrics.hairline)
            }
            .cardShadow(elevated: elevated)
    }
}

extension View {
    /// This row's band of a `Card(padding: 0)` whose rows are separate items of a lazy stack (History): the card's
    /// fill, shadow and hairline where the row sits, rounded above the first row and below the last. Stacked
    /// without gaps, the bands draw the same card, but no view holds all the rows.
    func cardSegment(isFirst: Bool, isLast: Bool) -> some View {
        modifier(CardSegment(isFirst: isFirst, isLast: isLast))
    }
}

private struct CardSegment: ViewModifier {
    var isFirst: Bool
    var isLast: Bool
    /// Beyond the reach of the card's shadow (14 pt blur, 6 pt down).
    private static let reach: CGFloat = 48

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // `clipped()` only clips drawing: without this, the band's hidden run-on past the row would take
                // the clicks and hovers of the rows it reaches under.
                band { shape.fill(.bgSurface).cardShadow() }
                    .allowsHitTesting(false)
            }
            .overlay {
                band { shape.strokeBorder(.stroke, lineWidth: Theme.Metrics.hairline) }
                    .allowsHitTesting(false)
            }
    }

    /// `card` runs on well past the row where a neighbour continues it (so neither its rounding nor the fall-off of
    /// its shadow shows at the join) and is cut at the join; at the card's outer edges the cut leaves room for the
    /// shadow.
    private func band(@ViewBuilder _ card: () -> some View) -> some View {
        let reach = Self.reach
        let outside = EdgeInsets(top: isFirst ? reach : 0, leading: reach, bottom: isLast ? reach : 0, trailing: reach)
        return Color.clear
            .overlay {
                card()
                    .padding(.top, isFirst ? 0 : -2 * reach)
                    .padding(.bottom, isLast ? 0 : -2 * reach)
            }
            .padding(outside)
            .clipped()
            .padding(EdgeInsets(top: -outside.top, leading: -reach, bottom: -outside.bottom, trailing: -reach))
    }
}

/// Rows separated by inset hairlines inside one card (System Settings-style group).
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Card(padding: 0) {
            Group(subviews: content) { subviews in
                VStack(spacing: 0) {
                    ForEach(subviews) { subview in
                        if subview.id != subviews.first?.id { RowDivider() }
                        subview
                    }
                }
            }
        }
    }
}

struct RowDivider: View {
    var inset: CGFloat = Theme.Spacing.md

    var body: some View {
        Rectangle()
            .fill(.stroke)
            .frame(height: Theme.Metrics.hairline)
            .padding(.leading, inset)
    }
}

// MARK: - Keys

struct KeyChip: View {
    enum Size {
        case small, regular, large

        var height: CGFloat {
            switch self {
            case .small: 18
            case .regular: 22
            case .large: 30
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .small: 10.5
            case .regular: 12
            case .large: 15
            }
        }

        var radius: CGFloat {
            switch self {
            case .small: 4.5
            case .regular: Theme.Radius.chip
            case .large: 8
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: 5
            case .regular: 6.5
            case .large: 10
            }
        }
    }

    var label: String
    var systemImage: String?
    /// "left" / "right" for side-specific modifiers.
    var caption: String?
    var size: Size = .regular
    var isWide = false
    /// Held down (onboarding keyboard): sinks into its base and glows iris.
    var isPressed = false

    init(label: String, systemImage: String? = nil, caption: String? = nil, size: Size = .regular,
         isWide: Bool = false, isPressed: Bool = false) {
        self.label = label
        self.systemImage = systemImage
        self.caption = caption
        self.size = size
        self.isWide = isWide
        self.isPressed = isPressed
    }

    init(_ keycap: Keycap, size: Size = .regular, isPressed: Bool = false) {
        self.init(label: keycap.label, systemImage: keycap.systemImage, caption: keycap.sideCaption,
                  size: size, isWide: keycap.isWide, isPressed: isPressed)
    }

    private var isSymbol: Bool { ["⌘", "⌃", "⌥", "⇧"].contains(label) }
    private var baseDepth: CGFloat { size == .large ? 2 : 1.5 }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size.radius, style: .continuous) }

    private var legend: some View {
        HStack(spacing: size == .small ? 2 : 3) {
            if let caption {
                Text(caption)
                    .font(.system(size: size.fontSize - 3, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkTertiary)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size.fontSize - 2, weight: .medium))
                    .foregroundStyle(Color.inkSecondary)
            }
            Text(label)
                .font(.system(size: isSymbol ? size.fontSize + 1 : size.fontSize, weight: .medium, design: .rounded))
                .foregroundStyle(isPressed ? Color.accent : Color.ink)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var face: some View {
        ZStack {
            shape.fill(Color.bgSurface)
            shape.fill(isPressed ? Color.accentSoft : Color.chipFill)
            shape.strokeBorder(isPressed ? Color.accentRing : Color.chipStroke, lineWidth: 1)
        }
    }

    var body: some View {
        let minWidth: CGFloat = isWide ? size.height * 2.6 : size.height
        let sink: CGFloat = isPressed ? baseDepth * 0.75 : 0
        // A ZStack of fixed-size children instead of `.frame(minWidth:)`: a flexible frame reports its
        // minimum as the ideal width under `.fixedSize()`, which squeezed the legend out of the face.
        ZStack {
            Color.clear.frame(width: minWidth, height: 1)
            legend.padding(.horizontal, size.horizontalPadding)
        }
            .frame(height: size.height)
            .background(face)
            .offset(y: sink)
            .background(shape.fill(Color.chipBase).offset(y: baseDepth))
            .padding(.bottom, baseDepth)
            .animation(Theme.Motion.hover, value: isPressed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(caption.map { "\($0) \(label)" } ?? label)
    }
}

/// A shortcut rendered as key caps: [🌐 fn] [space], [left ⌃] [⌘] [C].
struct ShortcutChips: View {
    var shortcut: Shortcut?
    var size: KeyChip.Size = .regular
    var placeholder = "Not set"

    init(shortcut: Shortcut?, size: KeyChip.Size = .regular, placeholder: String = "Not set") {
        self.shortcut = shortcut
        self.size = size
        self.placeholder = placeholder
    }

    var body: some View {
        if let shortcut, !shortcut.isEmpty {
            HStack(spacing: size == .large ? 6 : 4) {
                ForEach(Array(shortcut.keycaps.enumerated()), id: \.offset) { _, cap in
                    KeyChip(cap, size: size)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shortcut.spokenDescription)
        } else {
            Text(placeholder)
                .font(.system(size: size.fontSize, weight: .medium, design: .rounded))
                .foregroundStyle(.inkTertiary)
                .padding(.horizontal, size.horizontalPadding + 2)
                .frame(height: size.height)
                .overlay {
                    RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                        .strokeBorder(.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                }
        }
    }
}

// MARK: - Buttons

enum ButtonSize {
    case small, regular, large

    var height: CGFloat {
        switch self {
        case .small: Theme.Metrics.smallButtonHeight
        case .regular: Theme.Metrics.buttonHeight
        case .large: Theme.Metrics.largeButtonHeight
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 11
        case .regular: 16
        case .large: 22
        }
    }

    var font: Font {
        switch self {
        case .small: .system(size: 12, weight: .semibold)
        case .regular: .system(size: 13, weight: .semibold)
        case .large: .system(size: 14, weight: .semibold)
        }
    }
}

/// Iris capsule, 32 pt: the one primary action on a surface.
struct PrimaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .regular
    var fullWidth = false
    var tint: Color = .accentFill

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, size: size, fullWidth: fullWidth, tint: tint)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: ButtonSize
    let fullWidth: Bool
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(size.font)
            .foregroundStyle(.onAccent)
            .lineLimit(1)
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size.height)
            .background {
                Capsule(style: .continuous)
                    .fill(tint)
                    .overlay {
                        // Lit top edge: a soft white wash that fades by mid-height.
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0)],
                                                 startPoint: .top, endPoint: .center))
                    }
                    .overlay {
                        Capsule(style: .continuous).ring(1)
                            .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), style: FillStyle(eoFill: true))
                    }
                    .brightness(pressed ? -0.07 : (hovering ? 0.05 : 0))
            }
            .shadow(color: tint.opacity(scheme == .dark ? 0.0 : (isEnabled ? 0.22 : 0)), radius: 3.5, x: 0, y: 2)
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.06), radius: 1, x: 0, y: 1)
            .scaleEffect(pressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
            .animation(Theme.Motion.hover, value: pressed)
    }
}

/// Quiet capsule on the surface color with a hairline edge.
struct SecondaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .regular
    var fullWidth = false
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, size: size, fullWidth: fullWidth, isDestructive: isDestructive)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: ButtonSize
    let fullWidth: Bool
    let isDestructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(size.font.weight(.medium))
            .foregroundStyle(isDestructive ? Color.danger : Color.ink)
            .lineLimit(1)
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size.height)
            .background {
                Capsule(style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.bgSurface)
                    .overlay { Capsule(style: .continuous).fill(pressed ? Color.pressed : (hovering ? Color.hover : .clear)) }
                    .overlay { Capsule(style: .continuous).ring(1).fill(Color.strokeStrong, style: FillStyle(eoFill: true)) }
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 1, x: 0, y: 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
            .animation(Theme.Motion.hover, value: pressed)
    }
}

/// Text-only action ("Skip for now", "Insert example"): tinted label, hover wash.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = .accent
    var size: ButtonSize = .small

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, tint: tint, size: size)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let size: ButtonSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(size.font.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: size.height)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? Color.pressed : (hovering ? Color.hover : .clear))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
    }
}

/// Square icon button (toolbar, row actions): quiet until hovered.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var tint: Color = .inkSecondary
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, tint: tint, isActive: isActive)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let tint: Color
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: size * 0.46, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isActive ? Color.accent : (hovering ? Color.ink : tint))
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isActive ? Color.accentSoft : (pressed ? Color.pressed : (hovering ? Color.hover : .clear)))
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var appPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var appSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var appQuiet: QuietButtonStyle { QuietButtonStyle() }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var appIcon: IconButtonStyle { IconButtonStyle() }
}

// MARK: - Switch

/// Iris switch drawn in SwiftUI, so it looks identical in windows and offscreen snapshots.
struct AppSwitchStyle: ToggleStyle {
    var width: CGFloat = 34
    var height: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        AppSwitch(configuration: configuration, width: width, height: height)
    }
}

private struct AppSwitch: View {
    let configuration: ToggleStyleConfiguration
    let width: CGFloat
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let on = configuration.isOn
        let inset: CGFloat = 2
        let knob = height - inset * 2
        HStack(spacing: Theme.Spacing.xs) {
            configuration.label
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(on ? Color.accentFill : (scheme == .dark ? Color.white.opacity(0.16) : Color.ink.opacity(0.13)))
                Capsule(style: .continuous).ring(0.5)
                    .fill(Color.black.opacity(on ? 0.06 : 0.04), style: FillStyle(eoFill: true))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, x: 0, y: 0.5)
                    .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1.5)
                    .frame(width: knob, height: knob)
                    .padding(inset)
            }
            .frame(width: width, height: height)
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { configuration.isOn.toggle() }
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

extension ToggleStyle where Self == AppSwitchStyle {
    static var appSwitch: AppSwitchStyle { AppSwitchStyle() }
}

// MARK: - Status

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    /// Soft breathing halo for in-progress states (off under Reduce Motion).
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(color: Color, size: CGFloat = 8, pulsing: Bool = false) {
        self.color = color
        self.size = size
        self.pulsing = pulsing
    }

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (sin(t * 2 * .pi / 1.6) + 1) / 2
                    Circle()
                        .fill(color.opacity(0.10 + 0.18 * (1 - phase)))
                        .frame(width: size + 4 + 6 * phase, height: size + 4 + 6 * phase)
                }
            } else {
                Circle().fill(color.opacity(0.18)).frame(width: size + 6, height: size + 6)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size + 10, height: size + 10)
        .accessibilityHidden(true)
    }
}

struct Badge: View {
    var text: String
    var tint: Color = .accent
    var systemImage: String?

    init(text: String, tint: Color = .accent, systemImage: String? = nil) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(tint.opacity(0.12), in: Capsule(style: .continuous))
        .overlay { Capsule(style: .continuous).ring(0.5).fill(tint.opacity(0.16), style: FillStyle(eoFill: true)) }
        .fixedSize()
    }
}

extension Badge {
    /// Consistent tints for the engine badges ("Recommended", "Private", "Offline", "Cloud").
    static func engine(_ text: String) -> Badge {
        switch text {
        case "Recommended": Badge(text: text, tint: .accent, systemImage: "star.fill")
        case "Private": Badge(text: text, tint: .success, systemImage: "lock.fill")
        case "Offline": Badge(text: text, tint: .inkSecondary)
        case "Cloud": Badge(text: text, tint: .warning, systemImage: "cloud.fill")
        default: Badge(text: text, tint: .inkSecondary)
        }
    }
}

// MARK: - Progress

struct ProgressBar: View {
    /// 0...1
    var fraction: Double
    var tint: Color = .accent
    var height: CGFloat = Theme.Metrics.progressHeight

    init(fraction: Double, tint: Color = .accent, height: CGFloat = Theme.Metrics.progressHeight) {
        self.fraction = fraction
        self.tint = tint
        self.height = height
    }

    var body: some View {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Color.ink.opacity(0.08))
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.78), tint], startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    }
                    .frame(width: clamped > 0 ? max(height, geo.size.width * clamped) : 0)
            }
        }
        .frame(height: height)
        .animation(Theme.Motion.progress, value: clamped)
        .accessibilityElement()
        .accessibilityValue(Fmt.percent(clamped))
    }
}

/// Indeterminate progress: a soft highlight sweeping across the track.
struct ShimmerBar: View {
    var tint: Color = .accent
    var height: CGFloat = Theme.Metrics.progressHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tint: Color = .accent, height: CGFloat = Theme.Metrics.progressHeight) {
        self.tint = tint
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let segment = max(height * 4, width * 0.38)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(tint.opacity(0.14))
                if reduceMotion {
                    Capsule(style: .continuous).fill(tint.opacity(0.55))
                        .frame(width: segment)
                        .offset(x: (width - segment) / 2)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                        let period = 1.4
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let eased = 0.5 - cos(t * .pi) / 2
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [tint.opacity(0), tint, tint.opacity(0)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: segment)
                            .offset(x: -segment + (width + segment) * eased)
                    }
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
        .accessibilityLabel("In progress")
    }
}

// MARK: - Fields

extension View {
    /// Placeholder for an empty text field, drawn in `inkTertiary`. A field's `prompt:` takes the field's own
    /// foreground style, so an empty field would read as filled in. Apply it before the field's `.font`, so the
    /// placeholder inherits the font.
    func fieldPlaceholder(_ text: String, isShown: Bool, alignment: Alignment = .leading) -> some View {
        overlay(alignment: alignment) {
            if isShown {
                Text(verbatim: text)
                    .foregroundStyle(.inkTertiary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Layout

struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.inkTertiary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

extension SectionHeader {
    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, trailing: trailing)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title) { EmptyView() }
    }
}

extension VerticalAlignment {
    private enum SettingsRowAccessory: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }

    /// What a `SettingsRow` centers its icon and text on. Defaults to the trailing view's center; a trailing
    /// view that grows a note underneath (the shortcut recorder) moves it to its control, so the title stays
    /// beside the control instead of drifting down to the middle of the taller row.
    static let settingsRowAccessory = VerticalAlignment(SettingsRowAccessory.self)
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var systemImage: String?
    var iconTint: Color = .accent
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, systemImage: String? = nil, iconTint: Color = .accent,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .settingsRowAccessory, spacing: Theme.Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 28, height: 28)
                    .background(iconTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink)
                if let subtitle {
                    Text(subtitle)
                        .typeface(.callout)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            trailing
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(minHeight: 48)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, iconTint: Color = .accent) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, iconTint: iconTint) { EmptyView() }
    }
}

/// Soft onboarding/preview stage: lilac wash top-left, sunken middle, a warm glow bottom-right.
struct StageBackground: View {
    var cornerRadius: CGFloat = Theme.Radius.card

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(.bgSunken)
            .overlay {
                shape.fill(RadialGradient(colors: [.lilacWash, .lilacWash.opacity(0)],
                                          center: .topLeading, startRadius: 0, endRadius: 420))
            }
            .overlay {
                shape.fill(RadialGradient(colors: [Color.warm.opacity(0.16), Color.warm.opacity(0)],
                                          center: .bottomTrailing, startRadius: 0, endRadius: 360))
            }
            .overlay { shape.strokeBorder(.stroke, lineWidth: 1) }
    }
}

/// Engine mark used on model cards and history rows.
struct EngineIcon: View {
    var engine: EngineID
    var size: CGFloat = 32

    var body: some View {
        let tint: Color = engine.isLocal ? .accent : .warm
        Image(systemName: engine.symbolName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(tint.opacity(0.13))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
                    }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Model status

enum StatusTone: Sendable {
    case neutral, positive, progress, warning, negative

    var color: Color {
        switch self {
        case .neutral: .inkTertiary
        case .positive: .success
        case .progress: .accent
        case .warning: .warning
        case .negative: .danger
        }
    }
}

/// One-line status for a model or the OpenRouter key: "Ready · 632 MB", "Downloading 42% · about 1 min left",
/// "Optimizing for your Mac…", "Needs key", "Connected · $12.40 left".
struct ModelStatusText: View {
    private let text: String
    private let tone: StatusTone
    var showsDot = true

    /// `localError` is the error ModelStore kept for a failed model (what failed: download, disk, load).
    init(state: LocalModelState, engine: EngineID, showsDot: Bool = true, localError: AppError? = nil) {
        (text, tone) = Self.describe(state, engine: engine, localError: localError)
        self.showsDot = showsDot
    }

    init(keyStatus: KeyStatus, showsDot: Bool = true) {
        (text, tone) = Self.describe(keyStatus)
        self.showsDot = showsDot
    }

    var body: some View {
        HStack(spacing: 4) {
            if showsDot {
                StatusDot(color: tone.color, size: 6, pulsing: tone == .progress)
                    .frame(width: 12, height: 12)
            }
            Text(text)
                .typeface(.callout)
                .monospacedDigit()
                .foregroundStyle(tone == .negative ? Color.danger : Color.inkSecondary)
                .lineLimit(1)
        }
    }

    static func describe(_ state: LocalModelState, engine: EngineID,
                         localError: AppError? = nil) -> (text: String, tone: StatusTone) {
        let size = engine.approxDownloadBytes.map { " · \(Fmt.bytes($0))" } ?? ""
        switch state {
        case .notInstalled:
            return ("Not downloaded\(size)", .neutral)
        case .downloading(let p):
            let eta = p.secondsRemaining.map { " · \(Fmt.eta($0))" } ?? ""
            return ("Downloading \(p.percent)%\(eta)", .progress)
        case .installed:
            return ("Downloaded\(size)", .neutral)
        case .preparing:
            return ("Optimizing for your Mac…", .progress)
        case .ready:
            return ("Ready\(size)", .positive)
        case .failed:
            switch ModelFailure(localError) {
            case .download: return ("Didn’t finish · try again", .negative)
            case .disk: return ("Not enough space", .negative)
            case .load: return ("Couldn’t load · try again", .negative)
            }
        }
    }

    static func describe(_ status: KeyStatus) -> (text: String, tone: StatusTone) {
        switch status {
        case .missing:
            return ("Needs key", .warning)
        case .checking:
            return ("Checking key…", .progress)
        case .valid(let info):
            if let remaining = info.limitRemaining { return ("Connected · \(Fmt.usd(remaining)) left", .positive) }
            if info.usage > 0 { return ("Connected · \(Fmt.usd(info.usage)) used", .positive) }
            return ("Connected", .positive)
        case .invalid:
            return ("Key rejected", .negative)
        case .noCredit:
            return (status.isKeyLimitReached ? "Key limit reached" : "Out of credit", .negative)
        case .offline:
            return ("Offline · will check again", .warning)
        case .failed:
            return ("Couldn’t check key", .warning)
        }
    }
}

// MARK: - Mini pill

/// Non-panel pill for illustrations and previews: the real `PillView` driven by a frozen preview model.
struct MiniPill: View {
    var phase: PillPhase
    var level: Float

    @State private var model: PillModel

    init(phase: PillPhase, level: Float = 0.55) {
        self.phase = phase
        self.level = level
        _model = State(initialValue: .preview(phase: phase, level: level))
    }

    var body: some View {
        PillView(model: model)
            .onChange(of: phase) { _, new in model.phase = new }
            .accessibilityHidden(true)
    }
}

// MARK: - Pill mode illustration

/// Miniature screen showing where (and whether) the pill sits in each "Show the pill" mode. The Hub's tiles use
/// the full size; onboarding's shorter tiles use `compact`.
struct PillModeMiniScreen: View {
    var mode: PillMode
    var compact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
        ZStack(alignment: .bottom) {
            shape.fill(LinearGradient(colors: dark
                                      ? [Color(nsColor: .hex(0x28243F)), Color(nsColor: .hex(0x2B211C))]
                                      : [Color(nsColor: .hex(0xECE7FF)), Color(nsColor: .hex(0xFFE9DC))],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            // An app window, suggested rather than drawn.
            RoundedRectangle(cornerRadius: compact ? 3 : 5, style: .continuous)
                .fill(Color.white.opacity(dark ? 0.06 : 0.55))
                .frame(width: compact ? 50 : 70, height: compact ? 14 : 36)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, compact ? 6 : 10)
            PillModeGlyph(mode: mode, scale: compact ? 0.85 : 1)
                .padding(.bottom, compact ? 6 : 8)
        }
        .overlay { shape.strokeBorder(Color.stroke, lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// The pill as each mode shows it: a slim resting bar, the listening bars, or a dashed outline for Never.
private struct PillModeGlyph: View {
    var mode: PillMode
    var scale: CGFloat = 1

    var body: some View {
        switch mode {
        case .always:
            Capsule(style: .continuous)
                .fill(Color.pillFill)
                // The ring keeps the dark bar visible on the dark wallpaper.
                .overlay { Capsule(style: .continuous).ring(0.5).fill(.white.opacity(0.25), style: FillStyle(eoFill: true)) }
                .frame(width: 22 * scale, height: 6 * scale)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        case .whileDictating:
            HStack(spacing: 1.6 * scale) {
                ForEach(Array([0.3, 0.55, 0.85, 1.0, 0.7, 0.5, 0.3].enumerated()), id: \.offset) { _, h in
                    Capsule(style: .continuous).fill(.white)
                        .frame(width: 1.6 * scale, height: max(1.6, 8 * h) * scale)
                }
            }
            .frame(width: 42 * scale, height: 14 * scale)
            .background(Capsule(style: .continuous).fill(Color.pillFill))
            .overlay { Capsule(style: .continuous).ring(0.5).fill(.white.opacity(0.22), style: FillStyle(eoFill: true)) }
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
        case .never:
            Capsule(style: .continuous)
                .strokeBorder(Color.inkTertiary, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                .frame(width: 34 * scale, height: 10 * scale)
        }
    }
}

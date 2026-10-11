import SwiftUI

// Reusable building blocks for the Hub, onboarding and pill previews. Everything reads Theme tokens.

// MARK: - Card

extension EnvironmentValues {
    /// The view is inside a native grouped `Form` (a Hub page, `HubPage`): the form draws the rounded sections, their
    /// separators and their insets, so cards, groups and rows leave theirs out.
    @Entry var inNativeForm = false
}

struct Card<Content: View>: View {
    var padding: CGFloat
    var elevated: Bool
    @ViewBuilder var content: Content
    @Environment(\.inNativeForm) private var inNativeForm

    init(padding: CGFloat = Theme.Spacing.cardPadding, elevated: Bool = false, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.elevated = elevated
        self.content = content()
    }

    var body: some View {
        if inNativeForm {
            // A row of the form's section: the section is the card.
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            card
        }
    }

    private var card: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sectionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                band { shape.fill(Color.sectionFill) }
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
    @Environment(\.inNativeForm) private var inNativeForm

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if inNativeForm {
            // Each row a row of the form's section, with the form's own separators. Handed over as they are: rows
            // re-made from `Group(subviews:)` carry ids that repeat from one section to the next, and the form mixed
            // its sections up over them.
            content
        } else {
            card
        }
    }

    private var card: some View {
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

// The app's buttons are the system's (Liquid Glass on macOS 26): these styles only pick which, and at what size, so
// call sites keep naming a role (primary, secondary, quiet, icon) rather than a look.

extension ButtonSize {
    var controlSize: ControlSize {
        switch self {
        case .small: .small
        case .regular: .regular
        case .large: .large
        }
    }
}

/// The one primary action on a surface: the system's prominent button, in the accent color (or `tint`).
struct PrimaryButtonStyle: PrimitiveButtonStyle {
    var size: ButtonSize = .regular
    var fullWidth = false
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .lineLimit(1)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(size.controlSize)
        .tint(tint)
    }
}

/// A plain push button; `isDestructive` in red.
struct SecondaryButtonStyle: PrimitiveButtonStyle {
    var size: ButtonSize = .regular
    var fullWidth = false
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .lineLimit(1)
                .foregroundStyle(isDestructive ? Color.red : Color.primary)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .controlSize(size.controlSize)
    }
}

/// Text-only action ("Skip for now"): a borderless button in `tint`.
struct QuietButtonStyle: PrimitiveButtonStyle {
    var tint: Color = .accentColor
    var size: ButtonSize = .small

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .foregroundStyle(tint)
        }
        .buttonStyle(.borderless)
        .controlSize(size.controlSize)
    }
}

/// Square icon button (row actions): borderless, `size` points square. `isActive`: in the accent color.
struct IconButtonStyle: PrimitiveButtonStyle {
    var size: CGFloat = 28
    var tint: Color = .secondary
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isActive ? Color.accentColor : tint)
                .frame(width: size, height: size)
                .contentShape(RoundedRectangle(cornerRadius: size / 3, style: .continuous))
        }
        .buttonStyle(.borderless)
    }
}

extension PrimitiveButtonStyle where Self == PrimaryButtonStyle {
    static var appPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension PrimitiveButtonStyle where Self == SecondaryButtonStyle {
    static var appSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension PrimitiveButtonStyle where Self == QuietButtonStyle {
    static var appQuiet: QuietButtonStyle { QuietButtonStyle() }
}

extension PrimitiveButtonStyle where Self == IconButtonStyle {
    static var appIcon: IconButtonStyle { IconButtonStyle() }
}

// MARK: - Switch

/// The system's switch.
struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
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
    @Environment(\.inNativeForm) private var inNativeForm

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
        // In a form, the form's row insets.
        .padding(.horizontal, inNativeForm ? 0 : Theme.Spacing.md)
        .padding(.vertical, inNativeForm ? 2 : Theme.Spacing.sm)
        .frame(minHeight: inNativeForm ? 0 : 48)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, iconTint: Color = .accent) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, iconTint: iconTint) { EmptyView() }
    }
}

/// Soft onboarding/preview stage: a light wash top-left over the sunken gray.
struct StageBackground: View {
    var cornerRadius: CGFloat = Theme.Radius.card

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(.bgSunken)
            .overlay {
                shape.fill(RadialGradient(colors: [.lilacWash, .lilacWash.opacity(0)],
                                          center: .topLeading, startRadius: 0, endRadius: 420))
            }
            .overlay { shape.strokeBorder(.stroke, lineWidth: 1) }
    }
}

/// Where an engine runs: this Mac in ink, the cloud in gray. Onboarding's choice of where Parakeet runs; in the Hub a
/// model wears its own color (`ModelChoiceIcon`).
struct EngineIcon: View {
    var engine: EngineID
    var size: CGFloat = 32

    var body: some View {
        ModelTile(symbol: engine.symbolName, tint: engine.isLocal ? .accent : .inkSecondary, size: size)
    }
}

/// A model's mark: its symbol (Parakeet's bolt where `parakeet` runs it, Gemini's sparkles) in the
/// model's own color (`AppSettings.modelColors`), so a row in Models, the sidebar chip and the pill agree.
struct ModelChoiceIcon: View {
    var choice: ModelChoice
    var parakeet: EngineID
    var color: ModelColor
    var size: CGFloat = 32

    var body: some View {
        ModelTile(symbol: choice.symbolName(parakeet: parakeet), tint: color.tint, size: size)
    }
}

extension ModelColor {
    /// The model's color in the Hub, the one the pill wears (`PillPalette.accent(for:)`): its tile in Models and the
    /// sidebar, onboarding's summary. Graphite, the plain pill, is plain ink; orange is the Hub's warm.
    var hubColor: NSColor {
        switch self {
        case .graphite: Palette.inkSecondary
        case .orange: Palette.warm
        case .green: Palette.modelGreen
        case .teal: Palette.modelTeal
        case .blue: Palette.modelBlue
        case .violet: Palette.modelViolet
        case .purple: Palette.modelPurple
        case .pink: Palette.modelPink
        }
    }

    var tint: Color { Color(nsColor: hubColor) }

    /// History's marks, text this small: orange deepened (`HubPalette.apricotInk`); the others
    /// as `tint`.
    var markTint: Color { self == .orange ? HubPalette.apricotInk : tint }
}

/// A symbol on a tile of its tint: `EngineIcon`, `ModelChoiceIcon`.
private struct ModelTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background {
                shape.fill(tint.opacity(0.13))
                    .overlay { shape.strokeBorder(tint.opacity(0.18), lineWidth: 0.5) }
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
/// "Loading model…", "Needs key", "Connected · $12.40 left".
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
            return ("Loading model…", .progress)
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

    /// One key state, one color, wherever it shows: a missing key or spent credit is a warning to act on (as the key
    /// card's triangle), a rejected key an error.
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
        case .noCredit where status.isProxySpendLimit:
            return ("Spend limit reached", .warning)
        case .noCredit:
            return (status.isKeyLimitReached ? "Key limit reached" : "Out of credit", .warning)
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
                                      ? [Color(nsColor: .hex(0x2A2A2A)), Color(nsColor: .hex(0x1E1E1E))]
                                      : [Color(nsColor: .hex(0xF2F2F2)), Color(nsColor: .hex(0xE6E6E6))],
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

import AppKit
import SwiftUI

// Hub-specific building blocks on top of the design system (Theme + Components).

// MARK: - Extra tokens

enum HubPalette {
    /// Sidebar: a shade deeper than the canvas so the content reads as the lit "page".
    static let sidebar = Color(nsColor: Palette.dynamic("hub.sidebar", light: .hex(0xF2EEE6), dark: .hex(0x111010)))
    /// Selected sidebar row.
    static let sidebarSelection = Color(nsColor: Palette.dynamic("hub.sidebarSelection", light: .hex(0xFFFFFF), dark: .hex(0x2A2826)))
    /// Apricot dark enough for text on light surfaces.
    static let apricotInk = Color(nsColor: Palette.dynamic("hub.apricotInk", light: .hex(0xB85A2A), dark: .hex(0xFFB38F)))
    /// Field fill on cards (search, key field, code in release notes).
    static let field = Color(nsColor: Palette.dynamic("hub.field", light: .hex(0xF7F4EE), dark: .hex(0x171615)))
}

// MARK: - Page scaffold

/// A Hub page: title + subtitle header, then sections, in a centered readable column. A sub-page (Software
/// Update) gets a "‹ General" link above its title.
struct HubPage<Content: View, Accessory: View>: View {
    var title: String
    var subtitle: String?
    var back: HubBackLink?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, back: HubBackLink? = nil, @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.back = back
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                HStack(alignment: .lastTextBaseline, spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let back {
                            BackLinkButton(link: back)
                                .padding(.bottom, 2)
                        }
                        Text(title)
                            .typeface(.title)
                            .foregroundStyle(.ink)
                            .accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(subtitle)
                                .typeface(.body)
                                .foregroundStyle(.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    accessory
                }
                content
            }
            .padding(.horizontal, HubLayout.pageHorizontal)
            .padding(.top, HubLayout.pageTop)
            .padding(.bottom, HubLayout.pageBottom)
            .frame(maxWidth: HubLayout.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

extension HubPage where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, back: HubBackLink? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, back: back, accessory: { EmptyView() }, content: content)
    }
}

/// Where a sub-page's back link goes: "‹ General". ⌘[ follows it too.
struct HubBackLink {
    var title: String
    var action: () -> Void
}

private struct BackLinkButton: View {
    var link: HubBackLink
    @State private var hovering = false

    var body: some View {
        Button(action: link.action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(link.title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.ink : Color.accent)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.hover : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -6)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to \(link.title)")
        .accessibilityLabel("Back to \(link.title)")
    }
}

enum HubLayout {
    static let sidebarWidth: CGFloat = 212
    /// Clear band at the top of the detail column for the transparent titlebar (window drag area).
    static let titlebar: CGFloat = 28
    static let pageTop: CGFloat = 14
    static let pageBottom: CGFloat = 36
    static let pageHorizontal: CGFloat = 36
    static let readableWidth: CGFloat = 780
}

/// A titled group of settings: uppercase caption above a card.
struct HubGroup<Content: View, Trailing: View>: View {
    var title: String
    var footer: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionHeader(title) { trailing }
            content
            if let footer {
                Text(footer)
                    .typeface(.callout)
                    .foregroundStyle(.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
    }
}

extension HubGroup where Trailing == EmptyView {
    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Controls

/// Radio indicator: iris disc with a white center when on, a hairline ring when off.
struct RadioDot: View {
    var isOn: Bool
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Color.accentFill)
                Circle().fill(.white).frame(width: size * 0.38, height: size * 0.38)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            } else {
                Circle().fill(Color.bgSurface)
                Circle().strokeBorder(Color.strokeStrong, lineWidth: 1.25)
            }
        }
        .frame(width: size, height: size)
        .animation(Theme.Motion.snappy, value: isOn)
        .accessibilityHidden(true)
    }
}

/// Compact menu that looks like a secondary capsule: "Never ⌃⌄".
struct HubMenuPicker<Value: Hashable>: View {
    var options: [Value]
    @Binding var selection: Value
    var label: (Value) -> String

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(label(selection))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.inkTertiary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(SecondaryButtonStyle(size: .small))
        .fixedSize()
    }
}

/// A few mutually exclusive choices in a sunken capsule; the chosen one sits raised on a white chip.
struct HubSegmentedPicker<Value: Hashable>: View {
    var options: [Value]
    var selection: Value
    var label: (Value) -> String
    var onPick: (Value) -> Void
    @Namespace private var chip
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(Color.bgSunken, in: Capsule(style: .continuous))
        .overlay { Capsule(style: .continuous).ring(1).fill(Color.stroke, style: FillStyle(eoFill: true)) }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Value) -> some View {
        let selected = option == selection
        return Button {
            withAnimation(Theme.Motion.snappy) { onPick(option) }
        } label: {
            Text(label(option))
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.ink : Color.inkSecondary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: Theme.Metrics.smallButtonHeight - 4)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(HubPalette.sidebarSelection)
                            .overlay { Capsule(style: .continuous).strokeBorder(Color.stroke, lineWidth: scheme == .dark ? 1 : 0) }
                            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.08), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "chip", in: chip)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Search field on the canvas: rounded, hairline, magnifying glass, clear button.
struct HubSearchField: View {
    @Binding var text: String
    var prompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.inkTertiary)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .fieldPlaceholder(prompt, isShown: text.isEmpty)
                .font(.system(size: 13))
                .foregroundStyle(.ink)
                .focused(focused)
                .onExitCommand { text = "" }
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused.wrappedValue ? Color.accentRing : Color.strokeStrong,
                              lineWidth: focused.wrappedValue ? 1.5 : 1)
        }
        .animation(Theme.Motion.hover, value: focused.wrappedValue)
    }
}

// MARK: - Callouts

enum CalloutTone {
    case info, warning, error, success

    var color: Color {
        switch self {
        case .info: .accent
        case .warning: .warning
        case .error: .danger
        case .success: .success
        }
    }
}

/// Inline tinted note: "Bluetooth mics start slower…", "Secure typing is on in 1Password…".
struct Callout<Action: View>: View {
    var tone: CalloutTone
    var symbol: String
    var text: String
    @ViewBuilder var action: Action

    init(_ tone: CalloutTone, symbol: String, text: String, @ViewBuilder action: () -> Action) {
        self.tone = tone
        self.symbol = symbol
        self.text = text
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 18)
            Text(text)
                .typeface(.callout)
                .foregroundStyle(.ink.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(tone.color.opacity(0.18), lineWidth: 1)
        }
    }
}

extension Callout where Action == EmptyView {
    init(_ tone: CalloutTone, symbol: String, text: String) {
        self.init(tone, symbol: symbol, text: text) { EmptyView() }
    }
}

// MARK: - Icons and marks

/// Rounded tinted square behind an SF Symbol (settings rows, permission rows).
struct IconTile: View {
    var symbol: String
    var tint: Color = .accent
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// macOS's red count badge (System Settings' "1" beside General): white digits on a red capsule.
struct CountBadge: View {
    var count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5.5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color(nsColor: .systemRed), in: Capsule(style: .continuous))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The engine mark on history rows: P, F, Pro. Cloud Parakeet shares the local letter, so it carries a small
/// cloud as well as the cloud tint.
struct EngineGlyph: View {
    var engine: EngineID
    /// The OpenRouter provider that served the transcript, for the tooltip.
    var provider: String?
    /// The transcript shown is this model's clean-up of `engine`'s: a wand follows the letter.
    var cleanupModel: CleanupModel?
    /// The tooltip in full (`VersionDetails`), in place of the engine and provider alone.
    var details: String?

    var body: some View {
        let tint: Color = engine.isLocal ? .accent : HubPalette.apricotInk
        HStack(spacing: 1.5) {
            if engine.cloudAPI == .transcriptions {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 7, weight: .bold))
            }
            Text(engine.glyph)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
            if cleanupModel != nil {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 7.5, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(minWidth: 17, minHeight: 17)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(details ?? label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// "Parakeet v3 + Clean-up by GPT-6 Luna · via OpenAI": the accessibility label, and the tooltip without `details`.
    var label: String {
        let name = cleanupModel.map { TranscriptVersionKind.cleanup(of: engine, by: $0).displayName } ?? engine.displayName
        return provider.map { "\(name) · via \($0)" } ?? name
    }
}

/// transcribe-thing's mark: an ink-to-iris squircle holding a white capsule with five waveform bars.
struct BrandMark: View {
    var size: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(nsColor: .hex(0x2B2470)), Color(nsColor: .hex(0x6A5CF0))],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [Color.white.opacity(0.22), .clear], center: .topLeading,
                                      startRadius: 0, endRadius: size))
            Capsule(style: .continuous)
                .fill(.white)
                .frame(width: size * 0.66, height: size * 0.3)
            HStack(spacing: size * 0.045) {
                ForEach(Array([0.35, 0.7, 1.0, 0.62, 0.3].enumerated()), id: \.offset) { _, h in
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .hex(0x3A2F9E)))
                        .frame(width: size * 0.055, height: max(size * 0.05, size * 0.2 * h))
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color(nsColor: .hex(0x3A2F9E)).opacity(0.25), radius: size * 0.08, y: size * 0.04)
        .accessibilityHidden(true)
    }
}

/// The real app icon (bundle icon, or Resources/AppIcon.png when running the bare binary); the drawn mark otherwise.
struct AppIconMark: View {
    var size: CGFloat = 24

    var body: some View {
        if let image = AppIconSource.image {
            // The icon canvas keeps Apple's grid margin; the squircle fills about 80.5% of it.
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size / 0.805, height: size / 0.805)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            BrandMark(size: size)
        }
    }
}

@MainActor
private enum AppIconSource {
    static let image: NSImage? = {
        if Bundle.main.bundleURL.pathExtension == "app",
           let icon = NSImage(named: NSImage.applicationIconName) {
            return icon
        }
        return AppResources.url("AppIcon", ext: "png").flatMap(NSImage.init(contentsOf:))
    }()
}

/// Selected or hovered row fill inside a card, inset so its corners stay concentric with the card (16 − 4 = 12).
struct RowHighlight: View {
    var isSelected: Bool
    var isHovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(isSelected ? Color.accentSoft.opacity(0.7) : (isHovering ? Color.hover : .clear))
            .padding(4)
            .animation(Theme.Motion.hover, value: isHovering)
    }
}

// MARK: - Actions

/// Copy button that confirms with a checkmark for 1.2 s.
struct CopyButton: View {
    var text: String
    var copy: (String) -> Void
    @State private var copied = false

    var body: some View {
        Button {
            copy(text)
            withAnimation(Theme.Motion.snappy) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(Theme.Motion.fade) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? Color.success : Color.inkSecondary)
        }
        .buttonStyle(IconButtonStyle(size: 26))
        .help(copied ? "Copied" : "Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy transcript")
    }
}

import AppKit
import SwiftUI

// Hub-specific building blocks on top of the design system (Theme + Components).

// MARK: - Extra tokens

enum HubPalette {
    /// Apricot dark enough for text on light surfaces.
    static let apricotInk = Color(nsColor: Palette.dynamic("hub.apricotInk", light: .hex(0xB85A2A), dark: .hex(0xFFB38F)))
    /// Field fill on cards (search, key field, code in release notes).
    static let field = Color(nsColor: Palette.dynamic("hub.field", light: .hex(0xF5F5F5), dark: .hex(0x141414)))
}

// MARK: - Page scaffold

/// A Hub page, as a pane of System Settings: a native grouped `Form` (its rounded sections, rows and separators), the
/// title the window's (in the toolbar, `HubRoot`), a subtitle on a card at the top. A sub-page (Software Update)
/// gets a Back button in the toolbar.
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
        page
            .toolbar {
                if let back {
                    ToolbarItem(placement: .navigation) {
                        Button(action: back.action) {
                            Label("Back to \(back.title)", systemImage: "chevron.backward")
                        }
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Back to \(back.title)")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) { accessory }
            }
    }

    private var page: some View {
        Form {
            if let subtitle {
                // What the page is for, on a card of its own at the top, as System Settings' panes open.
                Section {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .formStyle(.grouped)
        // A page opens at its top, not scrolled to the first control that can take focus.
        .defaultScrollAnchor(.top)
        .environment(\.inNativeForm, true)
    }
}

extension HubPage where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, back: HubBackLink? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, back: back, accessory: { EmptyView() }, content: content)
    }
}

/// Where a sub-page's back button goes: "‹ General". ⌘[ follows it too.
struct HubBackLink {
    var title: String
    var action: () -> Void
}

enum HubLayout {
    static let sidebarWidth: CGFloat = 212
    static let pageTop: CGFloat = 20
    static let pageBottom: CGFloat = 36
    static let pageHorizontal: CGFloat = 36
    static let readableWidth: CGFloat = 780
}

/// A titled group of settings: in a form, one of its native sections (title above, footer below); elsewhere an
/// uppercase caption above a card.
struct HubGroup<Content: View, Trailing: View>: View {
    var title: String
    var footer: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @Environment(\.inNativeForm) private var inNativeForm

    init(_ title: String, footer: String? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        if inNativeForm {
            Section {
                content
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer(minLength: 8)
                    trailing
                }
            } footer: {
                if let footer {
                    Text(footer)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
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
                // Ink with a dot of the opposite: a black disc with a white dot on light, a white disc with a black
                // dot on dark (the accent being white there, a white dot vanished into it).
                Circle().fill(Color.accentFill)
                Circle().fill(Color.onAccent).frame(width: size * 0.38, height: size * 0.38)
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

/// A pop-up of choices: the system's menu button, "Never ⌃⌄". `title` isn't shown (the row says it): VoiceOver reads it.
struct HubMenuPicker<Value: Hashable>: View {
    var title: String
    var options: [Value]
    @Binding var selection: Value
    var label: (Value) -> String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// A few mutually exclusive choices: the system's segmented control. `title` is VoiceOver's, as the menu picker's.
struct HubSegmentedPicker<Value: Hashable>: View {
    var title: String
    var options: [Value]
    var selection: Value
    var label: (Value) -> String
    var onPick: (Value) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { selection }, set: { onPick($0) })) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// How General → Pasting's table names a way of dictating.
extension DictationMachine.Mode {
    /// The shortcut that starts a dictation this way: its symbol and, as the column's help, its name.
    var action: ShortcutAction {
        switch self {
        case .pushToTalk: .pushToTalk
        case .handsFree: .handsFree
        }
    }

    var chipTitle: String {
        switch self {
        case .pushToTalk: "Hold"
        case .handsFree: "Hands-free"
        }
    }
}

/// The model colors as small swatches, each the pill's ring in that color, graphite the plain pill in miniature; the
/// chosen one is ringed in ink.
struct ModelColorSwatches: View {
    var selection: ModelColor
    var onPick: (ModelColor) -> Void

    /// The width it lays out at, from the first circle's leading edge to the last one's trailing edge: 26 pt hit areas
    /// 4 pt apart, less the 4 pt each end's hit area reaches past its 18 pt circle.
    static let width = CGFloat(ModelColor.allCases.count) * 26 + CGFloat(ModelColor.allCases.count - 1) * 4 - 2 * 4

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ModelColor.allCases) { color in
                ModelColorSwatch(color: color, isSelected: color == selection) {
                    withAnimation(Theme.Motion.snappy) { onPick(color) }
                }
            }
        }
        .fixedSize()
        // The circles, not their hit areas, line up with the content around them.
        .padding(.horizontal, -4)
        .accessibilityElement(children: .contain)
    }
}

private struct ModelColorSwatch: View {
    var color: ModelColor
    var isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Ink: a colored ring would read as one of the colors. 25 pt across, so 2 pt of the popover keeps it
                // off the swatch.
                Circle().ring(1.5)
                    .fill(isSelected ? Color.ink : Color.strokeStrong, style: FillStyle(eoFill: true))
                    .frame(width: 25, height: 25)
                    .opacity(isSelected || hovering ? 1 : 0)
                swatch
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .help(color.title)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Opaque, so the popover behind doesn't tint it. An outer hairline holds a light ring's edge (orange, green) on a
    /// white popover.
    private var swatch: some View {
        let shape = Circle()
        return ZStack {
            if let accent = PillPalette.accent(for: color) {
                shape.fill(accent.ring)
            } else {
                graphite
            }
        }
        .overlay {
            shape.inset(by: -0.5).ring(0.5)
                .fill(Color.strokeStrong, style: FillStyle(eoFill: true))
        }
        .frame(width: 18, height: 18)
    }

    /// The pill's fill, sheen and lit hairline, which outlines it on the dark popover.
    private var graphite: some View {
        let shape = Circle()
        return shape.fill(Color(nsColor: Palette.pillFill.withAlphaComponent(1)))
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0)],
                                          startPoint: .top, endPoint: .center))
            }
            .overlay {
                shape.ring(0.5)
                    .fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.07)],
                                         startPoint: .top, endPoint: .bottom), style: FillStyle(eoFill: true))
            }
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

/// The engine mark on history rows: P, F, A, Pro, in the model's color (`ModelColor.markTint`, as the pill wears it).
/// The retired cloud Parakeet shares the local letter and color, so it carries a small cloud; a clean-up, a wand after
/// the letter.
/// A selection's polish in History: the wand (Translate's glyph for its translation), in the color of the model that
/// wrote it.
struct SelectionGlyph: View {
    var model: PolishSelectionModel
    var translated = false
    /// The tooltip in full (`VersionDetails`).
    var details: String?
    var colors: ModelColors = .default

    var body: some View {
        let tint = colors[model.choice].markTint
        Image(systemName: translated ? "translate" : "wand.and.sparkles")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(details ?? label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    private var label: String {
        (translated ? TranscriptVersionKind.selectionTranslation(model) : .selection(model)).displayName
    }
}

struct EngineGlyph: View {
    var engine: EngineID
    /// The OpenRouter provider that served the transcript, for the tooltip.
    var provider: String?
    /// The transcript shown is this model's clean-up of `engine`'s (an old one: nothing makes clean-ups any more): a
    /// wand follows the letter.
    var cleanupModel: CleanupModel?
    /// The tooltip in full (`VersionDetails`), in place of the engine and provider alone.
    var details: String?
    /// The models' colors (`AppSettings.modelColors`).
    var colors: ModelColors = .default

    /// The color of the model that made it: the retired Gemini 3.1 Pro and Gemini 4 Argon wear Flash's, the retired
    /// cloud Parakeet and an old clean-up of Parakeet's text Parakeet's.
    var color: ModelColor {
        colors[ModelChoice(engine: engine)]
    }

    var body: some View {
        let tint = color.markTint
        HStack(spacing: 1.5) {
            if engine == .parakeetCloud {
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

/// transcribe-thing's mark: a black-to-graphite squircle holding a white capsule with five waveform bars.
struct BrandMark: View {
    var size: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(nsColor: .hex(0x3A3A3A)), Color(nsColor: .hex(0x000000))],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [Color.white.opacity(0.22), .clear], center: .topLeading,
                                      startRadius: 0, endRadius: size))
            Capsule(style: .continuous)
                .fill(.white)
                .frame(width: size * 0.66, height: size * 0.3)
            HStack(spacing: size * 0.045) {
                ForEach(Array([0.35, 0.7, 1.0, 0.62, 0.3].enumerated()), id: \.offset) { _, h in
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .hex(0x111111)))
                        .frame(width: size * 0.055, height: max(size * 0.05, size * 0.2 * h))
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: size * 0.08, y: size * 0.04)
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
    @Environment(\.inNativeForm) private var inNativeForm

    /// In a form the row is the form's own, which marks nothing: the row's radio or check says what's picked.
    var body: some View {
        if !inNativeForm { highlight }
    }

    private var highlight: some View {
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

/// The ⓘ beside a stat: what it means, in a popover as the pointer rests on it (or on a click). A tooltip on the whole
/// tile came only after the system's long delay, and nothing said it was there.
struct InfoHint: View {
    var text: String
    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(hovering || shown ? Color.inkSecondary : Color.inkTertiary)
            .padding(5)
            .contentShape(Rectangle())
            .padding(-5)
            .onHover { inside in
                hovering = inside
                if !inside { shown = false }
            }
            .task(id: hovering) {
                guard hovering else { return }
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled, hovering { shown = true }
            }
            .onTapGesture { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240, alignment: .leading)
                    .padding(12)
            }
            .accessibilityLabel(text)
    }
}

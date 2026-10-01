import SwiftUI
import UniformTypeIdentifiers

/// The three models in the user's order: the main model every dictation starts on (a radio), which others the Switch
/// model shortcut steps to (a switch each), the order it steps in (drag a row by its handle), and each one's color on
/// the pill (its tile). Then where Parakeet runs (on this Mac: download, use, delete, storage; or through OpenRouter),
/// for Parakeet and clean-up alike, and the OpenRouter key.
struct ModelsPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(ModelStore.self) private var models
    @Environment(AppSettings.self) private var settings
    @Environment(OpenRouterAccount.self) private var account

    @State private var keyFocusRequest = 0
    @State private var freeBytes: Int64?
    /// Narrow window: the local model drops "Private" and "Offline" and keeps "Recommended".
    @State private var compactBadges = false
    /// The model being dragged by its handle, while it is.
    @State private var dragged: ModelChoice?

    /// Below this list width the local model's full badge row stops fitting beside its actions.
    static let compactBadgeWidth: CGFloat = 640

    var body: some View {
        ScrollViewReader { proxy in
            HubPage("Models", subtitle: "Every dictation starts on your main model. Switch to another while you talk.") {
                HubGroup("Your models",
                         footer: "Drag to change the order. Switch model steps through the ones that are on, starting from your main model. Click a model’s icon to change its color.") {
                    SwitchModelLineView(lineup: settings.lineup, binding: settings.shortcuts[.switchModel],
                                        blocked: settings.lineup.steps.filter { !hub.readiness(of: $0).isUsable }) {
                        hub.show(.shortcuts)
                    }
                    SettingsGroup {
                        ForEach(settings.lineup.order) { choice in
                            LineupRow(choice: choice, dragged: $dragged,
                                      chooseMain: { chooseMain(choice, proxy: proxy) },
                                      focusKey: { focusKey(proxy) })
                        }
                    }
                }
                HubGroup("Hands-free") {
                    SettingsGroup {
                        SettingsRow(title: "Hands-free dictations use", subtitle: handsFreeSubtitle,
                                    systemImage: "lock.fill", iconTint: .inkSecondary) {
                            HubMenuPicker(options: handsFreeOptions, selection: handsFreeModel,
                                          label: handsFreeLabel)
                        }
                    }
                }
                HubGroup("Where Parakeet runs", footer: "For Parakeet v3, with or without clean-up.") {
                    SettingsGroup {
                        ForEach(EngineID.parakeetRuntimes) { engine in row(engine, proxy: proxy) }
                    }
                    .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactBadgeWidth } action: { compact in
                        compactBadges = compact
                    }
                    storageLine
                }
                HubGroup("OpenRouter") {
                    OpenRouterKeyCard(focusRequest: keyFocusRequest)
                        .id(ModelsAnchor.key)
                }
            }
        }
        // A row's drag let go anywhere else on the page (or canceled, then the page left) ends here too.
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            dragged = nil
            return false
        }
        .onDisappear { dragged = nil }
        .task(id: models.diskUsageBytes) {
            freeBytes = hub.paths.freeDiskBytes()
        }
        .task { account.refreshIfStale(maxAge: 300) }
    }

    private func row(_ engine: EngineID, proxy: ScrollViewProxy) -> some View {
        ModelRow(
            engine: engine,
            isSelected: settings.parakeetEngine == engine,
            isPendingSwitch: models.pendingSelection == engine,
            compactBadges: compactBadges,
            choose: { choose(engine, proxy: proxy) },
            use: { use(engine) },
            focusKey: { focusKey(proxy) })
    }

    // MARK: Main model

    /// Makes `choice` the main model. One the OpenRouter key can't pay for leads to the key instead, even while it
    /// also waits for Parakeet's download; one on Parakeet on this Mac starts its download, or its load, so the next
    /// dictation doesn't wait for it.
    private func chooseMain(_ choice: ModelChoice, proxy: ScrollViewProxy) {
        guard settings.lineup.main != choice else { return }
        let parakeet = settings.parakeetEngine
        if choice.needsOpenRouter(parakeet: parakeet) {
            switch hub.readiness(of: .geminiFlash) {
            case .needsKey, .keyProblem:
                focusKey(proxy)
                return
            case .ready, .warming, .needsDownload, .failed:
                break
            }
        }
        withAnimation(Theme.Motion.snappy) { settings.lineup.main = choice }
        guard choice.usesLocalParakeet(parakeet: parakeet) else { return }
        switch models.state(of: parakeet) {
        case .notInstalled: models.download(parakeet)
        case .installed: models.prepare(parakeet)
        case .downloading, .preparing, .ready, .failed: break
        }
    }

    // MARK: Where Parakeet runs

    private func choose(_ engine: EngineID, proxy: ScrollViewProxy) {
        guard settings.parakeetEngine != engine else { return }
        switch hub.readiness(of: engine) {
        case .ready, .warming, .needsDownload, .failed:
            // Downloads keep the current engine until the new one lands (ModelStore finishes the switch
            // even if this window closes).
            withAnimation(Theme.Motion.snappy) { models.selectWhenInstalled(engine) }
        case .needsKey, .keyProblem:
            focusKey(proxy)
        }
    }

    private func use(_ engine: EngineID) {
        withAnimation(Theme.Motion.snappy) { models.select(engine) }
    }

    private func focusKey(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.Motion.expand) { proxy.scrollTo(ModelsAnchor.key, anchor: .top) }
        keyFocusRequest += 1
    }

    // MARK: Storage

    // MARK: Hands-free

    /// The main model (no switch), then every other model of the lineup.
    private var handsFreeOptions: [ModelChoice?] {
        [nil] + settings.lineup.order.filter { $0 != settings.lineup.main }
    }

    /// A model that has become the main one since reads as the main model: there's nothing to switch to.
    private var handsFreeModel: Binding<ModelChoice?> {
        let settings = settings
        return Binding(get: { settings.handsFreeModel == settings.lineup.main ? nil : settings.handsFreeModel },
                       set: { settings.handsFreeModel = $0 })
    }

    private func handsFreeLabel(_ choice: ModelChoice?) -> String {
        choice?.title(parakeet: settings.parakeetEngine) ?? "Main model"
    }

    private var handsFreeSubtitle: String {
        let key = settings.shortcuts[.handsFree]?.compactDescription ?? "The hands-free shortcut"
        return "\(key) switches to it as it starts, like Switch model. Holding the key stays on your main model."
    }

    private var storageLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 11, weight: .medium))
            Text(storageText)
                .monospacedDigit()
        }
        .typeface(.callout)
        .foregroundStyle(.inkSecondary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    /// "Takes 632 MB on disk · 23.6 GB free on this Mac"; just the free space before anything is downloaded.
    private var storageText: String {
        let free = freeBytes.flatMap { $0 > 0 ? "\(Fmt.bytes($0)) free on this Mac" : nil }
        guard models.diskUsageBytes > 0 else { return free ?? "Nothing downloaded yet" }
        let used = "Takes \(Fmt.bytes(models.diskUsageBytes)) on disk"
        return free.map { "\(used) · \($0)" } ?? used
    }
}

enum ModelsAnchor: Hashable {
    case key
}

// MARK: - Your models

/// What the Switch model shortcut does, with the user's own binding as key caps and the models it steps through
/// ("Parakeet → Clean-up → Gemini", the main model first, a step that can't run now dimmed); or what's missing for it
/// to work.
private struct SwitchModelLineView: View {
    var lineup: ModelLineup
    var binding: Shortcut?
    /// Steps Switch model skips for now (no usable key, not downloaded): their rows below say why.
    var blocked: [ModelChoice]
    var openShortcuts: () -> Void

    var body: some View {
        let status = SwitchModelLine.status(binding: binding, lineup: lineup)
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.isReady ? Color.accent : Color.inkTertiary)
            switch status {
            case .ready(let binding):
                // Key caps mid-sentence; the sentence is the accessibility label.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        Text("Press")
                        ShortcutChips(shortcut: binding, size: .small)
                        Text("while dictating:")
                        chain
                    }
                    HStack(spacing: 5) {
                        Text("Press")
                        ShortcutChips(shortcut: binding, size: .small)
                        Text("while dictating to step through them in this order.")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SwitchModelLine.explanation(status, lineup: lineup, blocked: blocked))
            case .alone, .unbound:
                Text(SwitchModelLine.explanation(status, lineup: lineup))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status == .unbound {
                Button("Set Shortcut", action: openShortcuts)
                    .buttonStyle(.appQuiet)
                    .fixedSize()
            }
        }
        .typeface(.callout)
        .foregroundStyle(.inkSecondary)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .animation(Theme.Motion.snappy, value: lineup)
    }

    /// The cycle by short names, the main model's in ink, a blocked step's faint.
    private var chain: some View {
        HStack(spacing: 5) {
            ForEach(Array(lineup.cycle.enumerated()), id: \.element) { index, choice in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.inkTertiary)
                }
                Text(choice.shortName)
                    .fontWeight(index == 0 ? .semibold : nil)
                    .foregroundStyle(index == 0 ? Color.ink : blocked.contains(choice) ? Color.inkTertiary.opacity(0.7)
                                     : Color.inkSecondary)
            }
        }
        .fixedSize()
    }
}

private extension SwitchModelLine.Status {
    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

/// One model of the lineup: a handle to drag it, a radio that makes it the main model, its tile (its color), what it
/// is and how it's doing, and a switch that includes it in Switch model ("Main" on the main model, which is always
/// included).
private struct LineupRow: View {
    var choice: ModelChoice
    @Binding var dragged: ModelChoice?
    var chooseMain: () -> Void
    var focusKey: () -> Void

    @Environment(HubContext.self) private var hub
    @Environment(ModelStore.self) private var models
    @Environment(AppSettings.self) private var settings
    @Environment(OpenRouterAccount.self) private var account
    @State private var hovering = false

    private var isMain: Bool { settings.lineup.main == choice }
    private var parakeet: EngineID { settings.parakeetEngine }
    private var index: Int { settings.lineup.order.firstIndex(of: choice) ?? 0 }
    private var isLast: Bool { index == settings.lineup.order.count - 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                handle
                RadioDot(isOn: isMain)
            }
            ModelColorButton(choice: choice, parakeet: parakeet)
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.modelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text(factLine)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let providerNote {
                    ProviderLine(text: providerNote)
                }
                status
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                actions
                trailing
            }
        }
        .padding(.leading, Theme.Spacing.md - 6)
        .padding(.trailing, Theme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .background { RowHighlight(isSelected: isMain, isHovering: hovering) }
        .contentShape(Rectangle())
        .onTapGesture(perform: chooseMain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.snappy, value: isMain)
        .onDrop(of: [.plainText], delegate: LineupDropDelegate(target: choice, dragged: $dragged, settings: settings))
        .contextMenu {
            Button("Make Main Model", action: chooseMain)
                .disabled(isMain)
            Divider()
            Button("Move Up") { move(by: -1) }
                .disabled(index == 0)
            Button("Move Down") { move(by: 1) }
                .disabled(isLast)
            Divider()
            // A submenu with the color checked: the tile's colors without the popover (and for VoiceOver).
            Picker("Pill Color", selection: color) {
                ForEach(ModelColor.allCases) { Text($0.title).tag($0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isMain ? .isSelected : [])
        .accessibilityValue(isMain ? "Main model"
            : settings.lineup.isSwitchable(choice) ? "Included when switching" : "Not included when switching")
        .accessibilityAction(named: "Make Main Model", chooseMain)
        .accessibilityAction(named: "Move Up") { move(by: -1) }
        .accessibilityAction(named: "Move Down") { move(by: 1) }
    }

    /// Drags the row to another place in the lineup; a click on it does nothing (the rest of the row makes it main).
    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.inkTertiary)
            .frame(width: 16, height: 36)
            .contentShape(Rectangle())
            .onTapGesture {}
            .pointerStyle(.grabIdle)
            .help("Drag to reorder")
            .onDrag {
                dragged = choice
                return NSItemProvider(object: choice.rawValue as NSString)
            }
            .accessibilityHidden(true)
    }

    private func move(by offset: Int) {
        let target = index + offset
        guard settings.lineup.order.indices.contains(target) else { return }
        withAnimation(Theme.Motion.snappy) { settings.lineup.move(choice, to: target) }
    }

    // MARK: Copy

    /// What the model is like, with where Parakeet runs.
    private var factLine: String {
        let place = parakeet.isLocal ? "on this Mac" : "through OpenRouter"
        switch choice {
        case .parakeet:
            return parakeet.isLocal ? "Fastest · private · on this Mac" : "Fast · through OpenRouter · ≈ $0.09 per hour of audio"
        case .cleanup:
            return "\(EngineID.parakeet.modelName) \(place) transcribes, then \(CleanupModel.default.modelName) tidies the text."
        case .gemini:
            return "Most accurate · thinks before it writes · pay per use"
        }
    }

    /// Who serves it through OpenRouter; nil for Parakeet on this Mac.
    private var providerNote: String? {
        switch choice {
        case .parakeet: ProviderNote.text(parakeet)
        case .cleanup: "\(CleanupModel.default.modelName) served by \(CleanupModel.default.providerName) only."
        case .gemini: ProviderNote.text(.geminiFlash)
        }
    }

    // MARK: Status and controls

    private var status: some View {
        let summary = EngineSummary.make(choice: choice, parakeet: parakeet, localState: models.state(of: parakeet),
                                         keyStatus: account.status, localError: models.lastErrors[parakeet])
        return HStack(spacing: 4) {
            StatusDot(color: summary.tone.color, size: 6, pulsing: summary.tone == .progress)
                .frame(width: 12, height: 12)
            Text(summary.status)
                .typeface(.callout)
                .monospacedDigit()
                .foregroundStyle(summary.tone == .negative ? Color.danger : Color.inkSecondary)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
    }

    @ViewBuilder private var actions: some View {
        switch hub.readiness(of: choice) {
        case .needsDownload:
            Button {
                models.download(.parakeet)
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
        case .needsKey:
            Button("Add Key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .keyProblem:
            Button("Update Key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .failed:
            // Only Parakeet on this Mac fails this way: the same Retry as under Where Parakeet runs.
            Button("Retry") { models.download(.parakeet) }
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .ready, .warming:
            EmptyView()
        }
    }

    /// "Main" on the main model, which Switch model always includes; a switch on the others.
    @ViewBuilder private var trailing: some View {
        if isMain {
            StateCapsule(title: "Main")
                .help("Every dictation starts here. It’s always included when switching.")
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        } else {
            Toggle("", isOn: switchable)
                .toggleStyle(.appSwitch)
                .labelsHidden()
                .accessibilityLabel("Include \(choice.modelName) when switching")
                .help(settings.lineup.isSwitchable(choice) ? "Included when switching models" : "Not included when switching models")
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private var switchable: Binding<Bool> {
        let settings = settings, choice = choice
        return Binding(get: { settings.lineup.isSwitchable(choice) },
                       set: { on in withAnimation(Theme.Motion.snappy) { settings.lineup.setSwitchable(choice, on) } })
    }

    private var color: Binding<ModelColor> {
        let settings = settings, choice = choice
        return Binding(get: { settings.modelColors[choice] },
                       set: { color in withAnimation(Theme.Motion.snappy) { settings.modelColors[choice] = color } })
    }
}

// MARK: - Model colors

/// A lineup row's tile, which opens the model's colors (`ModelColorPopover`). Its click is its own: it never makes the
/// model main.
private struct ModelColorButton: View {
    var choice: ModelChoice
    var parakeet: EngineID

    @Environment(AppSettings.self) private var settings
    @State private var picking = false
    @State private var hovering = false

    private static let size: CGFloat = 36

    var body: some View {
        let color = settings.modelColors[choice]
        let tile = RoundedRectangle(cornerRadius: Self.size * 0.28, style: .continuous)
        Button { picking = true } label: {
            ModelChoiceIcon(choice: choice, parakeet: parakeet, color: color, size: Self.size)
                .overlay {
                    // Hovered or open: a ring 3 pt out says the tile is a control.
                    RoundedRectangle(cornerRadius: Self.size * 0.28 + 3, style: .continuous).ring(1.5)
                        .fill(Color.strokeStrong, style: FillStyle(eoFill: true))
                        .padding(-3)
                        .opacity(hovering || picking ? 1 : 0)
                }
                .contentShape(tile)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering || picking)
        .help("Change pill color")
        .accessibilityLabel("Pill color for \(choice.modelName)")
        .accessibilityValue(color.title)
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            ModelColorPopover(choice: choice, parakeet: parakeet, color: color) { picked in
                settings.modelColors[choice] = picked
            }
        }
    }
}

/// A model's colors: its pill in the color, then the swatches. A pick applies at once (the tile behind, the sidebar
/// chip, History's marks and a pill that is dictating fade to it), and the popover stays open to compare.
struct ModelColorPopover: View {
    var choice: ModelChoice
    var parakeet: EngineID
    var color: ModelColor
    var onPick: (ModelColor) -> Void

    /// The swatches' circles span it, and the preview and the header line up on their ends.
    static let contentWidth = ModelColorSwatches.width
    static let width: CGFloat = contentWidth + 2 * 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelColorPreview(choice: choice, parakeet: parakeet, color: color)
                .frame(width: Self.contentWidth, height: 84)
            HStack(spacing: 0) {
                Text("Pill color")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                Spacer(minLength: 8)
                Text(color.title)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
            }
            ModelColorSwatches(selection: color, onPick: onPick)
        }
        .padding(14)
        .frame(width: Self.width)
    }
}

/// A still listening pill with its chip, in `color`: the chip names the model the colors are for.
private struct ModelColorPreview: View {
    var choice: ModelChoice
    var parakeet: EngineID
    var color: ModelColor

    @State private var model: PillModel

    init(choice: ModelChoice, parakeet: EngineID, color: ModelColor) {
        self.choice = choice
        self.parakeet = parakeet
        self.color = color
        let model = PillModel.preview(phase: .listening, level: 0.7)
        model.settings.parakeetEngine = parakeet
        model.sessionModel = choice
        // A preview's chip stays up.
        model.flashChip()
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            StageBackground(cornerRadius: 12)
            // Room above for the chip, so the pill and its chip sit centered together.
            PillView(model: model)
                .padding(.top, PillMetrics.chipLift)
        }
        .environment(\.pillStaticRendering, true)
        // The preview's own settings carry the color, as the app's carry the user's.
        .onChange(of: color, initial: true) { _, color in model.settings.modelColors[choice] = color }
        .accessibilityHidden(true)
    }
}

/// Live reordering: a dragged row takes the place of the row it enters, and the others make room. Only a row's own
/// drag counts: `dragged` is set by its handle and cleared by any drop on the page, so text dragged in from elsewhere
/// never moves a row.
private struct LineupDropDelegate: DropDelegate {
    var target: ModelChoice
    @Binding var dragged: ModelChoice?
    var settings: AppSettings

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target, let index = settings.lineup.order.firstIndex(of: target) else { return }
        withAnimation(Theme.Motion.snappy) { settings.lineup.move(dragged, to: index) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragged == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let wasOurs = dragged != nil
        dragged = nil
        return wasOurs
    }
}

/// "✓ In use", "✓ Main": a state, not a control.
private struct StateCapsule: View {
    var title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(.accent)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Color.accentSoft, in: Capsule(style: .continuous))
        .fixedSize()
    }
}

/// "Served by Together.", under a model's fact line, with a server glyph.
private struct ProviderLine: View {
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "server.rack")
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 12)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .typeface(.callout)
        .foregroundStyle(.inkTertiary)
    }
}

// MARK: - Where Parakeet runs

/// Parakeet v3 on this Mac (download, use, delete) or through OpenRouter: where Parakeet and clean-up run
/// (`AppSettings.parakeetEngine`).
private struct ModelRow: View {
    var engine: EngineID
    var isSelected: Bool
    var isPendingSwitch: Bool
    var compactBadges: Bool
    var choose: () -> Void
    var use: () -> Void
    var focusKey: () -> Void

    @Environment(HubContext.self) private var hub
    @Environment(ModelStore.self) private var models
    @Environment(OpenRouterAccount.self) private var account
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false
    @State private var confirmingDelete = false

    private var state: LocalModelState { models.state(of: engine) }
    private var readiness: EngineReadiness { hub.readiness(of: engine) }
    /// A model Switch model reaches runs on Parakeet, so the selected runtime is in use.
    private var lineupUsesParakeet: Bool { settings.lineup.cycle.contains { $0 != .gemini } }
    /// The row's title: the place, as the section names the model.
    private var runtimeName: String { engine.isLocal ? "On this Mac" : "Through OpenRouter" }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RadioDot(isOn: isSelected)
            // Parakeet either way, in Parakeet's color: the glyph and the title say where.
            ModelChoiceIcon(choice: .parakeet, parakeet: engine, color: settings.modelColors[.parakeet], size: 36)
            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    titleLine(badges: badges)
                    titleLine(badges: [])
                }
                Text(engine.factLine)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                if let note = ProviderNote.text(engine) {
                    ProviderLine(text: note)
                }
                status
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .background { RowHighlight(isSelected: isSelected, isHovering: hovering) }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var badges: [String] {
        engine.badges.filter { $0 != "Cloud" && !(compactBadges && EngineID.privacyBadges.contains($0)) }
    }

    private func titleLine(badges: [String]) -> some View {
        HStack(spacing: 6) {
            Text(runtimeName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.ink)
                .lineLimit(1)
                .fixedSize()
            ForEach(badges, id: \.self) { Badge.engine($0) }
        }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        if engine.isLocal {
            localStatus
        } else {
            ModelStatusText(keyStatus: account.status)
        }
    }

    @ViewBuilder private var localStatus: some View {
        switch state {
        case .downloading(let progress):
            BarThenCaption {
                ProgressBar(fraction: progress.fraction, height: 4)
                    .frame(width: 120)
            } caption: {
                HStack(spacing: 8) {
                    Text(downloadLabel(progress))
                        .typeface(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.inkSecondary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    pendingNote
                }
            }
        case .preparing(let since):
            BarThenCaption {
                ShimmerBar(height: 4).frame(width: 100)
            } caption: {
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        let elapsed = context.date.timeIntervalSince(since)
                        Text("Loading model into memory… up to a minute the first time" + (elapsed >= 20 ? " · \(Fmt.duration(elapsed))" : ""))
                            .typeface(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                    }
                    pendingNote
                }
            }
        case .failed(let message):
            HStack(spacing: 4) {
                StatusDot(color: .danger, size: 6).frame(width: 12, height: 12)
                // ModelStore's messages say what failed (download, load, disk space) on their own.
                Text(message.isEmpty ? "Something went wrong. Try again." : message)
                    .typeface(.callout)
                    .foregroundStyle(.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
        case .notInstalled, .installed, .ready:
            HStack(spacing: 6) {
                ModelStatusText(state: state, engine: engine)
                pendingNote
            }
        }
    }

    @ViewBuilder private var pendingNote: some View {
        if isPendingSwitch {
            Text("· Switches when ready")
                .typeface(.callout)
                .foregroundStyle(.accent)
                .lineLimit(1)
        }
    }

    private func downloadLabel(_ p: DownloadProgress) -> String {
        let amount = p.totalBytes > 0
            ? "\(Fmt.bytes(p.bytesReceived)) of \(Fmt.bytes(p.totalBytes))"
            : "\(p.percent)%"
        guard let eta = p.secondsRemaining else { return amount }
        return "\(amount) · \(Fmt.eta(eta))"
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if isSelected && readiness.isUsable && lineupUsesParakeet {
                StateCapsule(title: "In use")
            }
            if engine.isLocal {
                localActions
            } else {
                cloudActions
            }
        }
    }

    @ViewBuilder private var localActions: some View {
        switch state {
        case .notInstalled:
            Button {
                models.download(engine)
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
        case .failed:
            Button("Retry") { models.download(engine) }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            if case .modelLoadFailed? = models.lastErrors[engine] {
                // The files downloaded but don't load: Retry loads the same files again, this replaces them.
                Button("Download Again") {
                    let models = models
                    Task { await models.reinstall(engine) }
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .help("Delete \(engine.displayName) and download it again")
            } else {
                // A partial download or a half-removed install can go even while selected: nothing is loaded.
                deleteButton(isEnabled: true, freedBytes: nil)
            }
        case .downloading:
            Button("Cancel") { models.cancelDownload(engine) }
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .installed, .ready, .preparing:
            if !isSelected {
                Button("Use", action: use)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
            deleteButton(isEnabled: !(isSelected && lineupUsesParakeet), freedBytes: engine.approxDownloadBytes)
        }
    }

    @ViewBuilder private var cloudActions: some View {
        switch readiness {
        case .needsKey:
            Button("Add Key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .keyProblem:
            Button("Update Key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .ready, .warming, .needsDownload, .failed:
            if !isSelected {
                Button("Use", action: use)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }

    private func deleteButton(isEnabled: Bool, freedBytes: Int64?) -> some View {
        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(IconButtonStyle(size: 26))
        .disabled(!isEnabled)
        .help(isEnabled ? "Delete \(engine.displayName)" : "Switch Parakeet to OpenRouter to delete it.")
        .accessibilityLabel("Delete \(engine.displayName)")
        .popover(isPresented: $confirmingDelete, arrowEdge: .bottom) {
            DeleteModelConfirmation(engine: engine, freedBytes: freedBytes) {
                confirmingDelete = false
                let models = models
                Task { await models.delete(engine) }
            } cancel: {
                confirmingDelete = false
            }
        }
    }
}

/// A progress bar with its caption on the same line, or under it when the row is too narrow for both (a narrow
/// window, beside "In use" and an action button), so the caption keeps its end: "about 40 s left".
private struct BarThenCaption<Bar: View, Caption: View>: View {
    private let bar: Bar
    private let caption: Caption

    init(@ViewBuilder bar: () -> Bar, @ViewBuilder caption: () -> Caption) {
        self.bar = bar()
        self.caption = caption()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                bar
                caption
            }
            VStack(alignment: .leading, spacing: 6) {
                bar
                caption
            }
        }
    }
}

private struct DeleteModelConfirmation: View {
    var engine: EngineID
    var freedBytes: Int64?
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(engine.displayName)?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.ink)
            Text(message)
                .typeface(.callout)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .keyboardShortcut(.cancelAction)
                Button("Delete", action: confirm)
                    .buttonStyle(PrimaryButtonStyle(size: .small, tint: .danger))
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private var message: String {
        let size = freedBytes.map { "This frees \(Fmt.bytes($0)). " } ?? ""
        return "\(size)You can download it again anytime."
    }
}

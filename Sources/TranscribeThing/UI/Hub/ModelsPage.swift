import SwiftUI
import UniformTypeIdentifiers

/// The models in the user's order: the main model every dictation starts on (a radio), which others the Switch model
/// shortcut steps to (a switch), the order it steps in (drag a row by its handle), and each one's color on the pill
/// (its tile), and how hard each Gemini model thinks for dictation (its Reasoning menu; calls pick their own in
/// General). Then the model hands-free starts on, the model on this Mac, GigaAM v3 (download, delete, storage), with the
/// files retired models left there to delete, and the API keys: OpenRouter's, and the user's own OpenAI-compatible endpoint that can take Gemini's requests instead.
struct ModelsPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(ModelStore.self) private var models
    @Environment(AppSettings.self) private var settings
    @Environment(OpenRouterAccount.self) private var account

    @State private var keyFocusRequest = 0
    @State private var proxyFocusRequest = 0
    /// The model being dragged by its handle, while it is.
    @State private var dragged: ModelChoice?

    var body: some View {
        ScrollViewReader { proxy in
            HubPage("Models") {
                HubGroup("Your models", footer: lineupFooter) {
                    // Only when it can't work: Switch model has no shortcut.
                    if SwitchModelLine.status(binding: settings.shortcuts[.switchModel], lineup: settings.lineup) == .unbound {
                        SwitchModelUnboundLine { hub.show(.shortcuts) }
                    }
                    SettingsGroup {
                        ForEach(settings.lineup.order) { choice in
                            LineupRow(choice: choice, dragged: $dragged,
                                      chooseMain: { chooseMain(choice, proxy: proxy) },
                                      focusKey: { focusKey(for: choice, proxy) })
                        }
                    }
                }
                HubGroup("Hands-free") {
                    SettingsGroup {
                        SettingsRow(title: "Hands-free dictations use", subtitle: handsFreeSubtitle,
                                    systemImage: "lock.fill", iconTint: .inkSecondary) {
                            HubMenuPicker(title: "Hands-free dictations use", options: handsFreeOptions,
                                          selection: handsFreeModel, label: handsFreeLabel)
                        }
                    }
                }
                HubGroup("On this Mac", footer: onThisMacFooter) {
                    SettingsGroup {
                        // Ids of their own: the form mixes its sections up over ids that repeat between them
                        // (Your models has a "gigaam" too).
                        ForEach(LocalModel.all, id: \.onThisMacRowID) { model in
                            ModelRow(model: model)
                        }
                        ForEach(models.leftoverModels, id: \.onThisMacRowID) { leftover in
                            LeftoverModelRow(model: leftover)
                        }
                    }
                }
                APIKeysGroup(keyFocusRequest: keyFocusRequest, endpointFocusRequest: proxyFocusRequest)
            }
        }
        // A row's drag let go anywhere else on the page (or canceled, then the page left) ends here too.
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            dragged = nil
            return false
        }
        .onDisappear { dragged = nil }
        .task {
            account.refreshIfStale(maxAge: 300)
            hub.proxy.refreshIfStale(maxAge: 300)
        }
    }

    // MARK: Main model

    /// Makes `choice` the main model. One the key can't pay for leads to the key instead; a model on this Mac starts
    /// its download, or its load, so the next dictation doesn't wait for it.
    private func chooseMain(_ choice: ModelChoice, proxy: ScrollViewProxy) {
        guard settings.lineup.main != choice else { return }
        if choice.isGemini {
            switch hub.readiness(of: choice) {
            case .needsKey, .needsEndpoint, .keyProblem:
                focusKey(for: choice, proxy)
                return
            case .ready, .warming, .needsDownload, .failed:
                break
            }
        }
        withAnimation(Theme.Motion.snappy) { settings.lineup.main = choice }
        guard choice.isLocal else { return }
        switch models.state(of: choice.engine) {
        case .notInstalled: models.download(choice.engine)
        case .installed: models.prepare(choice.engine)
        case .downloading, .preparing, .ready, .failed: break
        }
    }

    private func focusKey(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.Motion.expand) { proxy.scrollTo(ModelsAnchor.key, anchor: .top) }
        keyFocusRequest += 1
    }

    /// The key `choice` goes with: the endpoint's row of API keys while it takes Gemini's requests, else the
    /// OpenRouter key.
    private func focusKey(for choice: ModelChoice, _ proxy: ScrollViewProxy) {
        guard hub.provider(for: choice.engine) == .vertexProxy else {
            focusKey(proxy)
            return
        }
        withAnimation(Theme.Motion.expand) { proxy.scrollTo(ModelsAnchor.proxy, anchor: .top) }
        proxyFocusRequest += 1
    }

    // MARK: Hands-free

    /// The main model (no switch), then the models Switch model steps to.
    private var handsFreeOptions: [ModelChoice?] {
        [nil] + settings.lineup.steps
    }

    private var handsFreeModel: Binding<ModelChoice?> {
        let settings = settings
        return Binding(get: { settings.handsFreeChoice }, set: { settings.handsFreeModel = $0 })
    }

    /// What the list can't say by itself: what the dot and the switches mean, what Reasoning costs, and where calls
    /// pick theirs.
    private var lineupFooter: String {
        let keys = settings.shortcuts[.switchModel].map { " (\($0.compactDescription))" } ?? ""
        return "The dot picks the main model: every dictation starts on it. Models switched on are the ones "
            + "Switch model\(keys) steps through while you dictate. " + ReasoningCopy.footer + " " + ReasoningCopy.calls
    }

    /// Which key the setting is about.
    private var handsFreeSubtitle: String {
        let key = settings.shortcuts[.handsFree]?.compactDescription ?? "The hands-free shortcut"
        return "The model \(key) starts on."
    }

    private func handsFreeLabel(_ choice: ModelChoice?) -> String {
        choice.map(\.modelName) ?? "Main model"
    }

    // MARK: On this Mac

    /// Only while a retired model's files are still on this Mac (`LeftoverModelCopy`).
    private var onThisMacFooter: String? {
        LeftoverModelCopy.footer(models.leftoverModels)
    }

}

/// What Models says about Reasoning, and where calls pick theirs.
enum ReasoningCopy {
    static let footer = "Higher Reasoning thinks longer before it writes: answers come slower and cost more."
    static let calls = "Calls pick their own model and level in General → Calls."
}

/// A Gemini model's level (`AppSettings.reasoningEfforts`) on its lineup row, after its status: "Reasoning: Medium", a
/// borderless menu of the levels it takes. Its click is its own: it never makes the model main.
private struct ReasoningMenu: View {
    var engine: EngineID

    @Environment(AppSettings.self) private var settings

    var body: some View {
        let current = settings.reasoningEffort(for: engine) ?? .medium
        Menu {
            Picker("Reasoning", selection: effort) {
                ForEach(engine.reasoningEfforts, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            // Styled as the status beside it: a plain label with a small chevron, so it reads as a setting of the row
            // rather than a second title.
            HStack(spacing: 3) {
                Text("Reasoning: \(current.title)")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.inkTertiary)
            }
            .typeface(.callout)
            .foregroundStyle(.inkSecondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(ReasoningCopy.footer)
        .accessibilityLabel("Reasoning for \(engine.modelName)")
        .accessibilityValue(current.title)
    }

    private var effort: Binding<ReasoningEffort> {
        let settings = settings, engine = engine
        return Binding(get: { settings.reasoningEffort(for: engine) ?? .medium },
                       set: { settings.reasoningEfforts[engine] = $0 })
    }
}

private extension LocalModel {
    var onThisMacRowID: String { "onThisMac.\(id)" }
}

private extension RetiredLocalModel {
    var onThisMacRowID: String { "onThisMac.retired.\(id)" }
}

/// What Models says about the files retired models left on this Mac.
enum LeftoverModelCopy {
    /// Under each one's name.
    static let note = "No longer used"

    /// "Parakeet v3 and GigaAM v3 e2e are no longer used. History keeps what they wrote; delete their files to free
    /// the space." nil when none is left.
    static func footer(_ leftovers: [RetiredLocalModel]) -> String? {
        let names = leftovers.map(\.displayName)
        guard let last = names.last else { return nil }
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + last : last
        let they = names.count > 1 ? "they" : "it"
        let their = names.count > 1 ? "their" : "its"
        return "\(list) \(names.count > 1 ? "are" : "is") no longer used. History keeps what \(they) wrote; delete "
            + "\(their) files to free the space."
    }
}

enum ModelsAnchor: Hashable {
    case key, proxy
}

// MARK: - Your models

/// Switch model has no shortcut, so nothing switches: says so, with a way to set one.
private struct SwitchModelUnboundLine: View {
    var openShortcuts: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(SwitchModelLine.explanation(.unbound, lineup: .default))
                .fixedSize(horizontal: false, vertical: true)
            Button("Set Shortcut", action: openShortcuts)
                .buttonStyle(.appQuiet)
                .fixedSize()
        }
        .typeface(.callout)
        .foregroundStyle(.inkSecondary)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
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
    @Environment(\.inNativeForm) private var inNativeForm
    @State private var hovering = false

    private var isMain: Bool { settings.lineup.main == choice }
    private var index: Int { settings.lineup.order.firstIndex(of: choice) ?? 0 }
    private var isLast: Bool { index == settings.lineup.order.count - 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                handle
                RadioDot(isOn: isMain)
            }
            ModelColorButton(choice: choice)
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.modelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                status
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                actions
                trailing
            }
        }
        // In a form, the form's row insets.
        .padding(.leading, inNativeForm ? 0 : Theme.Spacing.md - 6)
        .padding(.trailing, inNativeForm ? 0 : Theme.Spacing.md)
        .padding(.vertical, inNativeForm ? 4 : 12)
        .frame(minHeight: inNativeForm ? 0 : 76)
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

    // MARK: Status and controls

    private var status: some View {
        let summary = EngineSummary.make(choice: choice, localState: models.state(of: choice.engine),
                                         keyStatus: hub.keyStatus(for: choice.engine),
                                         localError: models.lastErrors[choice.engine],
                                         provider: hub.provider(for: choice.engine))
        // A model on this Mac that nothing uses yet isn't missing anything: its "Not downloaded" is plain, not red.
        let unused = choice.isLocal && !settings.usesLocalModel(choice.engine)
            && models.state(of: choice.engine) == .notInstalled
        let tone = unused ? StatusTone.neutral : summary.tone
        return HStack(spacing: 4) {
            StatusDot(color: tone.color, size: 6, pulsing: tone == .progress)
                .frame(width: 12, height: 12)
            Text(summary.status)
                .typeface(.callout)
                .monospacedDigit()
                .foregroundStyle(tone == .negative ? Color.danger : Color.inkSecondary)
                .contentTransition(.numericText())
                .lineLimit(1)
            // A Gemini model's Reasoning level, after its status; the model on this Mac doesn't reason.
            if !choice.engine.reasoningEfforts.isEmpty {
                Text("·")
                    .typeface(.callout)
                    .foregroundStyle(.inkTertiary)
                    .accessibilityHidden(true)
                ReasoningMenu(engine: choice.engine)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch hub.readiness(of: choice) {
        case .needsDownload:
            Button {
                models.download(choice.engine)
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
        case .needsKey:
            Button("Add Key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .needsEndpoint:
            Button("Set Up", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .keyProblem:
            Button("Update Key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .failed:
            // Only a model on this Mac fails this way: the same Retry as its row under On this Mac.
            Button("Retry") { models.download(choice.engine) }
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

    @Environment(AppSettings.self) private var settings
    @State private var picking = false
    @State private var hovering = false

    private static let size: CGFloat = 36

    var body: some View {
        let color = settings.modelColors[choice]
        let tile = RoundedRectangle(cornerRadius: Self.size * 0.28, style: .continuous)
        Button { picking = true } label: {
            ModelChoiceIcon(choice: choice, color: color, size: Self.size)
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
            ModelColorPopover(choice: choice, color: color) { picked in
                settings.modelColors[choice] = picked
            }
        }
    }
}

/// A model's colors: its pill in the color, then the swatches. A pick applies at once (the tile behind, the sidebar
/// chip, History's marks and a pill that is dictating fade to it), and the popover stays open to compare.
struct ModelColorPopover: View {
    var choice: ModelChoice
    var color: ModelColor
    var onPick: (ModelColor) -> Void

    /// The swatches' circles span it, and the preview and the header line up on their ends.
    static let contentWidth = ModelColorSwatches.width
    static let width: CGFloat = contentWidth + 2 * 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelColorPreview(choice: choice, color: color)
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
    var color: ModelColor

    @State private var model: PillModel

    init(choice: ModelChoice, color: ModelColor) {
        self.choice = choice
        self.color = color
        let model = PillModel.preview(phase: .listening, level: 0.7)
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

// MARK: - On this Mac

/// The model on this Mac (GigaAM v3): its download (or load) and how it's doing, its size, and Delete. While Switch
/// model reaches it, it's in use and can't be deleted.
private struct ModelRow: View {
    var model: LocalModel

    @Environment(ModelStore.self) private var models
    @Environment(AppSettings.self) private var settings
    @Environment(\.inNativeForm) private var inNativeForm
    @State private var confirmingDelete = false

    private var state: LocalModelState { models.state(model: model) }
    private var choice: ModelChoice { ModelChoice(engine: model.engine) }
    /// Switch model reaches it (as the main model, a step or hands-free's): in use.
    private var isInUse: Bool { settings.usesLocalModel(model.engine) }
    /// Downloaded, loaded or loading: what "In use" needs.
    private var isOnDisk: Bool {
        switch state {
        case .installed, .preparing, .ready: true
        case .notInstalled, .downloading, .failed: false
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ModelChoiceIcon(choice: choice, color: settings.modelColors[choice], size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                localStatus
            }
            Spacer(minLength: 8)
            actions
        }
        // In a form, the form's row insets.
        .padding(.horizontal, inNativeForm ? 0 : Theme.Spacing.md)
        .padding(.vertical, inNativeForm ? 4 : 12)
        .frame(minHeight: inNativeForm ? 0 : 76)
        .accessibilityElement(children: .contain)
    }

    /// What it writes, what it costs and needs.
    private var subtitle: String {
        "Russian · no punctuation · free · works offline"
    }

    // MARK: Status

    @ViewBuilder private var localStatus: some View {
        switch state {
        case .downloading(let progress):
            BarThenCaption {
                ProgressBar(fraction: progress.fraction, height: 4)
                    .frame(width: 120)
            } caption: {
                Text(downloadLabel(progress))
                    .typeface(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.inkSecondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
        case .preparing(let since):
            BarThenCaption {
                ShimmerBar(height: 4).frame(width: 100)
            } caption: {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(since)
                    Text("Loading model into memory… up to a minute the first time"
                         + (elapsed >= 20 ? " · \(Fmt.duration(elapsed))" : ""))
                        .typeface(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
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
            ModelStatusText(state: state, model: model)
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
            if isInUse, isOnDisk {
                StateCapsule(title: "In use")
            }
            switch state {
            case .notInstalled:
                Button {
                    models.download(model: model)
                } label: {
                    Label("Download", systemImage: "arrow.down")
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            case .failed:
                Button("Retry") { models.download(model: model) }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                if case .modelLoadFailed? = models.modelErrors[model] {
                    // The files downloaded but don't load: Retry loads the same files again, this replaces them.
                    Button("Download Again") {
                        let models = models, model = model
                        Task { await models.reinstall(model: model) }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .help("Delete \(model.displayName) and download it again")
                } else {
                    // A partial download or a half-removed install can go even while in use: nothing is loaded.
                    deleteButton(isEnabled: true, freedBytes: nil)
                }
            case .downloading:
                Button("Cancel") { models.cancelDownload(model: model) }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            case .installed, .ready, .preparing:
                deleteButton(isEnabled: !isInUse, freedBytes: model.approxInstalledBytes)
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
        .help(isEnabled ? "Delete \(model.displayName)"
              : "Make another model the main model and switch \(choice.shortName) off in Your models to delete it.")
        .accessibilityLabel("Delete \(model.displayName)")
        .popover(isPresented: $confirmingDelete, arrowEdge: .bottom) {
            DeleteModelConfirmation(name: model.displayName, freedBytes: freedBytes) {
                confirmingDelete = false
                let models = models, model = model
                Task { await models.delete(model: model) }
            } cancel: {
                confirmingDelete = false
            }
        }
    }
}

/// What a retired model left on this Mac (Parakeet v3, GigaAM v3 e2e, GigaAM Multilingual): its name, "No longer
/// used", what it takes, and Delete, which asks first. Nothing runs it, so nothing keeps it from going.
private struct LeftoverModelRow: View {
    var model: RetiredLocalModel

    @Environment(ModelStore.self) private var models
    @Environment(\.inNativeForm) private var inNativeForm
    @State private var confirmingDelete = false

    private var bytes: Int64 { models.leftovers[model] ?? 0 }
    private var isDeleting: Bool { models.deletingLeftovers.contains(model) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            EngineIcon(engine: model.engine, size: 36, tint: .inkTertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                Text(LeftoverModelCopy.note)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    StatusDot(color: StatusTone.neutral.color, size: 6).frame(width: 12, height: 12)
                    Text(isDeleting ? "Deleting…" : "\(Fmt.bytes(bytes)) on this Mac")
                        .typeface(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Delete") { confirmingDelete = true }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .disabled(isDeleting)
                .help("Delete \(model.displayName)’s files")
                .accessibilityLabel("Delete \(model.displayName)")
                .popover(isPresented: $confirmingDelete, arrowEdge: .bottom) {
                    DeleteModelConfirmation(name: model.displayName, freedBytes: bytes, canDownloadAgain: false) {
                        confirmingDelete = false
                        let models = models, model = model
                        Task { await models.deleteLeftover(model) }
                    } cancel: {
                        confirmingDelete = false
                    }
                }
        }
        // In a form, the form's row insets.
        .padding(.horizontal, inNativeForm ? 0 : Theme.Spacing.md)
        .padding(.vertical, inNativeForm ? 4 : 12)
        .frame(minHeight: inNativeForm ? 0 : 76)
        .accessibilityElement(children: .contain)
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
    var name: String
    var freedBytes: Int64?
    /// False for a retired model's files: nothing downloads it any more.
    var canDownloadAgain = true
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(name)?")
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
        return size + (canDownloadAgain ? "You can download it again anytime."
            : "It can’t be downloaded again. History keeps what it wrote.")
    }
}

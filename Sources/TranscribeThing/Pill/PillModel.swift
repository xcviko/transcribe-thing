import AppKit
import Observation

/// State the pill draws. The dictation controller writes `phase`; the pill view reads `visiblePhase`,
/// which follows `phase` but keeps the error flourish on screen for its minimum time.
@MainActor @Observable
final class PillModel {
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let levelMeter: LevelMeter

    /// Requested phase. `.rest` and `.hidden` both mean "idle": the resting capsule in Always mode, nothing otherwise.
    /// `.error` is transient: after its flourish the model returns to `.rest` (or to a `.processing` requested
    /// meanwhile) by itself.
    var phase: PillPhase = .rest {
        didSet { if phase != oldValue { phaseDidChange() } }
    }

    /// What is on screen right now.
    private(set) var visiblePhase: PillPhase = .rest
    /// The recording phase that preceded `.processing`: after hands-free the dots start where its bars stood.
    private(set) var processingOrigin: PillPhase = .listening

    /// Pointer over the pill (plus its 12 pt hover margin). Written by the controller with enter/exit delays.
    var isHovering = false
    /// "Hold fn to dictate" tooltip: after 350 ms of hover over the resting pill.
    private(set) var showsTooltip = false
    /// Hands-free button under the pointer, for hover styling and its tooltip.
    private(set) var hoveredControl: PillControl?
    /// The hovered button's tooltip (after 500 ms).
    private(set) var controlTooltip: PillControl?

    /// When the recording started: the hands-free timer counts from it.
    var recordingStartedAt: Date? {
        didSet { if recordingStartedAt != oldValue { scheduleHours() } }
    }
    /// The recording has run past an hour: the hands-free timer reads "1:02:03", and the capsule widens once to fit
    /// it (`PillMetrics.lockedHoursSize`).
    private(set) var showsHours = false
    /// How many tokens the model of the processing pill's dictation is thinking or writing right now, as far as its
    /// stream tells (`TokenEstimate`). Set by the controller; nil for Parakeet, and until the first streamed character.
    var tokenCount: PillTokenCount? {
        didSet { if tokenCount != oldValue { updateCounter() } }
    }
    /// The processing pill shows `tokenCount` in place of its dots. Only once a count has been there for
    /// `timing.counterDelay`, so a quick answer (Gemini on a short dictation) never flashes a number; then until
    /// the count goes or the pill stops processing.
    private(set) var showsCounter = false

    /// The dictation's model from key-down until its text lands, set by the controller; nil at rest. The pill's
    /// tint shows it throughout (`PillPalette.accent`, in the color Models gives it, whichever model is main); the
    /// chip only now and then (`showsChip`). With the dictation over, its chip goes with it: the next dictation never
    /// starts under the last one's chip (Esc in hands-free on Gemini, then fn on Parakeet).
    var sessionModel: ModelChoice? {
        didSet { if sessionModel == nil, oldValue != nil { endChipFlash() } }
    }
    /// The dictation on screen is polished (`Polish`): the wand sits left of its bars, then of its wave.
    var polishes = false
    /// The dictation on screen is translated (`Translate`): its glyph takes the wand's place (both, with Polish on too).
    var translates = false
    /// What stands left of the bars or the wave, if anything: the wand, Translate's glyph, or both in one.
    var rewrite: PillRewrite? { PillRewrite(polishes: polishes, translates: translates) }
    /// The dictation on screen is sent (`Send`): the paper plane sits right of its bars, then of its wave, as the wand
    /// sits left of them (both, with Polish or Translate on too).
    var sends = false
    /// The polish on screen is a selection's (Polish Selection): nothing was heard, so the pill says "Polishing" where
    /// a dictation's shows the wave.
    var selectionPolishing = false
    /// The dictation on screen won't be pasted: the user clicked away while it was processed (General → Pasting's
    /// "Hold the paste after a click"), and its text will come up on a card. The processing pill's outline is dashed,
    /// and stays so as the pill leaves with it.
    var holdsPaste = false
    /// Bumped on every switch of the dictation's model, back to the main model too, so the chip names the new one
    /// for a moment.
    var engineChipPulse = 0 {
        didSet { if engineChipPulse != oldValue { flashChip() } }
    }
    /// The chip after a switch, for `timing.chipHold`; a switch meanwhile starts it over.
    private(set) var isChipFlashing = false
    /// The Switch model discovery hint next to a long push-to-talk hold (its first few times).
    var showsTabHint = false
    /// A word over the pill about a key that did nothing where it was pressed ("Polish works on Gemini only"), for
    /// `timing.keyHintHold`. It takes the chip's place.
    private(set) var keyHint: String?

    /// Key-chip text for the tooltip, from `settings.shortcuts[.pushToTalk]`.
    var shortcutHint: String = "fn"
    /// Set before an error flash to say it in words inside the capsule ("No speech detected") instead of the
    /// glyph and the shake. Cleared when the flash settles.
    var errorMessage: String?
    /// The model of the dictation the error flash is about: "No speech detected" wears its ring, as the dictation
    /// did. Gone with the flash.
    var errorModel: ModelChoice?
    /// Increment to shake. Shaking an idle or processing pill turns it into a brief error flash
    /// so the feedback is visible even when the pill would otherwise be hidden.
    var shakeTrigger = 0 {
        didSet { if shakeTrigger != oldValue { shakeRequested() } }
    }
    /// Drives the keyframe shake (explicit shakes plus every entry into `.error`).
    private(set) var shakeCount = 0

    /// The tray beside the pill (`PillTray`): its dictation, and its buttons' state. nil when the pill shows no dictation
    /// (at rest, a selection's polish, the error flash), so no tray opens. Set by the controller.
    var tray: PillTrayState?
    /// Older dictations still on their way, each on a pill of its own stacked above this one, the nearest first
    /// (`PillStack`). Set by the controller with `setStack`.
    private(set) var stack: [PillStackItem] = []
    /// The stacked pills' own models, by dictation key: each draws its pill as this one draws the bottom pill.
    @ObservationIgnored private(set) var stackModels: [UUID: PillModel] = [:]
    /// The bottom pill's dictation came down off the stack: the one on the bottom pill (the newest on its way, or the
    /// recording) was canceled, and the next one took its place. Its stacked pill slides down onto the bottom pill as
    /// it goes (`PillStack`), and the bottom pill comes in under it, once per `descentCount`.
    private(set) var descentKey: UUID?
    private(set) var descentCount = 0
    /// The dictation the bottom pill showed at the last `setStack`.
    @ObservationIgnored private var stackBottomKey: UUID?
    /// The pill whose tray is open: the pointer is over it or its tray, or left them a moment ago.
    private(set) var openTray: PillTrayOwner?
    /// The tray button under the pointer, and the one whose shortcut shows over it (`PillTrayState.keys`), after
    /// `timing.controlTooltipDelay` on it.
    private(set) var hoveredTrayButton: PillTrayButton?
    private(set) var trayHint: PillTrayButton?
    /// The hint came straight over from the button next to it, which had one up: it's there at once, with no fade, and
    /// the other's goes at once too, as macOS tooltips do.
    private(set) var trayHintCarriesOver = false

    /// Resolved by `PillController` from the pill mode. Standalone previews keep `true`.
    var isPresented = true
    /// False in Never mode. Toasts follow `isPresented`: with no pill on screen they sit in its slot.
    var isPillAllowed = true
    /// Post-onboarding hello: the pill blooms with its tooltip for a few seconds, whatever the mode.
    private(set) var isHelloActive = false

    @ObservationIgnored var onClick: (() -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    /// A tray button was clicked: Polish, Translate or Send for that pill's dictation.
    @ObservationIgnored var onToggle: ((PillToggle, PillDictation) -> Void)?
    /// A stacked pill was clicked (a dashed one takes its click away back), by its dictation's key.
    @ObservationIgnored var onStackClick: ((UUID) -> Void)?
    @ObservationIgnored var contextMenuProvider: (() -> NSMenu)?
    /// The hands-free model chip was clicked: the controller opens the model menu under it.
    @ObservationIgnored var onEngineChipClick: (() -> Void)?
    /// A choice picked from that menu, for the dictation being recorded.
    @ObservationIgnored var onSelectModel: ((ModelChoice) -> Void)?
    /// Why a model of that menu can't take the dictation now ("Needs key", "Not downloaded"), shown beside it
    /// disabled; nil when it can. Set by the controller.
    @ObservationIgnored var unavailableReason: ((ModelChoice) -> String?)?
    /// Called as soon as `visiblePhase` changes, in the same turn (observation only reports it on the next one),
    /// so the panel can be on screen before whatever the caller does next, such as opening the mic.
    @ObservationIgnored var onVisiblePhaseChange: (() -> Void)?

    /// Durations of the automatic transitions; tests shorten them.
    @ObservationIgnored var timing = PillTiming()
    /// Previews render one phase forever; live models settle an error back to rest.
    @ObservationIgnored var autoSettles = true

    @ObservationIgnored private var holdUntil: Date?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var hoursTask: Task<Void, Never>?
    @ObservationIgnored private var counterTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var tooltipTask: Task<Void, Never>?
    @ObservationIgnored private var controlTooltipTask: Task<Void, Never>?
    @ObservationIgnored private var helloTask: Task<Void, Never>?
    @ObservationIgnored private var chipTask: Task<Void, Never>?
    @ObservationIgnored private var keyHintTask: Task<Void, Never>?
    @ObservationIgnored private var trayTask: Task<Void, Never>?
    @ObservationIgnored private var trayHintTask: Task<Void, Never>?
    @ObservationIgnored private var trayPointer: PillTrayOwner?
    @ObservationIgnored private var pointerInside = false

    init(settings: AppSettings, levelMeter: LevelMeter) {
        self.settings = settings
        self.levelMeter = levelMeter
        self.shortcutHint = settings.shortcuts[.pushToTalk]?.compactDescription ?? "fn"
    }

    /// A model frozen in one phase, for snapshots and illustrations (onboarding).
    static func preview(phase: PillPhase, level: Float = 0.55, isHovering: Bool = false,
                        recordingFor elapsed: TimeInterval? = nil, levelMeter: LevelMeter? = nil) -> PillModel {
        let model = PillModel(settings: .inMemory(), levelMeter: levelMeter ?? .preview(level: level))
        model.autoSettles = false
        model.phase = phase
        if phase.isRecording { model.recordingStartedAt = Date().addingTimeInterval(-(elapsed ?? 14)) }
        model.isHovering = isHovering
        return model
    }

    /// Snapshots: processing whose model has been streaming long enough to show its count.
    func previewCounter(_ count: PillTokenCount) -> PillModel {
        tokenCount = count
        showsCounter = visiblePhase == .processing
        return self
    }

    // MARK: Phase

    private func phaseDidChange() {
        let target = phase
        let now = Date()
        // A new idle (or processing: the next dictation is still queued) request must not cut the error
        // flash short. A new recording does.
        if target.isIdle || target == .processing, visiblePhase == .error,
           let holdUntil, holdUntil > now, autoSettles {
            scheduleSettle(at: holdUntil)
            return
        }
        apply(target, now: now)
    }

    private func apply(_ target: PillPhase, now: Date) {
        settleTask?.cancel()
        settleTask = nil
        let previous = visiblePhase
        if target == .processing, previous.isRecording { processingOrigin = previous }
        if target == .processing, !previous.isRecording, previous != .processing { processingOrigin = .listening }
        if target.isRecording, !previous.isRecording {
            // The controller usually stamps the start itself; a missing or stale stamp means it didn't.
            if recordingStartedAt.map({ now.timeIntervalSince($0) > 3 }) ?? true { recordingStartedAt = now }
        } else if !target.isRecording, previous.isRecording {
            recordingStartedAt = nil
        }
        if target == .error, previous != .error, errorMessage == nil { shakeCount &+= 1 }
        if target != .error {
            errorMessage = nil
            errorModel = nil
        }
        // The word about a key belongs to the dictation it was pressed in.
        if !target.isRecording { clearKeyHint() }
        visiblePhase = target
        if !target.isIdle { showsTooltip = false }
        if !target.isRecording { setHoveredControl(nil) }

        updateCounter()

        if target == .error {
            holdUntil = now.addingTimeInterval(timing.errorHold)
            if autoSettles { scheduleSettle(at: holdUntil!) }
        } else {
            holdUntil = nil
        }
        scheduleHours()
        if target != previous { onVisiblePhaseChange?() }
    }

    private func scheduleSettle(at date: Date) {
        settleTask?.cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.settle()
        }
    }

    private func settle() {
        settleTask = nil
        holdUntil = nil
        if phase == .error {
            phase = .rest   // didSet applies it: the hold is over
        } else {
            apply(phase, now: Date())
        }
    }

    private func shakeRequested() {
        switch visiblePhase {
        case .listening, .locked, .error:
            // A worded flash ("No speech detected") holds on without the shake.
            if !(visiblePhase == .error && errorMessage != nil) { shakeCount &+= 1 }
            if visiblePhase == .error, autoSettles {
                holdUntil = Date().addingTimeInterval(timing.errorHold)
                scheduleSettle(at: holdUntil!)
            }
        case .rest, .hidden, .processing:
            phase = .error
        }
    }

    // MARK: Counter

    /// Arms `showsCounter` when a count is there while processing, and drops it (with the wait) when the count goes
    /// or the pill leaves processing.
    private func updateCounter() {
        guard visiblePhase == .processing, tokenCount != nil else {
            counterTask?.cancel()
            counterTask = nil
            if showsCounter { showsCounter = false }
            return
        }
        guard !showsCounter, counterTask == nil, autoSettles else { return }
        counterTask = delayed(timing.counterDelay) { model in
            model.counterTask = nil
            if model.visiblePhase == .processing, model.tokenCount != nil { model.showsCounter = true }
        }
    }

    // MARK: Hours

    /// `showsHours` from the hour mark on: at once for a recording already past it (a preview, an Undo-resumed long
    /// dictation), else when the hour comes; off whenever the pill isn't recording.
    private func scheduleHours() {
        hoursTask?.cancel()
        hoursTask = nil
        guard visiblePhase.isRecording, let start = recordingStartedAt else {
            if showsHours { showsHours = false }
            return
        }
        let delay = start.addingTimeInterval(3600).timeIntervalSinceNow
        if delay <= 0 {
            if !showsHours { showsHours = true }
            return
        }
        if showsHours { showsHours = false }
        guard autoSettles else { return }
        hoursTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.visiblePhase.isRecording else { return }
            self.showsHours = true
        }
    }

    // MARK: Pointer

    /// Called by the controller whenever the pointer crosses the pill's hit area.
    /// Enter needs 80 ms of dwell, exit has a 150 ms grace, the tooltip needs 350 ms.
    func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()
        tooltipTask?.cancel()
        if inside {
            hoverTask = delayed(timing.hoverIn) { $0.isHovering = true }
            tooltipTask = delayed(timing.tooltipDelay) { model in
                if model.visiblePhase.isIdle { model.showsTooltip = true }
            }
        } else {
            if showsTooltip { showsTooltip = false }
            hoverTask = delayed(timing.hoverOut) { $0.isHovering = false }
            setHoveredControl(nil)
        }
    }

    /// Which hands-free button the pointer is over (hover styling + its tooltip after 500 ms).
    func setHoveredControl(_ control: PillControl?) {
        guard control != hoveredControl else { return }
        hoveredControl = control
        controlTooltipTask?.cancel()
        if controlTooltip != nil { controlTooltip = nil }
        if let control {
            controlTooltipTask = delayed(timing.controlTooltipDelay) { model in
                if model.hoveredControl == control { model.controlTooltip = control }
            }
        }
    }

    /// Shows a button tooltip without the hover delay (snapshots).
    func showControlTooltip(_ control: PillControl) {
        controlTooltipTask?.cancel()
        hoveredControl = control
        controlTooltip = control
    }

    /// Resets hover state at once (panel hidden).
    func resetPointer() {
        pointerInside = false
        hoverTask?.cancel()
        tooltipTask?.cancel()
        if isHovering { isHovering = false }
        if showsTooltip { showsTooltip = false }
        setHoveredControl(nil)
        setPointerOverChip(false)
        trayPointer = nil
        trayTask?.cancel()
        if openTray != nil { openTray = nil }
        setHoveredTrayButton(nil)
    }

    // MARK: Tray

    /// The pointer is over a pill that shows a dictation, or over its tray (`owner`), or over neither (nil), as the
    /// controller tracks it. A tray opens after the hover's short dwell, at once when another one is open already (the
    /// pointer went from one pill to the next), and goes the moment the pointer has left both: the gap between pill
    /// and tray is inside the pill's hover margin, so crossing it never closes the tray.
    func setPointerOverTray(_ owner: PillTrayOwner?) {
        guard owner != trayPointer else { return }
        trayPointer = owner
        trayTask?.cancel()
        if let owner {
            if openTray != nil {
                openTray = owner
            } else {
                trayTask = delayed(timing.hoverIn) { $0.openTray = owner }
            }
        } else {
            if openTray != nil { openTray = nil }
            setHoveredTrayButton(nil)
        }
    }

    /// Which tray button the pointer is on: its shortcut shows over it after `timing.controlTooltipDelay`, or at once
    /// when another button's was up (`trayHintCarriesOver`). Off a button (the gap between two, say) the hint stays
    /// `timing.trayHintCarryOver`, so the next button's still comes at once.
    func setHoveredTrayButton(_ button: PillTrayButton?) {
        guard button != hoveredTrayButton else { return }
        hoveredTrayButton = button
        trayHintTask?.cancel()
        if let button {
            if trayHint != nil {
                trayHintCarriesOver = true
                trayHint = button
            } else {
                trayHintCarriesOver = false
                trayHintTask = delayed(timing.controlTooltipDelay) { model in
                    if model.hoveredTrayButton == button { model.trayHint = button }
                }
            }
        } else if trayHint != nil {
            trayHintTask = delayed(timing.trayHintCarryOver) { model in
                model.trayHint = nil
                model.trayHintCarriesOver = false
            }
        }
    }

    /// Opens `owner`'s tray at once, with the pointer on `button` and its shortcut over it (snapshots, films).
    func showTray(_ owner: PillTrayOwner?, hovering button: PillTrayButton? = nil) {
        trayTask?.cancel()
        trayHintTask?.cancel()
        openTray = owner
        hoveredTrayButton = button
        trayHint = button
        trayHintCarriesOver = false
    }

    /// Whether `owner`'s tray is out now: its pill shows a dictation that has one, and the pointer opened it or one of
    /// its buttons is on (the pill shows no glyph of its own for them, so the tray stays to show it).
    func showsTray(_ owner: PillTrayOwner) -> Bool {
        guard isPresented, let state = trayState(owner) else { return false }
        if case .bottom = owner, !(visiblePhase.isRecording || visiblePhase == .processing) { return false }
        if case .stacked(let key) = owner, !stack.contains(where: { $0.key == key }) { return false }
        return openTray == owner || state.isAimed || PillToggle.allCases.contains { state.isOn($0) }
    }

    /// The tray `owner` shows: the bottom pill's, or a stacked pill's.
    func trayState(_ owner: PillTrayOwner) -> PillTrayState? {
        switch owner {
        case .bottom: tray
        case .stacked(let key): stack.first { $0.key == key }?.tray
        }
    }

    // MARK: Stack

    /// The older dictations still on their way, the nearest the pill first. Each gets a pill model of its own that
    /// draws it processing (its count after the usual wait, its glyphs, its dashed edge); one that leaves the stack
    /// drops its model, and its tray closes.
    func setStack(_ items: [PillStackItem]) {
        let bottomKey: UUID? = if case .processing(let key)? = tray?.dictation { key } else { nil }
        if let bottomKey, bottomKey != stackBottomKey, stack.contains(where: { $0.key == bottomKey }),
           !items.contains(where: { $0.key == bottomKey }) {
            descentKey = bottomKey
            descentCount += 1
        } else if let key = descentKey, items.contains(where: { $0.key == key }) {
            // Back up on the stack (a new dictation started): it leaves from there like any other.
            descentKey = nil
        }
        stackBottomKey = bottomKey
        for item in items {
            let child = stackModels[item.key] ?? makeStackModel()
            stackModels[item.key] = child
            child.apply(item)
        }
        let keys = Set(items.map(\.key))
        for key in stackModels.keys where !keys.contains(key) { stackModels[key] = nil }
        if stack != items { stack = items }
        if case .stacked(let key)? = openTray, !keys.contains(key) {
            openTray = nil
            setHoveredTrayButton(nil)
        }
    }

    private func makeStackModel() -> PillModel {
        let child = PillModel(settings: settings, levelMeter: .preview(level: 0))
        child.timing = timing
        child.autoSettles = autoSettles
        child.phase = .processing
        return child
    }

    /// A stacked pill's dictation, as this pill model draws it.
    private func apply(_ item: PillStackItem) {
        if sessionModel != item.choice { sessionModel = item.choice }
        if polishes != item.tray.polishes { polishes = item.tray.polishes }
        if translates != item.tray.translates { translates = item.tray.translates }
        if sends != item.tray.sends { sends = item.tray.sends }
        if holdsPaste != item.holdsPaste { holdsPaste = item.holdsPaste }
        if tokenCount != item.count { tokenCount = item.count }
        if tray != item.tray { tray = item.tray }
    }

    // MARK: Model chip

    /// The chip above the pill is up only for a moment after a switch (Switch model, or the menu), and in
    /// hands-free while the pointer rests on the chip itself, so a click can open the model menu. Hovering the
    /// pill never brings it up: the tint alone says the model. With hints above the pill off
    /// (`AppSettings.showsPillHints`), a switch doesn't bring it up either.
    var showsChip: Bool {
        isChipFlashing && settings.showsPillHints || (visiblePhase == .locked && isPointerOverChip)
    }
    /// The pointer is on the chip (hands-free), set by the controller.
    private(set) var isPointerOverChip = false

    func setPointerOverChip(_ over: Bool) {
        if isPointerOverChip != over { isPointerOverChip = over }
    }

    /// What the chip above the pill names right now: the dictation's model; nil while it's down.
    var chipModel: ModelChoice? {
        showsChip ? sessionModel : nil
    }

    /// Says `text` over the pill for `timing.keyHintHold`; another meanwhile starts it over.
    func showKeyHint(_ text: String) {
        keyHintTask?.cancel()
        keyHint = text
        if autoSettles { keyHintTask = delayed(timing.keyHintHold) { $0.keyHint = nil } }
    }

    private func clearKeyHint() {
        keyHintTask?.cancel()
        if keyHint != nil { keyHint = nil }
    }

    /// Shows the chip for `timing.chipHold`; a switch meanwhile starts it over, and answers a word about a key
    /// ("Polish works on Gemini only", then fn ⇥ onto Gemini).
    func flashChip() {
        clearKeyHint()
        chipTask?.cancel()
        isChipFlashing = true
        if autoSettles { chipTask = delayed(timing.chipHold) { $0.endChipFlash() } }
    }

    /// Takes the chip down at once: Polish Selection's handoff, whose polish circle it would sit over.
    func endChipFlash() {
        chipTask?.cancel()
        chipTask = nil
        if isChipFlashing { isChipFlashing = false }
    }

    /// What the hands-free chip's menu offers, in Switch model order: the main model, then every model it steps to.
    var menuChoices: [ModelChoice] {
        settings.lineup.cycle
    }

    // MARK: Hello

    func beginHello(duration: TimeInterval) {
        helloTask?.cancel()
        isHelloActive = true
        helloTask = delayed(duration) { $0.isHelloActive = false }
    }

    private func delayed(_ seconds: TimeInterval, _ body: @escaping @MainActor (PillModel) -> Void) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            body(self)
        }
    }
}

/// Buttons of the hands-free pill.
enum PillControl: Equatable, Sendable {
    case cancel, stop
}

struct PillTiming: Equatable, Sendable {
    var errorHold: TimeInterval = 1.6
    var hoverIn: TimeInterval = 0.08
    var hoverOut: TimeInterval = 0.15
    var tooltipDelay: TimeInterval = 0.35
    var controlTooltipDelay: TimeInterval = 0.5
    /// How long a tray button's hint stays once the pointer is off the button: long enough to reach the next one.
    var trayHintCarryOver: TimeInterval = 0.2
    /// How long a token count waits before the processing pill shows it (`PillModel.showsCounter`).
    var counterDelay: TimeInterval = 1.0
    /// How long the model chip stays after a switch, before it fades and the tint alone says the model; Polish
    /// Selection's hint stays as long.
    var chipHold: TimeInterval = 1.2
    /// How long a word about a key that did nothing stays over the pill (`PillModel.keyHint`).
    var keyHintHold: TimeInterval = 1.8
}

// MARK: - Tray and stack

/// The buttons of a pill's tray (`PillTray`), in their order: what each turns on or off for the pill's dictation.
enum PillToggle: String, CaseIterable, Sendable {
    case send, polish, translate

    var title: String {
        switch self {
        case .polish: "Polish"
        case .translate: "Translate"
        case .send: "Send"
        }
    }

    var symbolName: String {
        switch self {
        case .polish: "wand.and.sparkles"
        case .translate: "translate"
        case .send: "paperplane.fill"
        }
    }

    /// The shortcut that does what this button does.
    var action: ShortcutAction {
        switch self {
        case .polish: .polish
        case .translate: .translate
        case .send: .send
        }
    }

    init?(_ action: ShortcutAction) {
        switch action {
        case .polish: self = .polish
        case .translate: self = .translate
        case .send: self = .send
        case .pushToTalk, .handsFree, .pasteLast, .switchModel, .addToDictionary: return nil
        }
    }
}

/// The dictation a pill shows, for its tray: the one being recorded, or one being processed, by its job's key.
enum PillDictation: Hashable, Sendable {
    case recording
    case processing(UUID)
}

/// Which pill a tray belongs to: the one at the bottom (recording, or the newest dictation on its way), or one stacked
/// above it, by its dictation's key.
enum PillTrayOwner: Hashable, Sendable {
    case bottom
    case stacked(UUID)
}

/// One tray button: its pill and which button.
struct PillTrayButton: Hashable, Sendable {
    var owner: PillTrayOwner
    var toggle: PillToggle
}

/// A tray's buttons for one dictation: which are on, and which can be clicked.
struct PillTrayState: Equatable, Sendable {
    var dictation: PillDictation
    var polishes = false
    var translates = false
    var sends = false
    /// Polish and Translate can change this dictation (everywhere while it records; while it's processed, on Gemini).
    var rewrites = true
    /// Send can (not once a click away holds its text, nor while it's being pasted).
    var canSend = true
    /// Each button's shortcut ("fn ↩", "fn P", "fn T"), shown over it while the pointer rests on it. Only the bottom
    /// pill's: the keys are for the dictation it shows, never for one stacked above it.
    var keys: [PillToggle: String] = [:]
    /// The talk key is down over this dictation on its way (an aimed press): the tray is out, for its keys.
    var isAimed = false

    func isOn(_ toggle: PillToggle) -> Bool {
        switch toggle {
        case .polish: polishes
        case .translate: translates
        case .send: sends
        }
    }

    func isEnabled(_ toggle: PillToggle) -> Bool {
        toggle == .send ? canSend : rewrites
    }

    /// Why a dimmed button can't change the dictation (VoiceOver's hint).
    static func reason(_ toggle: PillToggle) -> String {
        toggle == .send ? "Its text waits on a card" : "Gemini only"
    }
}

/// A dictation still on its way, on a pill stacked above the bottom one (`PillModel.stack`).
struct PillStackItem: Equatable, Sendable {
    var key: UUID
    var choice: ModelChoice
    var tray: PillTrayState
    var holdsPaste = false
    var count: PillTokenCount?
}

extension PillPhase {
    /// `.rest` and `.hidden`: no dictation on screen.
    var isIdle: Bool { self == .rest || self == .hidden }
}

// MARK: - Visibility rules

/// Pure resolution of "is the pill on screen" from the mode and the phase (SPEC §4.13).
enum PillVisibility {
    /// The mode allows a pill at all (Never doesn't; toasts still appear).
    static func isPillAllowed(mode: PillMode) -> Bool {
        mode != .never
    }

    static func showsPill(phase: PillPhase, mode: PillMode, isHelloActive: Bool = false) -> Bool {
        guard isPillAllowed(mode: mode) else { return false }
        if phase.isActive { return true }
        return mode == .always || isHelloActive
    }

    /// The panel exists on screen while the pill or any toast is visible.
    static func needsPanel(showsPill: Bool, toastCount: Int) -> Bool {
        showsPill || toastCount > 0
    }
}

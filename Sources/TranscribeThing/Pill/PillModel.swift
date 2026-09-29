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
    /// `timing.counterDelay`, so a quick answer (the clean-up of a short dictation) never flashes a number; then until
    /// the count goes or the pill stops processing.
    private(set) var showsCounter = false

    /// The dictation's model from key-down until its text lands, set by the controller; nil at rest. The pill's
    /// tint shows it throughout (`PillPalette.accent`, whichever model is main); the chip only now and then
    /// (`showsChip`).
    var sessionModel: ModelChoice?
    /// Bumped on every switch of the dictation's model, back to the main model too, so the chip names the new one
    /// for a moment.
    var engineChipPulse = 0 {
        didSet { if engineChipPulse != oldValue { flashChip() } }
    }
    /// The chip after a switch, for `timing.chipHold`; a switch meanwhile starts it over.
    private(set) var isChipFlashing = false
    /// The Switch model discovery hint next to a long push-to-talk hold (its first few times).
    var showsTabHint = false

    /// Key-chip text for the tooltip, from `settings.shortcuts[.pushToTalk]`.
    var shortcutHint: String = "fn"
    /// Set before an error flash to say it in words inside the capsule ("No speech detected") instead of the
    /// glyph and the shake. Cleared when the flash settles.
    var errorMessage: String?
    /// Increment to shake. Shaking an idle or processing pill turns it into a brief error flash
    /// so the feedback is visible even when the pill would otherwise be hidden.
    var shakeTrigger = 0 {
        didSet { if shakeTrigger != oldValue { shakeRequested() } }
    }
    /// Drives the keyframe shake (explicit shakes plus every entry into `.error`).
    private(set) var shakeCount = 0

    /// Resolved by `PillController` from the pill mode. Standalone previews keep `true`.
    var isPresented = true
    /// False in Never mode. Toasts follow `isPresented`: with no pill on screen they sit in its slot.
    var isPillAllowed = true
    /// Post-onboarding hello: the pill blooms with its tooltip for a few seconds, whatever the mode.
    private(set) var isHelloActive = false

    @ObservationIgnored var onClick: (() -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
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
        if target != .error { errorMessage = nil }
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
    }

    // MARK: Model chip

    /// The chip above the pill is up only for a moment after a switch (Switch model, or the menu), and in
    /// hands-free while the pointer rests on the chip itself, so a click can open the model menu. Hovering the
    /// pill never brings it up: the tint alone says the model.
    var showsChip: Bool {
        isChipFlashing || (visiblePhase == .locked && isPointerOverChip)
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

    /// Shows the chip for `timing.chipHold`; a switch meanwhile starts it over.
    func flashChip() {
        chipTask?.cancel()
        isChipFlashing = true
        if autoSettles { chipTask = delayed(timing.chipHold) { $0.endChipFlash() } }
    }

    private func endChipFlash() {
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
    /// How long a token count waits before the processing pill shows it (`PillModel.showsCounter`).
    var counterDelay: TimeInterval = 1.0
    /// How long the model chip stays after a switch, before it fades and the tint alone says the model.
    var chipHold: TimeInterval = 1.2
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

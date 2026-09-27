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
    /// The recording phase that preceded `.processing`; processing keeps its width.
    private(set) var processingOrigin: PillPhase = .listening

    /// Pointer over the pill (plus its 12 pt hover margin). Written by the controller with enter/exit delays.
    var isHovering = false
    /// "Hold fn to dictate" tooltip: after 350 ms of hover over the resting pill.
    private(set) var showsTooltip = false
    /// Hands-free button under the pointer, for hover styling and its tooltip.
    private(set) var hoveredControl: PillControl?
    /// The hovered button's tooltip (after 500 ms).
    private(set) var controlTooltip: PillControl?

    /// Hands-free timer (shown on hover or in the last 60 s).
    var recordingStartedAt: Date? {
        didSet { if recordingStartedAt != oldValue { scheduleFinalMinute() } }
    }
    var limitSeconds: TimeInterval {
        didSet { if limitSeconds != oldValue { scheduleFinalMinute() } }
    }
    /// True during the last 60 s before the recording limit.
    private(set) var isInFinalMinute = false
    /// Processing has run longer than `timing.slowProcessing`: the pill says "Still transcribing…".
    private(set) var isProcessingSlow = false

    /// Key-chip text for the tooltip, from `settings.shortcuts[.pushToTalk]`.
    var shortcutHint: String = "fn"
    /// Increment to shake. Shaking an idle or processing pill turns it into a brief error flash
    /// so the feedback is visible even when the pill would otherwise be hidden.
    var shakeTrigger = 0 {
        didSet { if shakeTrigger != oldValue { shakeRequested() } }
    }
    /// Drives the keyframe shake (explicit shakes plus every entry into `.error`).
    private(set) var shakeCount = 0

    /// Resolved by `PillController` from the pill mode. Standalone previews keep `true`.
    var isPresented = true
    /// False in Never mode: toasts then sit where the pill would be.
    var isPillAllowed = true
    /// Post-onboarding hello: the pill blooms with its tooltip for a few seconds, whatever the mode.
    private(set) var isHelloActive = false

    @ObservationIgnored var onClick: (() -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored var contextMenuProvider: (() -> NSMenu)?
    /// Called as soon as `visiblePhase` changes, in the same turn (observation only reports it on the next one),
    /// so the panel can be on screen before whatever the caller does next, such as opening the mic.
    @ObservationIgnored var onVisiblePhaseChange: (() -> Void)?

    /// Durations of the automatic transitions; tests shorten them.
    @ObservationIgnored var timing = PillTiming()
    /// Previews render one phase forever; live models settle an error back to rest.
    @ObservationIgnored var autoSettles = true

    @ObservationIgnored private var holdUntil: Date?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var finalMinuteTask: Task<Void, Never>?
    @ObservationIgnored private var slowTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var tooltipTask: Task<Void, Never>?
    @ObservationIgnored private var controlTooltipTask: Task<Void, Never>?
    @ObservationIgnored private var helloTask: Task<Void, Never>?
    @ObservationIgnored private var pointerInside = false

    init(settings: AppSettings, levelMeter: LevelMeter) {
        self.settings = settings
        self.levelMeter = levelMeter
        self.limitSeconds = settings.effectiveMaxRecordingDuration
        self.shortcutHint = settings.shortcuts[.pushToTalk]?.compactDescription ?? "fn"
    }

    /// A model frozen in one phase, for snapshots and illustrations (onboarding).
    static func preview(phase: PillPhase, level: Float = 0.55, isHovering: Bool = false,
                        recordingFor elapsed: TimeInterval? = nil, limitSeconds: TimeInterval? = nil,
                        levelMeter: LevelMeter? = nil) -> PillModel {
        let model = PillModel(settings: .inMemory(), levelMeter: levelMeter ?? .preview(level: level))
        model.autoSettles = false
        if let limitSeconds { model.limitSeconds = limitSeconds }
        model.phase = phase
        if phase.isRecording { model.recordingStartedAt = Date().addingTimeInterval(-(elapsed ?? 14)) }
        model.isHovering = isHovering
        return model
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
        if target == .error, previous != .error { shakeCount &+= 1 }
        visiblePhase = target
        if !target.isIdle { showsTooltip = false }
        if !target.isRecording { setHoveredControl(nil) }

        if target == .processing, previous != .processing {
            slowTask?.cancel()
            if autoSettles { slowTask = delayed(timing.slowProcessing) { $0.isProcessingSlow = true } }
        } else if target != .processing {
            slowTask?.cancel()
            slowTask = nil
            if isProcessingSlow { isProcessingSlow = false }
        }

        if target == .error {
            holdUntil = now.addingTimeInterval(timing.errorHold)
            if autoSettles { scheduleSettle(at: holdUntil!) }
        } else {
            holdUntil = nil
        }
        scheduleFinalMinute()
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
            shakeCount &+= 1
            if visiblePhase == .error, autoSettles {
                holdUntil = Date().addingTimeInterval(timing.errorHold)
                scheduleSettle(at: holdUntil!)
            }
        case .rest, .hidden, .processing:
            phase = .error
        }
    }

    // MARK: Final minute

    private func scheduleFinalMinute() {
        finalMinuteTask?.cancel()
        finalMinuteTask = nil
        guard visiblePhase.isRecording, let start = recordingStartedAt, limitSeconds > 60 else {
            if isInFinalMinute, !visiblePhase.isRecording || recordingStartedAt == nil { isInFinalMinute = false }
            return
        }
        let fireAt = start.addingTimeInterval(limitSeconds - 60)
        let delay = fireAt.timeIntervalSinceNow
        if delay <= 0 {
            if !isInFinalMinute { isInFinalMinute = true }
            return
        }
        if isInFinalMinute { isInFinalMinute = false }
        guard autoSettles else { return }
        finalMinuteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.visiblePhase.isRecording else { return }
            self.isInFinalMinute = true
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
    var slowProcessing: TimeInterval = 6
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

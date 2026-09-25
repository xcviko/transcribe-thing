import Foundation

/// Pure dictation reducer (SPEC §4.11, wispr-ux §2.2–2.5). `HotkeyMonitor` only recognizes key gestures;
/// every dictation decision lives here. Time is injected as monotonic seconds so tests can drive it.
struct DictationMachine: Equatable {
    enum Mode: Equatable { case pushToTalk, handsFree }

    enum Capture: Equatable {
        case idle
        /// Mic already capturing, UI hidden (confirm delay).
        case arming(downAt: TimeInterval)
        /// PTT held, UI shown.
        case listening(downAt: TimeInterval)
        /// Hands-free.
        case locked(startedAt: TimeInterval)
        /// Hands-free + PTT key went down: stop on clean release, resume if it was a combo (fn+←).
        case lockedStopPending(startedAt: TimeInterval)
        /// Quick tap; waiting for a second press (double-press → hands-free).
        case tapPending(firstDownAt: TimeInterval)
    }

    enum Input: Equatable {
        /// `pttInterrupted`: another key, extra modifier or mouse click while the PTT key is held.
        case pttDown, pttUp, pttInterrupted
        case handsFreeToggle, cancel, pillClick, pillStop, pillCancel
        case timer(TimerID)
        case captureFailed(MurmurError), deviceLost
        /// Bookkeeping for `isBusy`.
        case jobStarted, jobEnded
    }

    enum TimerID: Equatable, Hashable, CaseIterable { case arming, doublePressWindow, limitWarning, limit }

    enum Effect: Equatable {
        case startCapture
        case stopCaptureAndTranscribe(mode: Mode)
        case cancelCapture(keepForUndo: Bool, notify: Bool)
        /// .listening / .locked / .rest (rest or hidden per pill mode).
        case showPill(PillPhase)
        case playSound(SoundEffect)
        case schedule(TimerID, after: TimeInterval), cancelTimer(TimerID)
        case cancelNewestJob
        case notice(NoticeKind)
    }

    enum NoticeKind: Equatable {
        case oneMinuteLeft, limitReached, stoppedByOtherKey, deviceLostTranscribing, captureFailed(MurmurError)
    }

    struct Config: Equatable {
        var armingDelay = 0.12
        var tapThreshold = 0.30
        var doublePressWindow = 0.50
        var quietInterruptWindow = 1.5
        var maxDuration: TimeInterval = 1200
        var warnBefore: TimeInterval = 60
        var doublePressEnabled = true
    }

    private(set) var capture: Capture = .idle
    private(set) var activeJobs: Int = 0
    var config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    var isRecording: Bool {
        switch capture {
        case .arming, .listening, .locked, .lockedStopPending: true
        case .idle, .tapPending: false
        }
    }

    /// HotkeyMonitor swallows Esc only while busy.
    var isBusy: Bool { isRecording || activeJobs > 0 }

    /// Hands-free or push-to-talk, for the states that record.
    var mode: Mode? {
        switch capture {
        case .arming, .listening: .pushToTalk
        case .locked, .lockedStopPending: .handsFree
        case .idle, .tapPending: nil
        }
    }

    /// When the current recording started (monotonic seconds), nil when not recording.
    var recordingStartedAt: TimeInterval? {
        switch capture {
        case .arming(let t), .listening(let t), .locked(let t), .lockedStopPending(let t): t
        case .idle, .tapPending: nil
        }
    }

    // MARK: - Reducer

    mutating func handle(_ input: Input, now: TimeInterval) -> [Effect] {
        switch input {
        case .jobStarted:
            activeJobs += 1
            return []
        case .jobEnded:
            activeJobs = max(0, activeJobs - 1)
            return []
        default:
            break
        }

        switch capture {
        case .idle:
            return handleIdle(input, now: now)
        case .arming(let downAt):
            return handleArming(input, downAt: downAt, now: now)
        case .listening(let downAt):
            return handleListening(input, downAt: downAt, now: now)
        case .locked(let startedAt):
            return handleLocked(input, startedAt: startedAt, now: now)
        case .lockedStopPending(let startedAt):
            return handleLockedStopPending(input, startedAt: startedAt, now: now)
        case .tapPending(let firstDownAt):
            return handleTapPending(input, firstDownAt: firstDownAt, now: now)
        }
    }

    private mutating func handleIdle(_ input: Input, now: TimeInterval) -> [Effect] {
        switch input {
        case .pttDown:
            capture = .arming(downAt: now)
            return [.startCapture, .schedule(.arming, after: config.armingDelay)]
        case .handsFreeToggle, .pillClick:
            return lockFromRest(now: now)
        case .cancel where activeJobs > 0:
            return [.cancelNewestJob, .playSound(.cancel)]
        default:
            return []
        }
    }

    private mutating func handleArming(_ input: Input, downAt: TimeInterval, now: TimeInterval) -> [Effect] {
        switch input {
        case .timer(.arming):
            capture = .listening(downAt: downAt)
            return [.showPill(.listening), .playSound(.start)] + limitTimers(startedAt: downAt, now: now)
        case .pttUp:
            capture = .tapPending(firstDownAt: downAt)
            return [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false),
                    .schedule(.doublePressWindow, after: doublePressRemaining(firstDownAt: downAt, now: now))]
        case .pttInterrupted:
            capture = .idle
            return [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false)]
        case .handsFreeToggle:
            capture = .locked(startedAt: downAt)
            // Limit timers only start once arming confirms, so a lock straight from arming schedules them here.
            return [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)] + limitTimers(startedAt: downAt, now: now)
        case .cancel, .pillCancel:
            return cancelRecording()
        case .deviceLost:
            capture = .idle
            return [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false)]
        case .captureFailed(let error):
            return failCapture(error)
        default:
            return []
        }
    }

    private mutating func handleListening(_ input: Input, downAt: TimeInterval, now: TimeInterval) -> [Effect] {
        let held = now - downAt
        switch input {
        case .pttUp where held < config.tapThreshold:
            capture = .tapPending(firstDownAt: downAt)
            return cancelLimitTimers + [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest),
                                        .schedule(.doublePressWindow, after: doublePressRemaining(firstDownAt: downAt, now: now))]
        case .pttUp:
            capture = .idle
            return cancelLimitTimers + [.stopCaptureAndTranscribe(mode: .pushToTalk), .playSound(.stop)]
        case .pttInterrupted where held < config.quietInterruptWindow:
            capture = .idle
            return cancelLimitTimers + [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)]
        case .pttInterrupted:
            capture = .idle
            return cancelLimitTimers + [.cancelCapture(keepForUndo: true, notify: false), .showPill(.rest),
                                        .notice(.stoppedByOtherKey)]
        case .handsFreeToggle:
            capture = .locked(startedAt: downAt)
            return [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)]
        case .cancel, .pillCancel:
            return cancelRecording()
        case .timer(.limitWarning):
            return [.notice(.oneMinuteLeft)]
        case .timer(.limit):
            capture = .idle
            return [.stopCaptureAndTranscribe(mode: .pushToTalk), .notice(.limitReached)]
        case .deviceLost:
            capture = .idle
            return cancelLimitTimers + [.stopCaptureAndTranscribe(mode: .pushToTalk), .notice(.deviceLostTranscribing)]
        case .captureFailed(let error):
            return failCapture(error)
        default:
            return []
        }
    }

    private mutating func handleLocked(_ input: Input, startedAt: TimeInterval, now: TimeInterval) -> [Effect] {
        switch input {
        case .pttDown:
            capture = .lockedStopPending(startedAt: startedAt)
            return []
        case .pttUp:
            // Release of the key that locked it (fn+Space, or the second press of a double-press).
            return []
        case .handsFreeToggle, .pillStop:
            return finishHandsFree()
        default:
            return handleHandsFreeCommon(input)
        }
    }

    private mutating func handleLockedStopPending(_ input: Input, startedAt: TimeInterval, now: TimeInterval) -> [Effect] {
        switch input {
        case .pttUp, .handsFreeToggle, .pillStop:
            return finishHandsFree()
        case .pttInterrupted:
            // It was a combo like fn+←: keep recording.
            capture = .locked(startedAt: startedAt)
            return []
        default:
            return handleHandsFreeCommon(input)
        }
    }

    private mutating func handleHandsFreeCommon(_ input: Input) -> [Effect] {
        switch input {
        case .cancel, .pillCancel:
            return cancelRecording()
        case .timer(.limitWarning):
            return [.notice(.oneMinuteLeft)]
        case .timer(.limit):
            capture = .idle
            return [.stopCaptureAndTranscribe(mode: .handsFree), .notice(.limitReached)]
        case .deviceLost:
            capture = .idle
            return cancelLimitTimers + [.stopCaptureAndTranscribe(mode: .handsFree), .notice(.deviceLostTranscribing)]
        case .captureFailed(let error):
            return failCapture(error)
        default:
            return []
        }
    }

    private mutating func handleTapPending(_ input: Input, firstDownAt: TimeInterval, now: TimeInterval) -> [Effect] {
        switch input {
        case .pttDown where config.doublePressEnabled && now - firstDownAt <= config.doublePressWindow:
            capture = .locked(startedAt: now)
            return [.cancelTimer(.doublePressWindow), .startCapture, .showPill(.locked), .playSound(.lock)]
                + limitTimers(startedAt: now, now: now)
        case .pttDown:
            capture = .arming(downAt: now)
            return [.cancelTimer(.doublePressWindow), .startCapture, .schedule(.arming, after: config.armingDelay)]
        case .timer(.doublePressWindow):
            capture = .idle
            return []
        case .handsFreeToggle, .pillClick:
            return lockFromRest(now: now)
        default:
            return []
        }
    }

    // MARK: - Shared transitions

    private mutating func lockFromRest(now: TimeInterval) -> [Effect] {
        capture = .locked(startedAt: now)
        return [.cancelTimer(.doublePressWindow), .startCapture, .showPill(.locked), .playSound(.lock)]
            + limitTimers(startedAt: now, now: now)
    }

    private mutating func finishHandsFree() -> [Effect] {
        capture = .idle
        return cancelLimitTimers + [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)]
    }

    private mutating func cancelRecording() -> [Effect] {
        capture = .idle
        return cancelAllTimers + [.cancelCapture(keepForUndo: true, notify: true), .playSound(.cancel)]
    }

    private mutating func failCapture(_ error: MurmurError) -> [Effect] {
        capture = .idle
        return cancelAllTimers + [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest),
                                  .notice(.captureFailed(error))]
    }

    /// Both limit timers, measured from the moment the recording started (not from now).
    private func limitTimers(startedAt: TimeInterval, now: TimeInterval) -> [Effect] {
        let elapsed = max(0, now - startedAt)
        let warnAt = max(0, config.maxDuration - config.warnBefore)
        return [.schedule(.limitWarning, after: max(0, warnAt - elapsed)),
                .schedule(.limit, after: max(0, config.maxDuration - elapsed))]
    }

    private var cancelLimitTimers: [Effect] { [.cancelTimer(.limitWarning), .cancelTimer(.limit)] }

    private var cancelAllTimers: [Effect] { TimerID.allCases.map { .cancelTimer($0) } }

    private func doublePressRemaining(firstDownAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0, firstDownAt + config.doublePressWindow - now)
    }
}

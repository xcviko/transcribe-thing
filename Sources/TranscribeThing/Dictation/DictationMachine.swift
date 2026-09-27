import Foundation

/// Pure dictation reducer (SPEC §4.11, wispr-ux §2.2–2.5). `HotkeyMonitor` only recognizes key gestures;
/// every dictation decision lives here. Time is injected as monotonic seconds so tests can drive it.
struct DictationMachine: Equatable {
    enum Mode: Equatable { case pushToTalk, handsFree }

    enum Capture: Equatable {
        case idle
        /// Key down: the pill is up and the mic is opening, but the start sound, the limit timers and any refusal
        /// wait for the confirm delay, so a quick tap or an fn combo (fn+←) stays quiet.
        case arming(downAt: TimeInterval)
        /// PTT held past the confirm delay.
        case listening(downAt: TimeInterval)
        /// Hands-free.
        case locked(startedAt: TimeInterval)
        /// Hands-free + PTT key went down: stop on clean release, resume if it was a combo (fn+←).
        case lockedStopPending(startedAt: TimeInterval)
        /// Quick tap; waiting for a second press (double-press → hands-free). The mic is off but the pill stays up
        /// until the window closes, so a double-press grows straight into hands-free instead of blinking.
        case tapPending(firstDownAt: TimeInterval)
    }

    enum Input: Equatable {
        /// `pttInterrupted`: another key, extra modifier or mouse click while the PTT key is held.
        case pttDown, pttUp, pttInterrupted
        case handsFreeToggle, cancel, pillClick, pillStop, pillCancel
        /// Undo of a canceled dictation: record on, hands-free, after `prefix` seconds of kept audio.
        case resume(prefix: TimeInterval)
        case timer(TimerID)
        case captureFailed(AppError), deviceLost
        /// Bookkeeping for `isBusy`.
        case jobStarted, jobEnded
    }

    enum TimerID: Equatable, Hashable, CaseIterable { case arming, doublePressWindow, limitWarning, limit }

    enum Effect: Equatable {
        case startCapture
        /// Start capture continuing the kept recording being resumed: its audio comes first.
        case resumeCapture
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
        case oneMinuteLeft, limitReached, stoppedByOtherKey, deviceLostTranscribing, captureFailed(AppError)
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
    /// Locked by the second press of a double-press, and that press is still down. The router reports the
    /// press before it can know a chord follows, so fn tap, then fn+Space arrives as pttDown (locks) and then
    /// handsFreeToggle, which only confirms the lock.
    private(set) var lockingPressHeld = false
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

        let effects = reduce(input, now: now)
        if case .locked = capture {} else { lockingPressHeld = false }
        return effects
    }

    private mutating func reduce(_ input: Input, now: TimeInterval) -> [Effect] {
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
            return arm(now: now)
        case .handsFreeToggle, .pillClick:
            return lockFromRest(now: now)
        case .resume(let prefix):
            return resumeFromRest(prefix: prefix, now: now)
        case .cancel where activeJobs > 0:
            return [.cancelNewestJob, .playSound(.cancel)]
        default:
            return []
        }
    }

    private mutating func handleArming(_ input: Input, downAt: TimeInterval, now: TimeInterval) -> [Effect] {
        switch input {
        case .timer(.arming):
            // The pill has been up since key-down; the sound confirms a real hold.
            capture = .listening(downAt: downAt)
            return [.playSound(.start)] + limitTimers(startedAt: downAt, now: now)
        case .pttUp:
            return [.cancelTimer(.arming)] + releaseTap(firstDownAt: downAt, now: now)
        case .pttInterrupted:
            capture = .idle
            return [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)]
        case .handsFreeToggle:
            capture = .locked(startedAt: downAt)
            // Limit timers only start once arming confirms, so a lock straight from arming schedules them here.
            return [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)] + limitTimers(startedAt: downAt, now: now)
        case .cancel, .pillCancel:
            return cancelRecording()
        case .deviceLost:
            capture = .idle
            return [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)]
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
            return cancelLimitTimers + releaseTap(firstDownAt: downAt, now: now)
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
            lockingPressHeld = false
            return []
        case .pttInterrupted:
            // The locking press became a combo (fn+←): it is over, and the recording goes on.
            lockingPressHeld = false
            return []
        case .handsFreeToggle where lockingPressHeld:
            lockingPressHeld = false
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
            lockingPressHeld = true
            return [.cancelTimer(.doublePressWindow), .startCapture, .showPill(.locked), .playSound(.lock)]
                + limitTimers(startedAt: now, now: now)
        case .pttDown:
            return [.cancelTimer(.doublePressWindow)] + arm(now: now)
        case .timer(.doublePressWindow):
            capture = .idle
            return [.showPill(.rest)]
        case .handsFreeToggle, .pillClick:
            return lockFromRest(now: now)
        case .resume(let prefix):
            return resumeFromRest(prefix: prefix, now: now)
        default:
            return []
        }
    }

    // MARK: - Shared transitions

    /// Key down: the pill comes first, in this very turn, so the mic open never delays its first frame.
    private mutating func arm(now: TimeInterval) -> [Effect] {
        capture = .arming(downAt: now)
        return [.showPill(.listening), .startCapture, .schedule(.arming, after: config.armingDelay)]
    }

    /// A quick tap: the mic closes without a sound. With double-press on, the pill stays up for the rest of the
    /// window (a second press locks it where it is); otherwise it folds away at once.
    private mutating func releaseTap(firstDownAt: TimeInterval, now: TimeInterval) -> [Effect] {
        guard config.doublePressEnabled else {
            capture = .idle
            return [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)]
        }
        capture = .tapPending(firstDownAt: firstDownAt)
        return [.cancelCapture(keepForUndo: false, notify: false),
                .schedule(.doublePressWindow, after: doublePressRemaining(firstDownAt: firstDownAt, now: now))]
    }

    private mutating func lockFromRest(now: TimeInterval) -> [Effect] {
        capture = .locked(startedAt: now)
        return [.cancelTimer(.doublePressWindow), .startCapture, .showPill(.locked), .playSound(.lock)]
            + limitTimers(startedAt: now, now: now)
    }

    /// Hands-free again, as if recording had never stopped: the timer and the limit count the kept audio too.
    private mutating func resumeFromRest(prefix: TimeInterval, now: TimeInterval) -> [Effect] {
        let startedAt = now - max(0, prefix)
        capture = .locked(startedAt: startedAt)
        return [.cancelTimer(.doublePressWindow), .resumeCapture, .showPill(.locked), .playSound(.lock)]
            + limitTimers(startedAt: startedAt, now: now)
    }

    private mutating func finishHandsFree() -> [Effect] {
        capture = .idle
        return cancelLimitTimers + [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)]
    }

    private mutating func cancelRecording() -> [Effect] {
        capture = .idle
        return cancelAllTimers + [.cancelCapture(keepForUndo: true, notify: true), .playSound(.cancel)]
    }

    private mutating func failCapture(_ error: AppError) -> [Effect] {
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

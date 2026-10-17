import Foundation

/// Pure dictation reducer (SPEC §4.11, wispr-ux §2.2–2.5). `HotkeyMonitor` only recognizes key gestures;
/// every dictation decision lives here. Time is injected as monotonic seconds so tests can drive it.
struct DictationMachine: Equatable {
    /// Raw values are stored: General → Pasting's rules (`AppSettings`) and History's entries.
    enum Mode: String, Codable, CaseIterable, Sendable { case pushToTalk, handsFree }

    enum Capture: Equatable {
        case idle
        /// Key down: the pill is up, the mic is opening and the start sound plays, but a refusal waits for the
        /// confirm delay, so a quick tap or an fn combo (fn+←) shows no error.
        case arming(downAt: TimeInterval)
        /// PTT held past the confirm delay.
        case listening(downAt: TimeInterval)
        /// Hands-free.
        case locked(startedAt: TimeInterval)
        /// Hands-free + PTT key went down: stop on clean release, resume if it was a combo (fn+←, fn+Space).
        case lockedStopPending(startedAt: TimeInterval)
    }

    enum Input: Equatable {
        /// `pttInterrupted`: another key, extra modifier or mouse click while the PTT key is held.
        case pttDown, pttUp, pttInterrupted
        /// `handsFreeToggle`: the hands-free shortcut. It only starts hands-free. Pressed during hands-free, the
        /// recording goes on, and a PTT key pressed for it (fn of fn+Space) no longer finishes on release. A lone PTT
        /// press finishes, Esc cancels.
        case handsFreeToggle, cancel, pillClick, pillStop, pillCancel
        /// The switch model shortcut: another engine for the dictation being recorded.
        case cycleEngine
        /// The polish shortcut: Polish on or off for the dictation being recorded.
        case polish
        /// The translate shortcut: Translate on or off for the dictation being recorded.
        case translate
        /// The send shortcut: Send on or off for the dictation being recorded (Return once its text is pasted).
        case send
        /// Undo of a canceled dictation: record on, hands-free, after `prefix` seconds of kept audio.
        case resume(prefix: TimeInterval)
        /// A key took the press over (Polish Selection, fn D in push-to-talk): the recording goes without a sound,
        /// kept for Undo only if something was said in it (`discardCapture`).
        case discard
        /// A key the press was for that changes nothing here (fn D, the polish key off Gemini saying why it can't):
        /// in hands-free, the push-to-talk key's release then doesn't finish it.
        case keyUsed
        case timer(TimerID)
        case captureFailed(AppError), deviceLost
        /// Bookkeeping for `isBusy`.
        case jobStarted, jobEnded

        var isResume: Bool {
            if case .resume = self { true } else { false }
        }
    }

    enum TimerID: Equatable, Hashable, CaseIterable { case arming }

    enum Effect: Equatable {
        case startCapture
        /// Start capture continuing the kept recording being resumed: its audio comes first.
        case resumeCapture
        case stopCaptureAndTranscribe(mode: Mode)
        case cancelCapture(keepForUndo: Bool, notify: Bool)
        /// `Input.discard`: the recording goes, and stays for Undo only if the user had said something in it.
        case discardCapture
        /// .listening / .locked / .rest (rest or hidden per pill mode).
        case showPill(PillPhase)
        case playSound(SoundEffect)
        case schedule(TimerID, after: TimeInterval), cancelTimer(TimerID)
        case cancelNewestJob
        case notice(NoticeKind)
        /// Step to the next engine for this dictation (the controller owns the choice and its sound).
        case cycleEngine
        /// Turn Polish on or off for this dictation (the controller owns it, its sound, and whether it may).
        case polish
        /// Turn Translate on or off for this dictation, as Polish.
        case translate
        /// Turn Send on or off for this dictation (the controller owns it and its sound).
        case send
    }

    enum NoticeKind: Equatable {
        case stoppedByOtherKey, deviceLostTranscribing, captureFailed(AppError)
    }

    struct Config: Equatable {
        var armingDelay = 0.12
        var tapThreshold = 0.30
        var quietInterruptWindow = 1.5
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
        case .idle: false
        }
    }

    /// HotkeyMonitor swallows Esc only while busy.
    var isBusy: Bool { isRecording || activeJobs > 0 }

    /// Hands-free or push-to-talk, for the states that record.
    var mode: Mode? {
        switch capture {
        case .arming, .listening: .pushToTalk
        case .locked, .lockedStopPending: .handsFree
        case .idle: nil
        }
    }

    /// When the current recording started (monotonic seconds), nil when not recording.
    var recordingStartedAt: TimeInterval? {
        switch capture {
        case .arming(let t), .listening(let t), .locked(let t), .lockedStopPending(let t): t
        case .idle: nil
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
        case .discard:
            guard isRecording else { return [] }
            capture = .idle
            return cancelAllTimers + [.discardCapture, .showPill(.rest)]
        default:
            return reduce(input, now: now)
        }
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
            // The pill and the start sound came at key-down; this only confirms a real hold.
            capture = .listening(downAt: downAt)
            return []
        case .pttUp:
            return [.cancelTimer(.arming)] + releaseTap()
        case .pttInterrupted:
            capture = .idle
            return [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)]
        case .handsFreeToggle:
            capture = .locked(startedAt: downAt)
            return [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)]
        case .cancel, .pillCancel:
            return cancelRecording()
        case .cycleEngine:
            return [.cycleEngine]
        case .polish, .translate, .send:
            return Self.keyEffect(input)
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
            return releaseTap()
        case .pttUp:
            capture = .idle
            return [.stopCaptureAndTranscribe(mode: .pushToTalk), .playSound(.stop)]
        case .pttInterrupted where held < config.quietInterruptWindow:
            capture = .idle
            return [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)]
        case .pttInterrupted:
            capture = .idle
            return [.cancelCapture(keepForUndo: true, notify: false), .showPill(.rest), .notice(.stoppedByOtherKey)]
        case .handsFreeToggle:
            capture = .locked(startedAt: downAt)
            return [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)]
        case .cancel, .pillCancel:
            return cancelRecording()
        case .cycleEngine:
            return [.cycleEngine]
        case .polish, .translate, .send:
            return Self.keyEffect(input)
        case .deviceLost:
            capture = .idle
            return [.stopCaptureAndTranscribe(mode: .pushToTalk), .notice(.deviceLostTranscribing)]
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
        case .pttUp, .pttInterrupted:
            // Release of the key that locked it (fn+Space), or that press became a combo (fn+←): the recording
            // goes on.
            return []
        case .handsFreeToggle:
            // Already hands-free: the shortcut only starts it. The PTT key finishes, Esc cancels.
            return []
        case .pillStop:
            return finishHandsFree()
        default:
            return handleHandsFreeCommon(input)
        }
    }

    private mutating func handleLockedStopPending(_ input: Input, startedAt: TimeInterval, now: TimeInterval) -> [Effect] {
        switch input {
        case .pttUp, .pillStop:
            return finishHandsFree()
        case .pttInterrupted, .handsFreeToggle, .keyUsed:
            // It was a combo like fn+←, fn D, or fn+Space, which does nothing while hands-free: keep recording.
            capture = .locked(startedAt: startedAt)
            return []
        case .cycleEngine:
            // fn+Tab: the fn press was for switching, so its release must not stop hands-free.
            capture = .locked(startedAt: startedAt)
            return [.cycleEngine]
        case .polish, .translate, .send:
            // fn P, fn T and fn ↩ likewise.
            capture = .locked(startedAt: startedAt)
            return Self.keyEffect(input)
        default:
            return handleHandsFreeCommon(input)
        }
    }

    private mutating func handleHandsFreeCommon(_ input: Input) -> [Effect] {
        switch input {
        case .cancel, .pillCancel:
            return cancelRecording()
        case .cycleEngine:
            return [.cycleEngine]
        case .polish, .translate, .send:
            return Self.keyEffect(input)
        case .deviceLost:
            capture = .idle
            return [.stopCaptureAndTranscribe(mode: .handsFree), .notice(.deviceLostTranscribing)]
        case .captureFailed(let error):
            return failCapture(error)
        default:
            return []
        }
    }

    // MARK: - Shared transitions

    /// Key down: the pill comes first, in this very turn, so the mic open never delays its first frame. The start
    /// sound follows in the same turn, so it answers the key at once.
    private mutating func arm(now: TimeInterval) -> [Effect] {
        capture = .arming(downAt: now)
        return [.showPill(.listening), .startCapture, .playSound(.start), .schedule(.arming, after: config.armingDelay)]
    }

    /// A quick tap: the mic closes without a sound and the pill folds away at once.
    private mutating func releaseTap() -> [Effect] {
        capture = .idle
        return [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)]
    }

    private mutating func lockFromRest(now: TimeInterval) -> [Effect] {
        capture = .locked(startedAt: now)
        return [.startCapture, .showPill(.locked), .playSound(.lock)]
    }

    /// Hands-free again, as if recording had never stopped: the timer counts the kept audio too.
    private mutating func resumeFromRest(prefix: TimeInterval, now: TimeInterval) -> [Effect] {
        let startedAt = now - max(0, prefix)
        capture = .locked(startedAt: startedAt)
        return [.resumeCapture, .showPill(.locked), .playSound(.lock)]
    }

    private mutating func finishHandsFree() -> [Effect] {
        capture = .idle
        return [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)]
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

    private var cancelAllTimers: [Effect] { TimerID.allCases.map { .cancelTimer($0) } }

    /// What the Polish, Translate and Send keys hand on: the controller turns them on or off for the recording.
    private static func keyEffect(_ input: Input) -> [Effect] {
        switch input {
        case .polish: [.polish]
        case .translate: [.translate]
        case .send: [.send]
        default: []
        }
    }
}

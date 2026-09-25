import Foundation

// STUB (FOUNDATION): SHELL implements `handle` per SPEC §4.11 (pure reducer).
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

    enum TimerID: Equatable, Hashable { case arming, doublePressWindow, limitWarning, limit }

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

    mutating func handle(_ input: Input, now: TimeInterval) -> [Effect] {
        []
    }

    var isRecording: Bool {
        switch capture {
        case .arming, .listening, .locked, .lockedStopPending: true
        case .idle, .tapPending: false
        }
    }

    /// HotkeyMonitor swallows Esc only while busy.
    var isBusy: Bool { isRecording || activeJobs > 0 }
}

import CoreAudio
import Foundation

/// The reference a dictation's echo canceller (`LiveEchoCanceller`) needs: what the Mac plays, as a process tap of
/// every app but this one hears it (`ProcessTapSource`, `.everythingButThisApp`, the tap a manual call recording uses).
///
/// Nothing of it runs at key-down: `start` returns at once and the checks run on a queue of their own while the mic
/// opens. The tap is made only when macOS already lets the app record other apps' sound (it never asks: a tap made
/// without the permission would bring up the system's prompt mid-dictation) and another app is playing sound right
/// now (the HAL's process list, as `CallWatch` reads it). When nothing plays, that's looked at again every
/// `recheck` seconds, so music started mid-dictation is caught too. Until the tap delivers, the mic goes through as
/// recorded.
///
/// This app's own sounds stay out of the reference: the cue that starts a dictation plays before any tap is up and
/// its filter has learned anything, and cues are already turned down in the recording while they play
/// (`AudioRecorder.duckRecording`). Kept in the reference, a ducked cue would only teach the filter an echo that isn't
/// there.
///
/// A call recording that taps everything at the same time has a tap of its own: two taps of the same sound are two
/// HAL objects that don't know of each other.
final class DictationEcho: @unchecked Sendable {
    /// Everything it asks of the system, replaceable in tests.
    struct Sensors: Sendable {
        var permission: @Sendable () -> SystemAudioPermission.Status
        /// Whether an app other than this one is playing sound.
        var othersPlaying: @Sendable () -> Bool
        var makeTap: @Sendable () -> any CallTrackSource
        /// Seconds between looks while nothing plays.
        var recheck: TimeInterval = 1

        static let live = Sensors(
            permission: { SystemAudioPermission.current() },
            othersPlaying: { CoreAudioHAL.othersRunningOutput() },
            makeTap: { ProcessTapSource(target: .everythingButThisApp, label: "dictation") })
    }

    enum Status: String, Sendable {
        /// Not looked yet.
        case checking
        case noPermission
        case nothingPlaying
        /// The tap is made (it may still be starting, or have failed: `problem`).
        case tapping
    }

    private let sensors: Sensors
    private let queue = DispatchQueue(label: "dev.transcribe-thing.audio.echo", qos: .userInitiated)
    private let lock = NSLock()
    // Lock state.
    private var tap: (any CallTrackSource)?
    private var currentStatus = Status.checking
    private var stopped = false
    private var started = false

    init(sensors: Sensors) {
        self.sensors = sensors
    }

    var status: Status { lock.withLock { currentStatus } }

    /// Why the tap gives nothing, once known.
    var problem: String? { lock.withLock { tap }?.problem }

    /// Looks, on its own queue, and makes the tap when it should.
    func start() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started && !stopped
        }
        guard first else { return }
        queue.async { self.look(permissionChecked: false) }
    }

    /// The reference that arrived since the last drain: from the mic's delivery queue.
    func drain() -> [TimedAudio] {
        lock.withLock { tap }?.drain() ?? []
    }

    /// Lets the tap go, off the caller's thread. Safe to call more than once.
    func stop() {
        let tap = lock.withLock { () -> (any CallTrackSource)? in
            stopped = true
            defer { self.tap = nil }
            return self.tap
        }
        guard let tap else { return }
        queue.async { tap.stop() }
    }

    deinit {
        lock.withLock { tap }?.stop()
    }

    // MARK: Queue

    private func look(permissionChecked: Bool) {
        guard !lock.withLock({ stopped }) else { return }
        if !permissionChecked, sensors.permission() != .authorized {
            lock.withLock { currentStatus = .noPermission }
            return
        }
        guard sensors.othersPlaying() else {
            lock.withLock { currentStatus = .nothingPlaying }
            queue.asyncAfter(deadline: .now() + sensors.recheck) { [weak self] in
                self?.look(permissionChecked: true)
            }
            return
        }
        let tap = sensors.makeTap()
        let kept = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            self.tap = tap
            currentStatus = .tapping
            return true
        }
        guard kept else { return }
        tap.start()
    }
}

/// Whether a dictation's echo canceller ran, for the diagnostics log. No audio.
struct EchoCancellationReport: Equatable, Sendable {
    enum Status: String, Sendable {
        /// The canceller found echo and took it out for some of the dictation.
        case on
        /// The tap was up but the mic had none of it in it (headphones, the speakers turned down): the mic as recorded.
        case off
        case noPermission, nothingPlaying
        /// The tap couldn't be made, or gave nothing before the dictation ended.
        case noTap
    }

    var status: Status
    /// How much quieter the Mac's sound got in the mic where it was cancelled, in dB.
    var reductionDB: Double?
    /// Seconds handed back as the canceller's version.
    var seconds: Double = 0
    /// Where the recording turns from the mic as recorded to the canceller's version or back, in samples: the speech
    /// check measures each part on its own (`SpeechAnalyzer.stats(parts:)`).
    var parts: [Int] = []

    init(status: Status, reductionDB: Double? = nil, seconds: Double = 0, parts: [Int] = []) {
        self.status = status
        self.reductionDB = reductionDB
        self.seconds = seconds
        self.parts = parts
    }

    init(echo: DictationEcho.Status, canceller: LiveEchoCanceller.Report) {
        if canceller.cancelledFrames > 0 {
            self.init(status: .on, reductionDB: canceller.echoReductionDB, seconds: canceller.cancelledSeconds,
                      parts: canceller.switches)
        } else if canceller.hadReference {
            self.init(status: .off)
        } else {
            switch echo {
            case .noPermission: self.init(status: .noPermission)
            case .nothingPlaying: self.init(status: .nothingPlaying)
            case .checking, .tapping: self.init(status: .noTap)
            }
        }
    }
}

extension CoreAudioHAL {
    /// Whether a process other than this one is playing sound right now: its output IO runs (macOS 14+). A few
    /// property reads per process connected to coreaudiod; never on the main thread at key-down.
    static func othersRunningOutput() -> Bool {
        let own = getpid()
        for id in processObjectIDs() {
            var output: UInt32 = 0
            guard read(id, kAudioProcessPropertyIsRunningOutput, into: &output), output != 0 else { continue }
            var pid: pid_t = -1
            if read(id, kAudioProcessPropertyPID, into: &pid), pid > 0, pid != own { return true }
        }
        return false
    }
}

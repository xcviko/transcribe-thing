import AppKit
import ApplicationServices
import CoreAudio
import Foundation

/// Follows calls the way both the `--audio-watch` probe and `CallMonitor` do: each look at the HAL's processes becomes
/// one step of `CallDetector` (per app, `CallApp`), and while a call is suspected or on, the followed app's own window
/// is read through Accessibility (`CallMuteReader`): its Mute button, its Leave button, a browser's call tab. Those
/// reads arrive between looks and go to the detector with the next one.
///
/// Everything it asks of the system is in `Sensors`, so tests drive it with a made-up HAL and window reads.
@MainActor
final class CallWatch {
    struct Sensors {
        /// Every process connected to coreaudiod, with what it does now.
        var processRecords: () -> [CoreAudioHAL.ProcessRecord]
        /// The app a process is for (`CallApp.of`); asked once per process.
        var app: (CoreAudioHAL.ProcessRecord) -> CallApp?
        /// The app's processes that have windows.
        var pids: (CallApp) -> [pid_t]
        /// Whether windows can be read at all (the Accessibility permission).
        var canReadWindows: () -> Bool
        /// Reads `app`'s window off the main thread and hands the report back on the main actor. `following` is the
        /// key of the browser tab the call was in.
        var readWindow: (_ app: CallApp, _ pids: [pid_t], _ following: String?,
                         _ done: @escaping @MainActor (CallMuteReader.Report) -> Void) -> Void
        /// The call is over: whatever the reader asked of the app (AXManualAccessibility) is turned back off.
        var releaseWindows: () -> Void

        /// The real HAL and the real Accessibility tree, one read at a time on a queue of their own.
        static func live() -> Sensors {
            let reader = CallMuteReader()
            let queue = DispatchQueue(label: "dev.transcribe-thing.calls.windows", qos: .utility)
            return Sensors(
                processRecords: { CoreAudioHAL.processObjectIDs().compactMap(CoreAudioHAL.processRecord) },
                app: { CallApp.of($0) },
                pids: { app in
                    NSRunningApplication.runningApplications(withBundleIdentifier: app.id).map(\.processIdentifier)
                },
                canReadWindows: { AXIsProcessTrusted() },
                readWindow: { app, pids, following, done in
                    queue.async {
                        let report = reader.read(app, pids: pids, following: following)
                        DispatchQueue.main.async { MainActor.assumeIsolated { done(report) } }
                    }
                },
                releaseWindows: { queue.async { reader.release() } })
        }
    }

    private(set) var detector: CallDetector
    /// Each app's processes known to the HAL, playing or not, by HAL object: what a process tap of the app takes in.
    private(set) var processes: [CallApp: [AudioObjectID]] = [:]
    /// The last window read of the followed app, while it's still the one followed.
    private(set) var lastRead: CallMuteReader.Report?
    /// Whether the followed app's mute has been readable at least once since it was first followed.
    private(set) var muteEverKnown = false
    /// Hears every window read as it arrives, with the app it's of.
    var onRead: ((CallMuteReader.Report, CallApp) -> Void)?
    /// The apps whose mic and sound the detector hears; nil: every app. The others are never followed, so they
    /// neither take the place of a call nor have their windows read.
    var includes: ((CallApp) -> Bool)?

    private let sensors: Sensors
    /// The app each process belongs to, looked up once per process.
    private var apps: [pid_t: CallApp?] = [:]
    /// Reads of the followed app's window that arrived since the last look, for the detector.
    private var windows: [CallApp: CallDetector.Window] = [:]
    private var reading = Reading()

    /// The app whose window is read, and when.
    private struct Reading {
        var app: CallApp?
        var inFlight = false
        var lastRead: TimeInterval?
        var lastKnown = false
    }

    init(settings: CallDetector.Settings = CallDetector.Settings(), sensors: Sensors) {
        detector = CallDetector(settings: settings)
        self.sensors = sensors
    }

    /// One look at `records` (the HAL's, unless given) at `time`, monotonic seconds: what the detector made of it.
    /// Then the followed app's window is read, if one is due.
    func poll(at time: TimeInterval, records given: [CoreAudioHAL.ProcessRecord]? = nil) -> [CallDetector.Event] {
        let records = given ?? sensors.processRecords()
        var seen: Set<pid_t> = []
        var activity: [(CallApp?, CallDetector.Activity)] = []
        var objects: [CallApp: [AudioObjectID]] = [:]
        for record in records where record.pid != getpid() {
            seen.insert(record.pid)
            let app = apps[record.pid] ?? sensors.app(record)
            apps[record.pid] = app
            if let app { objects[app, default: []].append(record.objectID) }
            guard record.isRunningInput || record.isRunningOutput, app.map({ includes?($0) ?? true }) ?? true
            else { continue }
            activity.append((app, CallDetector.Activity(mic: record.isRunningInput, sound: record.isRunningOutput)))
        }
        for pid in apps.keys where !seen.contains(pid) { apps[pid] = nil }
        processes = objects.mapValues { $0.sorted() }
        let events = detector.feed(CallApp.activity(activity), windows: windows, at: time)
        windows = [:]
        readWindow(at: time)
        return events
    }

    /// Stops following now (`CallDetector.stop`) and lets go of the app's window.
    func stop(at time: TimeInterval) -> [CallDetector.Event] {
        let events = detector.stop(at: time)
        if reading.app != nil { sensors.releaseWindows() }
        reading = Reading()
        lastRead = nil
        return events
    }

    // MARK: Windows

    /// Reads the followed app's window: once a second while its mute is known, every 3 s while it isn't (the walk
    /// that looks for it costs the app more), never two reads at once.
    private func readWindow(at time: TimeInterval) {
        guard sensors.canReadWindows() else { return }
        let app = detector.followed?.app
        let following = detector.followed?.tab?.key
        if app != reading.app {
            if reading.app != nil { sensors.releaseWindows() }
            reading = Reading(app: app)
            lastRead = nil
            muteEverKnown = false
        }
        guard let app, !reading.inFlight,
              time - (reading.lastRead ?? -.infinity) >= (reading.lastKnown ? 1 : 3) else { return }
        reading.inFlight = true
        reading.lastRead = time
        sensors.readWindow(app, sensors.pids(app), following) { [weak self] report in
            self?.received(report, for: app)
        }
    }

    private func received(_ report: CallMuteReader.Report, for app: CallApp) {
        guard app == reading.app else { return }
        reading.inFlight = false
        reading.lastKnown = report.read.state.isKnown
        if report.read.state.isKnown { muteEverKnown = true }
        lastRead = report
        if let window = report.window { windows[app] = window }
        onRead?(report, app)
    }
}

import AppKit
import ApplicationServices
import CoreAudio
import Foundation

/// Headless probe for call detection, dispatched by TranscribeThingMain before the app starts:
///
///     transcribe-thing --audio-watch [--for <seconds>] [--call-after <seconds>] [--end-after <seconds>]
///
/// Prints, as they happen, which processes start and stop using a microphone and playing sound, with how long
/// each lasted, and what `CallDetector` makes of them per app (`CallApp`): `CALL?` when one app has both at once,
/// `CALL STARTED` once that has lasted `--call-after` seconds (default 20), `CALL MIC RELEASED` and `CALL MIC BACK`
/// when the app gives the mic back and takes it again (Telegram's mute; leaving, for the apps that keep the mic while
/// muted), and `CALL ENDED` once it has been silent for `--end-after` seconds (default 60), was hung up, or the
/// probe stops. A browser's call is named by its tab's service and page: `CALL STARTED Google Chrome · Google Meet
/// "Meet – abc-defg-hij"`. It polls the HAL twice a second and also listens for its change notifications, printing
/// `listener:` when one arrives, to show whether they can be relied on.
///
/// While a call is suspected or on, it also reads the app's own mute control through Accessibility once a second
/// (`CallMuteReader`) and prints `MUTE` when that changes; for a browser, `TAB` says which tab holds the call. Both go
/// to the detector: a tab of another service ends the call and starts the next, and the Mute button gives the mutes
/// of the apps that keep the mic. When mute can't be read, `AX DUMP` lists the app's buttons, to learn its labels
/// from. That needs the Accessibility permission, which the installed app has and a `swift build` binary doesn't;
/// without it these lines are left out.
/// It only reads: no recording, no settings, no network. The one thing it changes is asking an Electron app or a
/// browser in a call for its web Accessibility tree, turned back off when the call is over.
enum AudioWatchCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--audio-watch")
    }

    static let usage = "usage: transcribe-thing --audio-watch [--for <seconds>] [--call-after <seconds>] [--end-after <seconds>]"

    /// Runs until `--for` runs out or Ctrl-C, then exits the process.
    @MainActor
    static func run(_ arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        func seconds(_ flag: String) -> TimeInterval?? {
            guard let index = arguments.firstIndex(of: flag) else { return .some(nil) }
            guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 else { return nil }
            return .some(value)
        }
        guard let duration = seconds("--for"), let callAfter = seconds("--call-after"), let endAfter = seconds("--end-after")
        else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        var settings = CallDetector.Settings()
        settings.confirmAfter = callAfter ?? settings.confirmAfter
        settings.endAfter = endAfter ?? settings.endAfter
        let watch = AudioWatch(settings: settings)
        watch.start()
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                MainActor.assumeIsolated { watch.finish() }
            }
        }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { MainActor.assumeIsolated { watch.finish() } }
        interrupt.resume()
        withExtendedLifetime(interrupt) { dispatchMain() }
    }
}

@MainActor
private final class AudioWatch {
    private struct Activity {
        var name: String
        var input: Date?
        var output: Date?
    }

    private let started = Date()
    private let listeners = HALListenerSet(queue: .main)
    private var watchedObjects: Set<AudioObjectID> = []
    private var activities: [pid_t: Activity] = [:]
    /// The detector and the window reads, as `CallMonitor` has them.
    private let calls: CallWatch
    private var suspectedAt: TimeInterval?
    private var micReleasedAt: TimeInterval?
    private var deviceInUse: [AudioDeviceID: Bool] = [:]
    private var timer: DispatchSourceTimer?
    private let accessibility = AXIsProcessTrusted()
    private var shown = Shown()

    /// What was last printed for the followed app's window.
    private struct Shown {
        var app: CallApp?
        var tabLine: String?
        var muteLine: String?
        var dump: (lines: [String], at: Date)?
    }

    init(settings: CallDetector.Settings) {
        calls = CallWatch(settings: settings, sensors: .live())
        calls.onRead = { [weak self] report, app in self?.show(report, for: app) }
    }

    private var detector: CallDetector { calls.detector }

    func start() {
        let settings = detector.settings
        print("AUDIO WATCH: polling every 0.5 s plus HAL notifications · a call after \(Int(settings.confirmAfter)) s of "
              + "one app's mic and sound together, over after \(Int(settings.endAfter)) s of silence")
        print("Ctrl-C to stop. pid \(getpid()) is this probe and is left out.")
        if !accessibility { print("AX: no Accessibility permission (run the installed app's binary)") }
        listeners.add(CoreAudioHAL.systemObject, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated { self?.poll(listener: "process list changed") }
        }
        poll(listener: nil)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.poll(listener: nil) } }
        timer.resume()
        self.timer = timer
    }

    func finish() {
        timer?.cancel()
        listeners.invalidate()
        let now = Date()
        let followed = detector.followed
        report(calls.stop(at: now.timeIntervalSince(started)), followed: followed)
        for activity in activities.values.sorted(by: { $0.name < $1.name }) {
            if let since = activity.input { line("\(activity.name): still on mic for \(span(since, now))") }
            if let since = activity.output { line("\(activity.name): still playing sound for \(span(since, now))") }
        }
        line("DONE after \(span(started, now))")
        exit(0)
    }

    private func poll(listener: String?) {
        if let listener { line("listener: \(listener)") }
        let now = Date()
        var seen: Set<pid_t> = []
        var records: [CoreAudioHAL.ProcessRecord] = []
        for object in CoreAudioHAL.processObjectIDs() {
            watch(object)
            guard let record = CoreAudioHAL.processRecord(object), record.pid != getpid() else { continue }
            seen.insert(record.pid)
            update(record, at: now)
            records.append(record)
        }
        for pid in activities.keys where !seen.contains(pid) {
            update(CoreAudioHAL.ProcessRecord(objectID: 0, pid: pid, bundleID: nil, isRunningInput: false,
                                              isRunningOutput: false, inputDevices: [], outputDevices: []), at: now)
            activities[pid] = nil
        }
        let followed = detector.followed
        report(calls.poll(at: now.timeIntervalSince(started), records: records), followed: followed)
        pollDevices()
    }

    // MARK: Windows

    /// Prints what a read of the followed app's window found, when it changed.
    private func show(_ report: CallMuteReader.Report, for app: CallApp) {
        if app != shown.app { shown = Shown(app: app) }
        var name = app.name
        if report.isBrowser {
            let tabLine = Self.tabLine(report, browser: name)
            if tabLine != shown.tabLine { line(tabLine) }
            shown.tabLine = tabLine
            if let tab = report.tab {
                name += " · \(tab.service?.name ?? "unknown service")\(tab.active ? "" : " (background tab)")"
            }
        }
        let read = report.read
        let inCall = read.inCall.map { $0 ? " · in call" : " · no Leave button" } ?? ""
        let muteLine = "MUTE \(name): \(read.state)" + (read.detail.isEmpty ? "" : " (\(read.detail))") + inCall
        if muteLine != shown.muteLine { line(muteLine) }
        shown.muteLine = muteLine
        // A dump again when the controls change, but at most every 10 s: some carry a timer or a count.
        if let dump = report.dump, !dump.isEmpty, dump != shown.dump?.lines,
           Date().timeIntervalSince(shown.dump?.at ?? .distantPast) >= 10 {
            shown.dump = (dump, Date())
            line("AX DUMP \(name), \(dump.count) controls (role, t= title, d= description, v= value, id=):")
            for entry in dump { print("           " + entry) }
        }
    }

    private static func tabLine(_ report: CallMuteReader.Report, browser: String) -> String {
        guard let tab = report.tab else {
            return "TAB \(browser): no tab records or is titled like a call (\(report.windowCount) windows)"
        }
        let window = "window \(tab.window + 1) of \(report.windowCount)"
            + (tab.active ? "" : ", which shows \"\(CallLabels.safe(tab.windowTitle ?? "?", limit: 60))\"")
        let what = tab.recording.map { "is recording (\(tab.active ? "active" : "background"), \($0.name))" }
            ?? "looks like a call by its title, no recording mark (\(tab.active ? "active" : "background"))"
        return "TAB \(browser): \"\(CallLabels.safe(tab.page))\" \(what) · \(tab.service?.name ?? "unknown service") · \(window)"
    }

    private func watch(_ object: AudioObjectID) {
        guard watchedObjects.insert(object).inserted else { return }
        for (selector, label) in [(kAudioProcessPropertyIsRunningInput, "mic"), (kAudioProcessPropertyIsRunningOutput, "sound")] {
            listeners.add(object, selector) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let name = CoreAudioHAL.processRecord(object).map { self.name(of: $0) } ?? "object \(object)"
                    self.poll(listener: "\(name) \(label) changed")
                }
            }
        }
    }

    private func update(_ record: CoreAudioHAL.ProcessRecord, at now: Date) {
        if activities[record.pid] == nil, !record.isRunningInput, !record.isRunningOutput { return }
        var activity = activities[record.pid] ?? Activity(name: name(of: record))
        if record.isRunningInput, activity.input == nil {
            activity.input = now
            line("\(activity.name): MIC ON · \(devices(record.inputDevices))")
        } else if !record.isRunningInput, let since = activity.input {
            activity.input = nil
            line("\(activity.name): mic off after \(span(since, now))")
        }
        if record.isRunningOutput, activity.output == nil {
            activity.output = now
            line("\(activity.name): SOUND ON · \(devices(record.outputDevices))")
        } else if !record.isRunningOutput, let since = activity.output {
            activity.output = nil
            line("\(activity.name): sound off after \(span(since, now))")
        }
        activities[record.pid] = activity.input == nil && activity.output == nil ? nil : activity
    }

    /// What the detector made of the last look, `followed` being the call it followed before. Its times are seconds
    /// since the probe started, like the lines', and can be up to 1.5 s before the line: a signal only counts as off
    /// once it has stayed off.
    private func report(_ events: [CallDetector.Event], followed: CallDetector.Call?) {
        /// The call `app`'s event is about: the one followed now, or the one that just ended.
        func call(of app: CallApp) -> CallDetector.Call? {
            [detector.followed, followed].compactMap { $0 }.first { $0.app == app }
        }
        for event in events {
            switch event {
            case .suspected(let app, let at):
                suspectedAt = at
                let name = detector.followed.map { $0.app == app ? Self.name(of: $0) : app.name } ?? app.name
                line("CALL? \(name): mic and sound together since \(time(at)), keeping audio from there")
            case .dropped(let app, let at):
                line("CALL? \(app.name): not a call, mic and sound together for only \(span(suspectedAt ?? at, at))")
                suspectedAt = nil
            case .started(let call):
                line("CALL STARTED \(Self.name(of: call)): mic and sound together since \(time(call.startedAt))")
                suspectedAt = nil
            case .micReleased(let app, let at):
                micReleasedAt = at
                if let call = call(of: app), !call.micReleaseIsMute {
                    line("CALL MIC RELEASED \(Self.name(of: call)) at \(time(at)): \(call.service?.name ?? "it") keeps "
                         + "the mic while muted, so leaving or reconnecting, not a mute")
                } else {
                    line("CALL MIC RELEASED (muted?) \(call(of: app).map(Self.name) ?? app.name) at \(time(at)), "
                         + "sound goes on")
                }
            case .micBack(let app, let at):
                let released = micReleasedAt.map { " after \(span($0, at))" } ?? ""
                line("CALL MIC BACK \(call(of: app).map(Self.name) ?? app.name) at \(time(at))\(released)")
                micReleasedAt = nil
            case .ended(let call):
                let mutes = call.mutes.isEmpty ? "no mute seen"
                    : "muted " + call.mutes.map { "\(time($0.lowerBound)) to \(time($0.upperBound))" }.joined(separator: ", ")
                line("CALL ENDED \(Self.name(of: call)) after \(span(call.startedAt, call.lastAudioAt)) "
                     + "(\(time(call.startedAt)) to \(time(call.lastAudioAt))), \(mutes)")
                micReleasedAt = nil
            }
        }
    }

    /// The call's app, and for a browser its tab: `Google Chrome · Google Meet "Meet – abc-defg-hij"`.
    private static func name(of call: CallDetector.Call) -> String {
        guard let tab = call.tab else { return call.app.name }
        return "\(call.app.name) · \(tab.service?.name ?? "unknown service") \"\(CallLabels.safe(tab.page, limit: 60))\""
    }

    /// Whether anyone at all uses each microphone, as the device reports it: what apps without per-process
    /// data would see, and a check on Bluetooth headsets that are said not to report it.
    private func pollDevices() {
        for record in CoreAudioHAL.inputRecords() {
            var running: UInt32 = 0
            CoreAudioHAL.read(record.audioID, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running)
            let inUse = running != 0
            guard deviceInUse[record.audioID] != inUse else { continue }
            let first = deviceInUse[record.audioID] == nil
            deviceInUse[record.audioID] = inUse
            if first, !inUse { continue }
            line("device: \(record.device.name) (\(record.device.transport)) \(inUse ? "in use" : "free")")
        }
    }

    private func name(of record: CoreAudioHAL.ProcessRecord) -> String {
        let app = NSRunningApplication(processIdentifier: record.pid)?.localizedName
        var buffer = [CChar](repeating: 0, count: 256)
        let process = proc_name(record.pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        let label = app ?? process ?? "pid \(record.pid)"
        let detail = [record.bundleID, "pid \(record.pid)"].compactMap { $0 }.joined(separator: ", ")
        return "\(label) (\(detail))"
    }

    private func devices(_ ids: [AudioDeviceID]) -> String {
        ids.isEmpty ? "no device listed" : ids.map { CoreAudioHAL.name(of: $0) ?? "device \($0)" }.joined(separator: ", ")
    }

    private func span(_ from: Date, _ to: Date) -> String {
        span(from.timeIntervalSinceReferenceDate, to.timeIntervalSinceReferenceDate)
    }

    private func span(_ from: TimeInterval, _ to: TimeInterval) -> String {
        let seconds = to - from
        return seconds < 60 ? String(format: "%.1f s", seconds) : String(format: "%d min %02d s", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func time(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }

    private func line(_ text: String) {
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "%7.1f  ", elapsed) + text)
    }
}

import AppKit
import CoreAudio
import Foundation

/// Headless probe for call detection, dispatched by TranscribeThingMain before the app starts:
///
///     transcribe-thing --audio-watch [--for <seconds>] [--call-after <seconds>]
///
/// Prints, as they happen, which apps start and stop using a microphone and playing sound, with how long each
/// lasted, and `CALL?` when one app has done both at once for `--call-after` seconds (default 20). It polls
/// the HAL twice a second and also listens for its change notifications, printing `listener:` when one
/// arrives, to show whether they can be relied on. It only reads: no recording, no settings, no network.
enum AudioWatchCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--audio-watch")
    }

    static let usage = "usage: transcribe-thing --audio-watch [--for <seconds>] [--call-after <seconds>]"

    /// Runs until `--for` runs out or Ctrl-C, then exits the process.
    @MainActor
    static func run(_ arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        func seconds(_ flag: String) -> TimeInterval?? {
            guard let index = arguments.firstIndex(of: flag) else { return .some(nil) }
            guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 else { return nil }
            return .some(value)
        }
        guard let duration = seconds("--for"), let callAfter = seconds("--call-after") else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        let watch = AudioWatch(callAfter: callAfter ?? 20)
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
        var both: Date?
        var announcedCall = false
    }

    private let callAfter: TimeInterval
    private let started = Date()
    private let listeners = HALListenerSet(queue: .main)
    private var watchedObjects: Set<AudioObjectID> = []
    private var activities: [pid_t: Activity] = [:]
    private var deviceInUse: [AudioDeviceID: Bool] = [:]
    private var timer: DispatchSourceTimer?

    init(callAfter: TimeInterval) {
        self.callAfter = callAfter
    }

    func start() {
        print("AUDIO WATCH: polling every 0.5 s plus HAL notifications · CALL? after \(Int(callAfter)) s of mic and sound together")
        print("Ctrl-C to stop. pid \(getpid()) is this probe and is left out.")
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
        for object in CoreAudioHAL.processObjectIDs() {
            watch(object)
            guard let record = CoreAudioHAL.processRecord(object), record.pid != getpid() else { continue }
            seen.insert(record.pid)
            update(record, at: now)
        }
        for pid in activities.keys where !seen.contains(pid) {
            update(CoreAudioHAL.ProcessRecord(objectID: 0, pid: pid, bundleID: nil, isRunningInput: false,
                                              isRunningOutput: false, inputDevices: [], outputDevices: []), at: now)
            activities[pid] = nil
        }
        pollDevices()
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
        if activity.input != nil, activity.output != nil {
            let since = activity.both ?? now
            activity.both = since
            if !activity.announcedCall, now.timeIntervalSince(since) >= callAfter {
                activity.announcedCall = true
                line("CALL? \(activity.name): mic and sound together for \(span(since, now))")
            }
        } else if let since = activity.both {
            activity.both = nil
            if activity.announcedCall {
                activity.announcedCall = false
                line("CALL? \(activity.name): mic and sound together ended after \(span(since, now))")
            }
        }
        activities[record.pid] = activity.input == nil && activity.output == nil ? nil : activity
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
        let seconds = to.timeIntervalSince(from)
        return seconds < 60 ? String(format: "%.1f s", seconds) : String(format: "%d min %02d s", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func line(_ text: String) {
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "%7.1f  ", elapsed) + text)
    }
}

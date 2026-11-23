import AppKit
import CoreAudio
import Foundation

/// The app a process plays or records sound for, named by its main bundle id: Chrome's "Google Chrome Helper" and
/// Discord's "Discord Helper (Renderer)" are the same call as their app. `CallDetector` follows these, not processes.
struct CallApp: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The main app's bundle id: "ru.keepcoder.Telegram", "com.google.Chrome", "com.hnc.Discord".
    let id: String

    /// The app `bundleID`'s process belongs to, or nil for one that isn't an app's call: us, and system daemons
    /// (`CallDenylist`; systemsoundserverd plays alert sounds and has no bundle id). `ownerBundleID` is the app that started or is
    /// responsible for the process, when known (`CallApp.of(_:)` looks it up); otherwise helpers are told apart by
    /// their bundle id alone.
    init?(bundleID: String?, ownerBundleID: String? = nil, ownBundleID: String = SingleInstance.bundleIdentifier) {
        let own = Self.mainBundleID(of: ownBundleID)
        if let bundleID, Self.mainBundleID(of: bundleID) == own { return nil }
        guard let candidate = ownerBundleID ?? bundleID else { return nil }
        let main = Self.mainBundleID(of: candidate)
        guard main != own, !CallDenylist.isSystemProcess(main) else { return nil }
        id = main
    }

    /// `bundleID` without a helper's suffix: Chromium and Electron name their processes `<app>.helper`,
    /// `<app>.helper.Renderer`, `.helper.GPU` and `.helper.Plugin` (the "… Helper (Renderer)" process names), so
    /// everything from a `helper…` component on goes. At least two components always stay.
    static func mainBundleID(of bundleID: String) -> String {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let cut = parts.indices.dropFirst(2).first(where: { parts[$0].lowercased().hasPrefix("helper") })
        else { return bundleID }
        return parts[..<cut].joined(separator: ".")
    }

    /// Each app's mic and sound across all its processes: on when any of them has it.
    static func activity(_ processes: some Sequence<(CallApp?, CallDetector.Activity)>) -> [CallApp: CallDetector.Activity] {
        var apps: [CallApp: CallDetector.Activity] = [:]
        for case let (app?, activity) in processes {
            var merged = apps[app] ?? CallDetector.Activity(mic: false, sound: false)
            merged.mic = merged.mic || activity.mic
            merged.sound = merged.sound || activity.sound
            apps[app] = merged
        }
        return apps
    }

    static func < (lhs: CallApp, rhs: CallApp) -> Bool { lhs.id < rhs.id }

    var description: String { id }
}

// MARK: - From the HAL

extension CallApp {
    /// The app a HAL process record is for, or nil for this process and the ones `init` leaves out. The owner is the
    /// parent process when that is an app (Chromium and Electron start their helpers themselves), else the process
    /// macOS holds responsible for it (WebKit's XPC services run for Safari or the app showing the web view).
    static func of(_ record: CoreAudioHAL.ProcessRecord) -> CallApp? {
        guard record.pid != getpid() else { return nil }
        if let bundleID = record.bundleID, CallApp(bundleID: bundleID) == nil { return nil }
        guard let app = CallApp(bundleID: record.bundleID, ownerBundleID: ownerBundleID(of: record.pid)),
              isRunningApp(app.id) else { return nil }
        return app
    }

    /// Whether an app (a running .app bundle) has this bundle id. A process no app owns is the system's: CoreSpeech
    /// holds the mic and plays sound while macOS listens for speech (during a dictation, too), and isn't a call.
    private static func isRunningApp(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.bundleURL?.pathExtension.lowercased() == "app" }
    }

    /// The localized name of the app's running copy ("Telegram", "Google Chrome"), or its bundle id.
    @MainActor
    var name: String {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id
    }

    private static func ownerBundleID(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            let parent = pid_t(info.pbi_ppid)
            if parent > 1, let owner = NSRunningApplication(processIdentifier: parent)?.bundleIdentifier { return owner }
        }
        guard let responsible = responsiblePID(pid), responsible != pid, responsible > 1 else { return nil }
        return NSRunningApplication(processIdentifier: responsible)?.bundleIdentifier
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// libsystem's `responsibility_get_pid_responsible_for_pid`: private, so looked up at run time and skipped when
    /// a macOS release drops it. No public API says whom an XPC service works for.
    private static let responsibleFunction: ResponsibleFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let responsible = responsibleFunction(pid)
        return responsible > 0 ? responsible : nil
    }
}

import Foundation

/// Whether macOS lets this app record other apps' sound (Privacy & Security → Screen & System Audio Recording →
/// System Audio Recording Only), which taking music out of a dictation needs (`DictationEcho`). There's no public way
/// to ask, and a tap without it just hands back silence, as does a Mac playing nothing: so the app asks TCC's
/// preflight, looked up at run time and taken as unknown when it's missing.
enum SystemAudioPermission {
    enum Status: Equatable, Sendable {
        case authorized, denied, unknown
    }

    /// The status now. Tests replace it.
    nonisolated(unsafe) static var current: @Sendable () -> Status = { preflight() }

    /// Brings up macOS's question, which comes the first time the app makes a tap: one of everything, let go a moment
    /// later. Nothing it hears is kept. General → Permissions' Allow, never a dictation.
    static func ask() {
        let tap = ProcessTapSource(label: "permission")
        tap.start()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            _ = tap.drain()
            tap.stop()
        }
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int

    private static let preflightFunction: Preflight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    /// 0: granted, 1: denied, anything else: not asked yet.
    private static func preflight() -> Status {
        guard let preflightFunction else { return .unknown }
        switch preflightFunction("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }
}

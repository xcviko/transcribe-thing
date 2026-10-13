import Foundation

/// Whether macOS lets this app record other apps' sound (Privacy & Security → Screen & System Audio Recording →
/// System Audio Recording Only), which a call's other side needs. There's no public way to ask, and a tap without it
/// just hands back silence, as does a call where nobody on the other side speaks: so the app asks TCC's preflight,
/// looked up at run time and taken as unknown when it's missing.
enum SystemAudioPermission {
    enum Status: Equatable, Sendable {
        case authorized, denied, unknown
    }

    /// The status now. Tests replace it.
    nonisolated(unsafe) static var current: @Sendable () -> Status = { preflight() }

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

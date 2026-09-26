import Darwin
import Foundation

/// Monotonic clock shared by the capture thread, the level meter and the UI.
/// Same timebase as `ProcessInfo.systemUptime`, `CACurrentMediaTime()` and `AVAudioTime` host time.
enum AudioClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> TimeInterval {
        seconds(hostTime: mach_absolute_time())
    }

    static func seconds(hostTime: UInt64) -> TimeInterval {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func hostTime(seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }
}

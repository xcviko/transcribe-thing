import Foundation

struct DownloadProgress: Sendable, Equatable {
    /// 0...1
    var fraction: Double
    var bytesReceived: Int64
    var totalBytes: Int64
    /// Smoothed transfer rate.
    var bytesPerSecond: Double?
    var secondsRemaining: Double?

    init(
        fraction: Double,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double? = nil,
        secondsRemaining: Double? = nil
    ) {
        self.fraction = min(max(fraction, 0), 1)
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = secondsRemaining
    }

    static let zero = DownloadProgress(fraction: 0)

    /// Whole percent, never shows 100 until the download is actually complete.
    var percent: Int {
        fraction >= 1 ? 100 : min(99, Int((fraction * 100).rounded(.down)))
    }
}

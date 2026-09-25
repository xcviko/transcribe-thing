import Foundation

/// Turns raw download fractions into `DownloadProgress` with a smoothed transfer rate and ETA.
///
/// Nothing is reported during `warmUp`: the first seconds of a transfer (TLS, redirects, many small files)
/// say little about its speed. The rate is then seeded with the average over the warm-up window and
/// exponentially smoothed with a time constant (not per sample), so irregular callback timing doesn't make
/// it jump. The ETA is derived from that smoothed rate; smoothing the ETA a second time would make it lag
/// far behind reality after a slow start.
struct DownloadRateEstimator: Sendable {
    let totalBytes: Int64
    var timeConstant: TimeInterval = 3
    var warmUp: TimeInterval = 1.5
    /// Samples closer together than this are merged into the next one.
    var minimumInterval: TimeInterval = 0.2
    static let maximumETA: TimeInterval = 86_400

    private var startTime: TimeInterval?
    private var startBytes: Int64 = 0
    private var lastTime: TimeInterval = 0
    private var lastBytes: Int64 = 0
    private var rate: Double?

    init(totalBytes: Int64) {
        self.totalBytes = max(0, totalBytes)
    }

    var smoothedBytesPerSecond: Double? { rate }

    mutating func progress(fraction raw: Double, at now: TimeInterval) -> DownloadProgress {
        let fraction = min(max(raw.isFinite ? raw : 0, 0), 1)
        let bytes = Int64((Double(totalBytes) * fraction).rounded())

        guard let startTime else {
            // A resumed download starts at its resume offset; only bytes after this point count as speed.
            self.startTime = now
            startBytes = bytes
            lastTime = now
            lastBytes = bytes
            return DownloadProgress(fraction: fraction, bytesReceived: bytes, totalBytes: totalBytes)
        }

        let dt = now - lastTime
        if let current = rate {
            if dt >= minimumInterval {
                let instant = Double(max(0, bytes - lastBytes)) / dt
                let alpha = 1 - exp(-dt / timeConstant)
                rate = current + alpha * (instant - current)
                lastTime = now
                lastBytes = bytes
            }
        } else if now - startTime >= warmUp {
            rate = Double(max(0, bytes - startBytes)) / (now - startTime)
            lastTime = now
            lastBytes = bytes
        }

        let remaining: Double? = if fraction >= 1 {
            0
        } else if let rate, rate > 1 {
            // Beyond a day the transfer is effectively stalled; a number would only alarm.
            Optional(Double(max(0, totalBytes - bytes)) / rate).flatMap { $0 <= Self.maximumETA ? $0 : nil }
        } else {
            nil
        }
        return DownloadProgress(fraction: fraction, bytesReceived: bytes, totalBytes: totalBytes,
                                bytesPerSecond: rate, secondsRemaining: remaining)
    }
}

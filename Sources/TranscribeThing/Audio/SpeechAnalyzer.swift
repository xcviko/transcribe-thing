import Accelerate
import Foundation

/// Pure pre-flight analysis of a finished recording: is the signal dead, and how much of it is voice?
///
/// Voiced time is measured against an adaptive noise floor (10th percentile of 10 ms frame energies in a
/// ±3 s neighbourhood), so a noisy café and a silent studio both work, and steady noise alone (fan, hum,
/// a stationary tone) never counts as speech.
enum SpeechAnalyzer {
    struct Parameters: Sendable {
        var frameSeconds: Double = 0.010
        /// A frame is voiced when its energy exceeds the local noise floor by this much.
        var voicedMarginDB: Float = 10
        /// Floor estimates never go below this, so near-digital silence can't make faint hiss "voiced".
        var minimumFloorDBFS: Float = -75
        /// Voiced runs shorter than this (key clicks, pops) are ignored.
        var minimumRunSeconds: Double = 0.040
        /// The floor is re-estimated per block, from frames within ±`floorRadiusSeconds`.
        var floorBlockSeconds: Double = 0.5
        var floorRadiusSeconds: Double = 3.0
        var floorPercentile: Double = 0.10
    }

    /// Below this peak the signal is digital silence: a muted, disconnected or permission-blocked mic.
    static let digitalSilencePeak: Float = 1e-7

    static func stats(for samples: [Float]) -> SpeechStats {
        stats(for: samples, sampleRate: Recording.sampleRate)
    }

    static func stats(for samples: [Float], sampleRate: Double, parameters: Parameters = Parameters()) -> SpeechStats {
        guard !samples.isEmpty, sampleRate > 0 else { return .empty }

        var minValue: Float = 0
        var maxValue: Float = 0
        vDSP_minv(samples, 1, &minValue, vDSP_Length(samples.count))
        vDSP_maxv(samples, 1, &maxValue, vDSP_Length(samples.count))
        let peak = max(abs(minValue), abs(maxValue))
        let peakDB = peak > 0 ? max(20 * log10(peak), -160) : -160

        // Zero or a constant (DC-stuck) signal carries nothing.
        if peak < digitalSilencePeak || maxValue - minValue < digitalSilencePeak * 10 {
            return SpeechStats(voicedSeconds: 0, peakDBFS: peakDB, isSilent: true)
        }

        let frameDB = frameLevels(samples, frameLength: max(1, Int(sampleRate * parameters.frameSeconds)))
        let voicedFrames = countVoicedFrames(frameDB, parameters: parameters)
        return SpeechStats(voicedSeconds: Double(voicedFrames) * parameters.frameSeconds,
                           peakDBFS: peakDB, isSilent: false)
    }

    /// AC energy (mean removed) of each frame in dBFS; digital-zero frames report -160.
    static func frameLevels(_ samples: [Float], frameLength: Int) -> [Float] {
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else {
            return [acLevelDB(samples[...])]
        }
        var levels = [Float](repeating: -160, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                let start = buffer.baseAddress! + frame * frameLength
                var mean: Float = 0
                var meanSquare: Float = 0
                vDSP_meanv(start, 1, &mean, vDSP_Length(frameLength))
                vDSP_measqv(start, 1, &meanSquare, vDSP_Length(frameLength))
                let variance = max(0, meanSquare - mean * mean)
                levels[frame] = variance > 1e-16 ? max(10 * log10(variance), -160) : -160
            }
        }
        return levels
    }

    private static func acLevelDB(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return -160 }
        let mean = slice.reduce(0, +) / Float(slice.count)
        let variance = slice.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(slice.count)
        return variance > 1e-16 ? max(10 * log10(variance), -160) : -160
    }

    /// Number of frames that sit `voicedMarginDB` above the local noise floor, in runs long enough to be speech.
    static func countVoicedFrames(_ frameDB: [Float], parameters: Parameters = Parameters()) -> Int {
        guard !frameDB.isEmpty else { return 0 }
        let floors = localFloors(frameDB, parameters: parameters)
        let minimumRun = max(1, Int((parameters.minimumRunSeconds / parameters.frameSeconds).rounded()))

        var voiced = 0
        var run = 0
        for index in frameDB.indices {
            let threshold = max(floors[index], parameters.minimumFloorDBFS) + parameters.voicedMarginDB
            if frameDB[index] > threshold {
                run += 1
            } else {
                if run >= minimumRun { voiced += run }
                run = 0
            }
        }
        if run >= minimumRun { voiced += run }
        return voiced
    }

    /// Per-frame noise floor from a sliding histogram (0.5 dB bins) of the surrounding blocks. Linear time,
    /// so a 20-minute recording analyses in a few milliseconds.
    static func localFloors(_ frameDB: [Float], parameters: Parameters = Parameters()) -> [Float] {
        let binWidth: Float = 0.5
        let lowest: Float = -120
        let binCount = Int(-lowest / binWidth) + 1
        func bin(_ db: Float) -> Int? {
            guard db > lowest else { return nil }        // digital zero (ducked or dropped audio) is not "noise"
            return min(binCount - 1, Int((db - lowest) / binWidth))
        }

        let framesPerBlock = max(1, Int((parameters.floorBlockSeconds / parameters.frameSeconds).rounded()))
        let blockCount = (frameDB.count + framesPerBlock - 1) / framesPerBlock
        let radius = max(0, Int((parameters.floorRadiusSeconds / parameters.floorBlockSeconds).rounded()))

        var blockHistograms = [[Int32]](repeating: [Int32](repeating: 0, count: binCount), count: blockCount)
        var blockTotals = [Int](repeating: 0, count: blockCount)
        for (index, db) in frameDB.enumerated() {
            guard let b = bin(db) else { continue }
            blockHistograms[index / framesPerBlock][b] += 1
            blockTotals[index / framesPerBlock] += 1
        }

        var window = [Int32](repeating: 0, count: binCount)
        var windowTotal = 0
        func add(_ block: Int, _ sign: Int32) {
            guard block >= 0, block < blockCount else { return }
            for b in 0..<binCount where blockHistograms[block][b] != 0 {
                window[b] += sign * blockHistograms[block][b]
            }
            windowTotal += Int(sign) * blockTotals[block]
        }
        for block in 0...min(radius, blockCount - 1) { add(block, 1) }

        var floors = [Float](repeating: parameters.minimumFloorDBFS, count: frameDB.count)
        for block in 0..<blockCount {
            if block > 0 {
                add(block + radius, 1)
                add(block - radius - 1, -1)
            }
            var floor = parameters.minimumFloorDBFS
            if windowTotal > 0 {
                let target = max(1, Int((Double(windowTotal) * parameters.floorPercentile).rounded(.up)))
                var seen = 0
                for b in 0..<binCount {
                    seen += Int(window[b])
                    if seen >= target {
                        floor = lowest + (Float(b) + 0.5) * binWidth
                        break
                    }
                }
            }
            let start = block * framesPerBlock
            let end = min(frameDB.count, start + framesPerBlock)
            for index in start..<end { floors[index] = floor }
        }
        return floors
    }
}

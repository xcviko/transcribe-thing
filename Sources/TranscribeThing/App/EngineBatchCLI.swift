import CoreML
import Darwin
import Foundation

/// Hidden comparison of the local models (not in the usage text), free, with no key:
///
///     transcribe-thing --batch <list.txt> --engine parakeet|gigaam-v3|gigaam-v3-e2e|gigaam-multilingual
///            [--gigaam-models <dir>] [--compute all|ane|gpu|cpu] [--out <file.jsonl>]
///
/// Loads one model once, then transcribes every audio file listed in `<list.txt>` (one path per line, anything
/// AVFoundation reads) as the app reads a recording. Prints, and writes to `--out` as JSON lines, each file's
/// length, time and text, then the load time and the process's memory (phys_footprint, what Activity Monitor shows
/// as Memory): before the load, after it, and the peak. Parakeet loads from the app's model folder, read only;
/// GigaAM from `<dir>/<model>` (`scripts/convert-gigaam.py`, compiled to .mlmodelc). Writes nothing but `--out`.
enum EngineBatchCLI {
    static let flag = "--batch"

    struct Line: Encodable {
        let file: String
        let audio: Double
        let time: Double
        let text: String
    }

    @MainActor
    static func run(_ arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        func path(_ text: String) -> URL { URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }
        guard let list = value(flag), let engineName = value("--engine"),
              let listText = try? String(contentsOf: path(list), encoding: .utf8)
        else {
            print("usage: transcribe-thing --batch <list.txt> --engine parakeet|gigaam-v3|gigaam-v3-e2e|gigaam-multilingual [--gigaam-models <dir>] [--compute all|ane|gpu|cpu] [--out <file.jsonl>]")
            return 2
        }
        let files = listText.split(whereSeparator: \.isNewline).map { path(String($0)) }
        let units: MLComputeUnits = switch value("--compute") {
        case "ane": .cpuAndNeuralEngine
        case "gpu": .cpuAndGPU
        case "cpu": .cpuOnly
        default: .all
        }
        let out = value("--out").map(path)
        if let out { FileManager.default.createFile(atPath: out.path, contents: nil) }
        let writer = out.flatMap { try? FileHandle(forWritingTo: $0) }

        let transcribe: ([Float]) async throws -> String
        let before = Memory.footprint()
        let loadStart = ContinuousClock.now
        do {
            switch engineName {
            case "parakeet":
                ParakeetEngine.quietLibraryLogging()
                let engine = ParakeetEngine(modelsRoot: AppPaths.live().models)
                try await engine.load()
                transcribe = { try await engine.transcribe($0) }
            case "gigaam-v3", "gigaam-v3-e2e", "gigaam-multilingual":
                let variant: GigaAMEngine.Variant = switch engineName {
                case "gigaam-v3": .v3
                case "gigaam-v3-e2e": .v3e2e
                default: .multilingual
                }
                guard let root = value("--gigaam-models") else {
                    print("ERROR: --gigaam-models <dir> is required for \(engineName)")
                    return 2
                }
                let engine = GigaAMEngine(variant: variant, directory: path(root).appendingPathComponent(variant.rawValue),
                                          computeUnits: units)
                try await engine.load()
                transcribe = { try await engine.transcribe($0) }
            default:
                print("ERROR: unknown engine \(engineName)")
                return 2
            }
        } catch {
            print("ERROR: load: \(error.localizedDescription)")
            return 1
        }
        let load = loadStart.duration(to: .now)
        let loaded = Memory.footprint()
        print("ENGINE: \(engineName) · compute \(value("--compute") ?? "all")")
        print("LOAD: \(seconds(load)) s")

        var totalAudio = 0.0
        var totalTime = 0.0
        for file in files {
            do {
                let samples = try AudioFileLoader.load16kMono(file)
                let audio = Double(samples.count) / Recording.sampleRate
                let start = ContinuousClock.now
                let text = try await transcribe(samples)
                let time = seconds(start.duration(to: .now))
                totalAudio += audio
                totalTime += time
                let line = Line(file: file.lastPathComponent, audio: audio, time: time, text: text)
                print(String(format: "FILE: %@ · %.1f s audio · %.3f s · %@", file.lastPathComponent, audio, time, text))
                if let writer, var data = try? JSONEncoder().encode(line) {
                    data.append(0x0A)
                    writer.write(data)
                }
            } catch {
                print("ERROR: \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try? writer?.close()
        let peak = Memory.peakFootprint()
        print(String(format: "TOTAL: %d files · %.1f s audio · %.2f s · %.0fx real time",
                     files.count, totalAudio, totalTime, totalTime > 0 ? totalAudio / totalTime : 0))
        print("MEMORY: before load \(mb(before)) · after load \(mb(loaded)) · peak \(mb(peak))")
        return 0
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func mb(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

    enum Memory {
        private static func info() -> task_vm_info_data_t? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info : nil
        }

        static func footprint() -> UInt64 { info()?.phys_footprint ?? 0 }
        static func peakFootprint() -> UInt64 { UInt64(info()?.ledger_phys_footprint_peak ?? 0) }
    }
}

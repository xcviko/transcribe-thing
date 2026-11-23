import Foundation

/// Headless look at the recorded calls, dispatched by TranscribeThingMain before the app starts:
///
///     transcribe-thing --calls-status [--transcript]
///
/// Prints each call in calls.json (`CallStore`), newest first: when, which app and service, how long each track is,
/// its status, mutes, problems, cost, its last error and the answers Gemini gave (`Calls/<id>/answers`: file names and
/// sizes); with `--transcript`, its transcript too. Then any call still in
/// `Calls in Progress` (`CallJournal`): one being recorded now, or one the app left when it quit. Only reads: nothing
/// is written, moved or deleted, and nothing goes over the network.
enum CallsCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--calls-status")
    }

    static func run(_ arguments: [String]) -> Never {
        let paths = AppPaths.live()
        let showTranscript = arguments.contains("--transcript")
        var calls: [CallRecord] = []
        if let data = try? Data(contentsOf: paths.callsFile) {
            do {
                calls = try CallStore.readRecords(from: data).sorted { $0.startedAt > $1.startedAt }
            } catch {
                print("calls.json can't be read: \(error.localizedDescription)")
            }
        }
        print("\(calls.count) call\(calls.count == 1 ? "" : "s") in \(paths.callsFile.path)")
        for call in calls {
            print("")
            for line in describe(call, folder: paths.calls.appendingPathComponent(call.id.uuidString),
                                 transcript: showTranscript) {
                print(line)
            }
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: paths.callJournals.path)) ?? []).sorted()
        if !files.isEmpty {
            print("\nIn progress (\(paths.callJournals.path)):")
            for name in files {
                let url = paths.callJournals.appendingPathComponent(name)
                if name.hasSuffix(".wav") {
                    let seconds = Double(RecordingJournal.sampleCount(of: url) ?? 0) / Recording.sampleRate
                    print("  \(name)  \(clock(seconds))")
                } else if name.hasSuffix(".json"), let data = try? Data(contentsOf: url),
                          let info = try? JSONDecoder().decode(CallJournal.Info.self, from: data) {
                    print("  \(name)  \(info.appName)\(info.service.map { " · \($0.name)" } ?? "") · \(info.consent.rawValue)")
                } else {
                    print("  \(name)")
                }
            }
        }
        exit(0)
    }

    static func describe(_ call: CallRecord, folder: URL, transcript: Bool) -> [String] {
        let date = call.startedAt.formatted(date: .abbreviated, time: .shortened)
        var lines = ["\(date)  \(call.title)\(call.service != nil && call.appName != call.title ? " in \(call.appName)" : "")"
                     + "\(call.manual ? " (manual)" : "")  \(clock(call.duration))  \(call.status.rawValue)"]
        lines.append("  id \(call.id.uuidString)")
        if let page = call.pageTitle { lines.append("  page \"\(CallLabels.safe(page, limit: 60))\"") }
        if let title = call.summary?.title { lines.append("  title \"\(CallLabels.safe(title, limit: 60))\"") }
        for (name, file, seconds, problem) in [("mic", call.micFile, call.micSeconds, call.micProblem),
                                               ("remote", call.remoteFile, call.remoteSeconds, call.remoteProblem)] {
            let exists = file.map { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let state = file == nil ? "no audio" : exists == true ? "\(clock(seconds))" : "\(clock(seconds)), file missing"
            lines.append("  \(name): \(state)\(problem.map { " · \($0)" } ?? "")")
        }
        let mutes = call.muteIntervals.map { "\(clock($0.start))-\(clock($0.end))" }.joined(separator: ", ")
        lines.append("  mute: \(call.muteKnown ? (mutes.isEmpty ? "never muted" : mutes) : "not known")")
        if !call.otherBrowserAudio.isEmpty {
            lines.append("  other tabs played sound: "
                         + call.otherBrowserAudio.map { "\(clock($0.start))-\(clock($0.end))" }.joined(separator: ", "))
        }
        if let error = call.error { lines.append("  last error: \(error)") }
        if let cut = call.cutOffAt { lines.append("  cut off at \(clock(cut))") }
        if !call.missedSpeech.isEmpty {
            lines.append("  may miss speech: "
                         + call.missedSpeech.map { "\(clock($0.start))-\(clock($0.end))" }.joined(separator: ", "))
        }
        if let cost = call.costUSD { lines.append(String(format: "  cost: $%.4f", cost)) }
        let answers = folder.appendingPathComponent("answers", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: answers.path)) ?? []).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        if !names.isEmpty {
            lines.append("  answers (\(answers.path)):")
            for name in names {
                let attributes = try? FileManager.default.attributesOfItem(atPath: answers.appendingPathComponent(name).path)
                let size = (attributes?[.size] as? Int).map { "\($0) bytes" } ?? "?"
                lines.append("    \(name)  \(size)")
            }
        }
        if let segments = call.transcript?.segments {
            let speakers = call.transcript?.speakers.map(call.name(of:)).joined(separator: ", ") ?? ""
            lines.append("  transcript: \(segments.count) phrases · \(speakers)")
            if transcript {
                for segment in segments {
                    let muted = segment.duringMute ? " (muted)" : ""
                    lines.append("    [\(clock(segment.start))] \(call.name(of: segment.speaker))\(muted): \(segment.text)")
                }
            }
        }
        return lines
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        CallPrompts.clock(seconds)
    }
}

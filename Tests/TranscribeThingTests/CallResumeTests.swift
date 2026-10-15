import Foundation
import os
import Testing
@testable import TranscribeThing

// An answer that ends as if done long before its chunk's audio does, or leaves minutes out in the middle: the stretch
// that still has speech is asked for again (`CallTranscriber.resume`), its phrases merged by time, a call of one chunk
// summed up whole after it, every request's cost counted. Gemini is a fake.

private let rate = Recording.sampleRate

/// `seconds` of something SpeechAnalyzer hears as speech: a voice with harmonics in syllables, over faint noise.
private func speechLike(seconds: Double, pitch: Double = 140) -> [Float] {
    var seed: UInt32 = 12_345
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        let inPause = t.truncatingRemainder(dividingBy: 1) >= 0.75
        let syllable = inPause ? 0 : pow(sin(.pi * (t * 4).truncatingRemainder(dividingBy: 1)), 2)
        var voice = 0.0
        for harmonic in 1...12 { voice += sin(2 * .pi * pitch * Double(harmonic) * t) / Double(harmonic) }
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = Double(seed >> 8) / Double(1 << 24) - 0.5
        return Float(0.08 * syllable * voice + 0.002 * noise)
    }
}

private let tenSeconds = speechLike(seconds: 10)

/// `seconds` of speech: the same ten seconds over and over, so minutes of it are cheap to make.
private func speech(_ seconds: Double) -> [Float] {
    let count = Int(seconds * rate)
    var out: [Float] = []
    out.reserveCapacity(count)
    while out.count < count { out += tenSeconds.prefix(count - out.count) }
    return out
}

/// `seconds` of a quiet room: faint noise, no voice.
private func quiet(_ seconds: Double) -> [Float] {
    var seed: UInt32 = 4_242
    return (0..<Int(seconds * rate)).map { _ in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return 0.002 * (Float(seed >> 8) / Float(1 << 24) - 0.5)
    }
}

/// What each request was sent, and Gemini's made-up answers by request (from 1); each costs 0.01.
private final class Gemini: Sendable {
    struct Request: Sendable {
        var prompt: String
        var seconds: TimeInterval
        var sample: Data?
    }

    let requests = OSAllocatedUnfairLock(initialState: [Request]())
    let answer: @Sendable (_ index: Int) throws -> String

    init(_ answer: @escaping @Sendable (_ index: Int) throws -> String) {
        self.answer = answer
    }

    var count: Int { requests.withLock { $0.count } }

    func send(_ audio: Data, _ prompt: String, _ seconds: TimeInterval, _ sample: Data?) async throws -> CloudResult {
        let index = requests.withLock {
            $0.append(Request(prompt: prompt, seconds: seconds, sample: sample))
            return $0.count
        }
        #expect(!audio.isEmpty)
        var result = CloudResult(text: try answer(index))
        result.costUSD = 0.01
        result.finishReason = "stop"
        return result
    }
}

/// The summary's text-only requests; each costs 0.002.
private final class Summaries: Sendable {
    let requests = OSAllocatedUnfairLock(initialState: [(text: String, prompt: String)]())
    let answer: String

    init(_ answer: String = "<summary>\nThe whole call.\n</summary>") {
        self.answer = answer
    }

    var count: Int { requests.withLock { $0.count } }

    func send(_ text: String, _ prompt: String) async throws -> CloudResult {
        requests.withLock { $0.append((text, prompt)) }
        var result = CloudResult(text: answer)
        result.costUSD = 0.002
        return result
    }
}

private func plan(_ audio: [Float], file: String? = nil, answers: URL? = nil,
                  callID: UUID? = nil) -> CallTranscriber.Plan {
    CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: nil, remoteSamples: audio.count,
                         micSamples: 0, mutes: [], userName: "Sam", service: file == nil ? "Discord" : nil,
                         answers: answers, callID: callID, file: file)
}

private func answersFolder() -> URL {
    AppPaths.temporary().root.appendingPathComponent("answers", isDirectory: true)
}

@Suite(.serialized) struct CallResumeTests {
    private static func log() -> (DiagnosticLog, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("calls-log-\(UUID().uuidString)",
                                                                                   isDirectory: true)
        let log = DiagnosticLog()
        log.start(directory: folder)
        return (log, folder)
    }

    /// The second chunk's answer stops at 0:50 of 3:20 of speech: the rest goes in one more request from 0:45, with the
    /// speakers named so far; its times land on the call's clock, and what it writes again of what was already there
    /// (the end of the last phrase, a phrase said again with its time drifted) is left out.
    @Test func anAnswerThatStopsEarlyIsAskedForTheRest() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let audio = speech(400)
        let answers = answersFolder()
        let id = UUID()
        let gemini = Gemini { index in
            switch index {
            case 1: "[00:01-00:05] Аня: Привет, слышно?\n[00:06-00:10] Sam: Да, отлично.\n[01:30-01:40] Аня: Едем дальше."
                + "\n[03:10-03:19] Sam: Хорошо."
            case 2: "[00:01-00:05] Аня: Тогда релиз переносим на пятницу.\n"
                + "[00:40-00:50] Sam: Я тоже так думаю, давай обсудим."
            default: "[00:00-00:05] Sam: давай обсудим.\n[00:06-00:12] Олег: Я подключился, слышно меня?\n"
                + "[00:20-00:26] Аня: Тогда релиз переносим на пятницу!\n[02:25-02:33] Аня: Всё, до завтра."
            }
        }
        let summaries = Summaries()
        let outcome = try await CallTranscriber.run(
            plan(audio, answers: answers, callID: id), maxChunkSeconds: 200,
            send: { try await gemini.send($0, $1, $2, $3) }, summarize: { try await summaries.send($0, $1) },
            read: { _, range in Array(audio[range]) }, log: log)

        let requests = gemini.requests.withLock { $0 }
        #expect(requests.count == 3, "a request a chunk, and one for the rest of the second")
        #expect(outcome.requests == 2 && outcome.resumed == 1)
        let rest = requests[2]
        #expect(abs(rest.seconds - 155) < 0.01, "from 5 s before the answer stopped to the chunk's end")
        #expect(rest.prompt.hasPrefix("This audio is a recording of a call on Discord"))
        #expect(rest.prompt.contains("Earlier in this call these speakers were heard: Аня, Sam (who recorded the call). "
                                     + "Use the same names"))
        #expect(rest.prompt.contains(CallPrompts.format) && !rest.prompt.contains("<summary>"))

        let second = outcome.transcript.segments.filter { $0.start >= 200 }
        #expect(second.map(\.text) == ["Тогда релиз переносим на пятницу.", "Я тоже так думаю, давай обсудим.",
                                       "Я подключился, слышно меня?", "Всё, до завтра."])
        #expect(second.map(\.start) == [201, 240, 251, 390] && second.map(\.end) == [205, 250, 257, 398])
        #expect(second.map(\.side) == [.remote, .local, .remote, .remote])
        #expect(outcome.transcript.segments.count == 8, "the first chunk's four, untouched")

        // Three requests and the summary, which sums up the whole transcript.
        #expect(abs((outcome.costUSD ?? 0) - 0.032) < 1e-9)
        let summed = try #require(summaries.requests.withLock { $0.first })
        #expect(summed.text.contains("Олег: Я подключился, слышно меня?"))
        #expect(FileManager.default.fileExists(atPath: answers.appendingPathComponent("2-mix-rest-1.txt").path))
        #expect(!FileManager.default.fileExists(atPath: answers.appendingPathComponent("1-mix-rest-1.txt").path))
        #expect(try String(contentsOf: answers.appendingPathComponent("2-mix-rest-1.txt"), encoding: .utf8)
                    .hasPrefix("[00:00-00:05] Sam: давай обсудим."))

        log.flush()
        let text = log.retainedText()
        #expect(text.contains("[calls] transcription.resumed call=\(CallTranscriber.shortID(id)) chunk=2 kind=end "
                              + "from=245 to=400 voiced="))
        let counts = #"transcription\.resumed .* audio=155 chars=\d+ format=lines phrases=4 kept=2 finish=stop cost=0\.01"#
        #expect(text.range(of: counts, options: .regularExpression) != nil)
        #expect(!text.contains("Олег") && !text.contains("релиз"), "never what was said")
    }

    /// A call of one chunk is summed up in its answer: when more requests added to its transcript, that summary was of
    /// what it had, so the whole transcript is summed up in a request of its own, and it all counts in the cost. A
    /// request that found nothing more leaves the answer's summary.
    @Test func aCallOfOneChunkIsSummedUpWholeAfterItsRest() async throws {
        let audio = speech(200)
        let main = "[00:01-00:05] Аня: Привет.\n[00:40-00:50] Sam: Давай обсудим планы.\n"
            + "<summary>\nOnly the start.\n</summary>"
        let gemini = Gemini { $0 == 1 ? main : "[00:10-00:20] Олег: Я тут, всё слышу.\n[02:30-02:35] Аня: До встречи." }
        let summaries = Summaries()
        let outcome = try await CallTranscriber.run(
            plan(audio), send: { try await gemini.send($0, $1, $2, $3) },
            summarize: { try await summaries.send($0, $1) }, read: { _, range in Array(audio[range]) })
        let prompts = gemini.requests.withLock { $0.map(\.prompt) }
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("Answer with the transcript first, nothing before it:"))
        #expect(prompts[1].contains("Answer with only the transcript, nothing before or after it:"))
        #expect(!prompts[1].contains("<summary>"))
        #expect(outcome.transcript.segments.map(\.text) == ["Привет.", "Давай обсудим планы.", "Я тут, всё слышу.",
                                                            "До встречи."])
        #expect(outcome.transcript.segments.map(\.start) == [1, 40, 55, 195])
        #expect(summaries.count == 1 && outcome.summary?.summary == "The whole call.")
        #expect(summaries.requests.withLock { $0.first?.text.contains("Олег: Я тут, всё слышу.") } == true)
        #expect(abs((outcome.costUSD ?? 0) - 0.022) < 1e-9, "both requests and the summary")

        // Nothing more there: the answer's own summary stands, no summary request.
        let nothing = Gemini { $0 == 1 ? main : "NO SPEECH" }
        let none = Summaries()
        let kept = try await CallTranscriber.run(
            plan(audio), send: { try await nothing.send($0, $1, $2, $3) },
            summarize: { try await none.send($0, $1) }, read: { _, range in Array(audio[range]) })
        #expect(nothing.count == 2 && kept.resumed == 1)
        #expect(none.count == 0 && kept.summary?.summary == "Only the start.")
        #expect(abs((kept.costUSD ?? 0) - 0.02) < 1e-9)
    }

    /// No more requests when what's after the last phrase is quiet, too short, or has too little speech in it; or
    /// when the answer had no phrase at all.
    @Test func theRestIsOnlyAskedForWhenItHasSpeech() async throws {
        let cases: [(name: String, audio: [Float], answer: String)] = [
            ("quiet after", speech(60) + quiet(140), "[00:01-00:05] Аня: Привет.\n[00:50-00:58] Sam: Пока."),
            ("under a minute left", speech(200),
             "[00:01-00:05] Аня: Привет.\n[01:10-01:20] Аня: Ну что?\n[02:20-02:30] Sam: Пока."),
            ("ten seconds of speech in the rest", speech(60) + quiet(60) + speech(10) + quiet(70),
             "[00:01-00:05] Аня: Привет.\n[00:50-01:00] Sam: Пока."),
            ("no phrase", speech(200), "NO SPEECH"),
        ]
        for item in cases {
            let audio = item.audio
            let gemini = Gemini { _ in item.answer }
            let outcome = try await CallTranscriber.run(plan(audio), send: { try await gemini.send($0, $1, $2, $3) },
                                                        read: { _, range in Array(audio[range]) })
            #expect(gemini.count == 1 && outcome.resumed == 0, "\(item.name)")
            #expect(outcome.cutOffAt == nil && outcome.missedSpeech.isEmpty, "\(item.name)")
        }
    }

    /// An answer cut off by its token limit, even with under a minute left, is asked for the rest from the start of
    /// its last phrase, which may stop mid-word: what comes back from there takes its place, and the call isn't said
    /// to be cut off. Its rest is asked for with the summary left to its own request.
    @Test func aCutOffAnswerIsAskedForItsRest() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let audio = speech(200)
        let gemini = Gemini { index in
            if index == 1 {
                throw AppError.openRouterTruncated("[00:01-00:05] Аня: Привет.\n[01:10-01:20] Аня: Ну что?\n"
                                                   + "[02:20-02:30] Sam: Ну и во")
            }
            // From 2:15: the phrase cut off, whole, then the rest.
            return "[00:00-00:04] Аня: что?\n[00:05-00:15] Sam: Ну и вот, всё по плану.\n[00:20-00:40] Аня: Отлично."
        }
        let summaries = Summaries()
        let outcome = try await CallTranscriber.run(
            plan(audio, callID: UUID()), send: { try await gemini.send($0, $1, $2, $3) },
            summarize: { try await summaries.send($0, $1) }, read: { _, range in Array(audio[range]) }, log: log)
        let requests = gemini.requests.withLock { $0 }
        #expect(requests.count == 2 && outcome.resumed == 1)
        #expect(abs(requests[1].seconds - 65) < 0.01, "from 5 s before the cut-off phrase to the end")
        #expect(!requests[1].prompt.contains("<summary>"))
        #expect(outcome.transcript.segments.map(\.text) == ["Привет.", "Ну что?", "Ну и вот, всё по плану.", "Отлично."])
        #expect(outcome.transcript.segments.map(\.start) == [1, 70, 140, 155])
        #expect(outcome.cutOffAt == nil && outcome.missedSpeech.isEmpty)
        #expect(summaries.count == 1, "the cut-off answer's summary blocks never came")
        log.flush()
        #expect(log.retainedText().contains("kind=cutOff from=135 to=200"))
    }

    /// When the request for a cut-off answer's rest fails too, the call says where the transcript may stop, not that
    /// it may miss speech; an answer for the rest that is cut off again goes on from its own last phrase.
    @Test func aCutOffAnswerWhoseRestFailsSaysWhereItStops() async throws {
        let audio = speech(200)
        let failing = Gemini { index in
            if index == 1 { throw AppError.openRouterTruncated("[00:01-00:05] Аня: Привет.\n[00:50-01:00] Sam: Ну и во") }
            throw AppError.openRouterMissingKey
        }
        let failed = try await CallTranscriber.run(plan(audio), send: { try await failing.send($0, $1, $2, $3) },
                                                   read: { _, range in Array(audio[range]) })
        #expect(failing.count == 2)
        #expect(failed.transcript.segments.map(\.text) == ["Привет.", "Ну и во"], "the cut-off phrase stands")
        #expect(failed.cutOffAt == 60 && failed.missedSpeech.isEmpty)

        let again = Gemini { index in
            switch index {
            case 1: throw AppError.openRouterTruncated("[00:01-00:05] Аня: Привет.\n[00:50-01:00] Sam: Ну и во")
            // From 0:45: the cut-off phrase whole, and another cut off.
            case 2: throw AppError.openRouterTruncated("[00:05-00:15] Sam: Ну и вот.\n[01:00-01:10] Аня: Дава")
            // From 1:40.
            default: return "[00:00-00:10] Аня: Давай дальше.\n[01:30-01:40] Sam: Хорошо."
            }
        }
        let outcome = try await CallTranscriber.run(plan(audio), send: { try await again.send($0, $1, $2, $3) },
                                                    read: { _, range in Array(audio[range]) })
        let requests = again.requests.withLock { $0 }
        #expect(requests.count == 3 && outcome.resumed == 2)
        #expect(requests.dropFirst().map { ($0.seconds * 100).rounded() / 100 } == [155, 100])
        #expect(outcome.transcript.segments.map(\.text) == ["Привет.", "Ну и вот.", "Давай дальше.", "Хорошо."])
        #expect(outcome.transcript.segments.map(\.start) == [1, 50, 100, 190])
        #expect(outcome.cutOffAt == nil)

        // Cut off every time: as far as the rounds go, then the call says where it stops.
        let always = Gemini { index in
            let at = 10 * index
            throw AppError.openRouterTruncated("[00:00-00:02] Аня: Ещё.\n[00:\(at)-00:\(at + 5)] Sam: Обры")
        }
        let cut = try await CallTranscriber.run(plan(audio), send: { try await always.send($0, $1, $2, $3) },
                                                read: { _, range in Array(audio[range]) })
        #expect(always.count == 1 + CallTranscriber.ResumeRules.default.rounds)
        #expect(cut.cutOffAt != nil && cut.missedSpeech.isEmpty)
    }

    /// A request for what an answer left out that fails leaves the call saying where it may miss speech: that stretch
    /// and any after it in the chunk; Transcribe Again can try again.
    @MainActor
    @Test func aFailedRequestForTheRestSaysWhatMayBeMissing() async throws {
        let audio = speech(200)
        let gemini = Gemini { index in
            guard index == 1 else { throw AppError.openRouterMissingKey }
            return "[00:01-00:05] Аня: Привет.\n[00:40-00:50] Sam: Давай обсудим."
        }
        let outcome = try await CallTranscriber.run(plan(audio), send: { try await gemini.send($0, $1, $2, $3) },
                                                    read: { _, range in Array(audio[range]) })
        #expect(outcome.missedSpeech == [CallInterval(start: 50, end: 200)] && outcome.cutOffAt == nil)

        // A gap in the middle and one at the end of the first of two chunks: the gap's request fails, so both are
        // noted.
        let long = speech(400)
        let gaps = Gemini { index in
            switch index {
            case 1: "[00:00-00:10] Аня: Начали.\n[02:15-02:20] Sam: Ага."
            case 2: throw AppError.openRouterMissingKey
            default: "[00:00-03:20] Аня: Второй кусок."
            }
        }
        let both = try await CallTranscriber.run(plan(long), maxChunkSeconds: 200,
                                                 send: { try await gaps.send($0, $1, $2, $3) },
                                                 read: { _, range in Array(long[range]) })
        #expect(gaps.count == 3)
        #expect(both.missedSpeech == [CallInterval(start: 10, end: 135), CallInterval(start: 140, end: 200)])

        // On the call's page.
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Discord", status: .done)
        call.remoteSeconds = 200
        call.missedSpeech = [CallInterval(start: 50, end: 200)]
        #expect(CallFormat.shortNotes(call).last?.label == "May miss speech after 00:50")
        #expect(CallFormat.notes(call).last == "The transcript may miss speech after 00:50: Gemini left it out, and "
                + "asking again didn’t work. Transcribe Again can try again.")
        call.remoteSeconds = 400
        call.missedSpeech = [CallInterval(start: 10, end: 170), CallInterval(start: 250, end: 400)]
        #expect(CallFormat.shortNotes(call).last?.label == "May miss speech in 2 places")
        #expect(CallFormat.notes(call).last == "The transcript may miss speech between 00:10 and 02:50, and after 04:10: "
                + "Gemini left it out, and asking again didn’t work. Transcribe Again can try again.")
        // Kept with the call.
        let data = try JSONEncoder().encode(call)
        #expect(try JSONDecoder().decode(CallRecord.self, from: data).missedSpeech == call.missedSpeech)
    }

    /// Minutes in the middle with no phrase and speech in them: that stretch is asked for, a few seconds wider, with the
    /// same sample of the person's voice; its phrases go in between, by time, and what it writes again of the phrases
    /// on either side is left out.
    @Test func aStretchLeftOutMidChunkIsFilledIn() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        // The person alone on their mic at first (so there's a sample of their voice), then the other side talking.
        var alone = quiet(300)
        for start in [0, 12] {
            for (index, value) in speechLike(seconds: 7, pitch: 220).enumerated() {
                alone[Int(Double(start) * rate) + index] = value
            }
        }
        let mic = alone
        let remote = [Float](repeating: 0, count: Int(21 * rate)) + speech(279)
        let answers = answersFolder()
        let plan = CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: URL(fileURLWithPath: "/mic.m4a"),
                                        remoteSamples: remote.count, micSamples: mic.count, mutes: [],
                                        userName: "Sam", service: "Zoom", answers: answers, callID: UUID())
        let gemini = Gemini { index in
            index == 1
                ? "[00:01-00:06] Sam: Привет, это я.\n[00:13-00:18] Sam: Начинаем.\n[00:22-00:30] Аня: Хорошо, давай.\n"
                    + "[00:31-01:40] Аня: Про релиз.\n[04:10-04:20] Аня: Итак, по срокам.\n[04:21-04:59] Sam: Понял."
                : "[00:00-00:05] Аня: релиз.\n[00:10-00:20] Олег: Добрый день, я по поводу сроков.\n"
                    + "[02:20-02:28] Олег: Вот и всё, что хотел сказать.\n[02:35-02:40] Аня: Итак, по срокам."
        }
        let outcome = try await CallTranscriber.run(
            plan, send: { try await gemini.send($0, $1, $2, $3) },
            read: { url, range in Array((url.lastPathComponent == "mic.m4a" ? mic : remote)[range]) }, log: log)
        let requests = gemini.requests.withLock { $0 }
        #expect(requests.count == 2 && outcome.resumed == 1)
        #expect(abs(requests[1].seconds - 160) < 0.01, "1:35 to 4:15: the stretch and 5 s either side")
        let sample = try #require(requests[0].sample)
        #expect(requests[1].sample == sample, "the same sample of their voice")
        #expect(requests[1].prompt.hasPrefix(CallPrompts.voiceSampleParagraph(me: "Sam")))
        #expect(requests[1].prompt.contains("Earlier in this call these speakers were heard: Sam (who recorded the "
                                            + "call), Аня."))
        #expect(outcome.transcript.segments.map(\.text) == [
            "Привет, это я.", "Начинаем.", "Хорошо, давай.", "Про релиз.", "Добрый день, я по поводу сроков.",
            "Вот и всё, что хотел сказать.", "Итак, по срокам.", "Понял.",
        ])
        #expect(outcome.transcript.segments.map(\.start) == [1, 13, 22, 31, 105, 235, 250, 261])
        #expect(FileManager.default.fileExists(atPath: answers.appendingPathComponent("1-mix-rest-1.txt").path))
        log.flush()
        #expect(log.retainedText().contains("chunk=1 kind=gap from=95 to=255 voiced="))
    }

    /// An answer for the rest that stops early again is followed by another, from where it stopped, while each brings
    /// a phrase: three at most for a stretch, and never more than the chunk's limit. One that brings nothing stops it.
    @Test func roundsGoOnWhileEachBringsPhrasesUpToALimit() async throws {
        let audio = speech(400)
        let answers = answersFolder()
        func gemini(_ rest: @escaping @Sendable (Int) -> String) -> Gemini {
            Gemini { $0 == 1 ? "[00:00-00:10] Аня: Начали." : rest($0) }
        }
        let progressing: @Sendable (Int) -> String = { "[00:05-00:30] Аня: Часть \($0).\n[00:30-01:00] Sam: Ответ \($0)." }

        let three = gemini(progressing)
        let outcome = try await CallTranscriber.run(
            plan(audio, answers: answers), send: { try await three.send($0, $1, $2, $3) },
            read: { _, range in Array(audio[range]) })
        let requests = three.requests.withLock { $0 }
        #expect(requests.count == 4 && outcome.resumed == 3)
        // Each from 5 s before where the one before stopped: 0:10, 1:05, 2:00.
        #expect(requests.dropFirst().map { ($0.seconds * 100).rounded() / 100 } == [395, 340, 285])
        #expect(requests[3].prompt.contains("Earlier in this call these speakers were heard: Аня, Sam (who recorded the "
                                            + "call)."))
        #expect(outcome.transcript.segments.last?.end == 175)
        #expect(outcome.transcript.segments.count == 7)
        for n in 1...3 {
            #expect(FileManager.default.fileExists(atPath: answers.appendingPathComponent("1-mix-rest-\(n).txt").path))
        }

        // The chunk's limit.
        var rules = CallTranscriber.ResumeRules()
        rules.maxRequests = 2
        let two = gemini(progressing)
        let limited = try await CallTranscriber.run(plan(audio), resume: rules, send: { try await two.send($0, $1, $2, $3) },
                                                    read: { _, range in Array(audio[range]) })
        #expect(two.count == 3 && limited.resumed == 2)

        // Nothing new: no more.
        let nothing = gemini { _ in "NO SPEECH" }
        let stopped = try await CallTranscriber.run(plan(audio), send: { try await nothing.send($0, $1, $2, $3) },
                                                    read: { _, range in Array(audio[range]) })
        #expect(nothing.count == 2 && stopped.resumed == 1 && stopped.transcript.segments.count == 1)
    }

    /// A call made from a file is asked for its rest with the file's prompt, the speakers it named so far, no sample;
    /// here its answers come with every phrase on one line, and are read phrase by phrase.
    @Test func aFilesCallIsAskedForItsRestWithTheFilesPrompt() async throws {
        let audio = speech(200)
        let gemini = Gemini { index in
            index == 1
                ? "[00:00-00:05] Speaker 1: Добрый день, начнём интервью. [00:06-00:20] Speaker 2: Да, конечно, я готов. "
                    + "[00:21-00:50] Speaker 1: Расскажите о себе."
                : "[00:00-00:05] Speaker 1: о себе. [00:06-00:30] Speaker 2: Я работаю инженером десять лет. "
                    + "[02:00-02:25] Speaker 1: Спасибо, на этом всё."
        }
        let outcome = try await CallTranscriber.run(plan(audio, file: "Interview.m4a"),
                                                    send: { try await gemini.send($0, $1, $2, $3) },
                                                    read: { _, range in Array(audio[range]) })
        let requests = gemini.requests.withLock { $0 }
        #expect(requests.count == 2 && outcome.resumed == 1)
        #expect(requests.allSatisfy { $0.sample == nil })
        #expect(requests[0].prompt.contains("<summary>"), "a file of one chunk is summed up in its answer")
        let rest = requests[1].prompt
        #expect(rest.hasPrefix("This audio is a recording from the file \"Interview.m4a\""))
        #expect(rest.contains("Earlier in this recording these speakers were heard: Speaker 1, Speaker 2."))
        #expect(!rest.contains("<summary>") && !rest.contains("Participant"))
        #expect(outcome.transcript.segments.map(\.text) == [
            "Добрый день, начнём интервью.", "Да, конечно, я готов.", "Расскажите о себе.",
            "Я работаю инженером десять лет.", "Спасибо, на этом всё.",
        ])
        #expect(outcome.transcript.segments.map(\.start) == [0, 6, 21, 51, 165])
        #expect(outcome.transcript.segments.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 2",
                                                               "Speaker 1"])
    }

    /// A request for the rest that fails leaves the transcript as the chunk's answer had it, and is logged.
    @Test func aFailedRequestForTheRestKeepsTheTranscript() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let audio = speech(200)
        let gemini = Gemini { index in
            guard index == 1 else { throw AppError.openRouterMissingKey }
            return "[00:01-00:05] Аня: Привет.\n[00:40-00:50] Sam: Давай обсудим."
        }
        let outcome = try await CallTranscriber.run(
            plan(audio, callID: UUID()), send: { try await gemini.send($0, $1, $2, $3) },
            read: { _, range in Array(audio[range]) }, log: log)
        #expect(gemini.count == 2 && outcome.resumed == 1)
        #expect(outcome.transcript.segments.map(\.text) == ["Привет.", "Давай обсудим."])
        #expect(abs((outcome.costUSD ?? 0) - 0.01) < 1e-9)
        log.flush()
        #expect(log.retainedText().range(of: #"transcription\.resumed .* kind=end from=45 to=200 voiced=[\d.]+ error=\w+"#,
                                         options: .regularExpression) != nil)
    }
}

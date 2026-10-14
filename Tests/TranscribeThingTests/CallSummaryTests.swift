import Foundation
import os
import Testing
@testable import TranscribeThing

// A call's summary: its tagged blocks read out of an answer (`CallSummaryParser`), the transcript parser leaving them
// alone, the summary from the transcript's own answer for a call of one chunk and from one more text-only request for a
// longer one, Summarize on an older call, ticks kept and saved, and how the page and the list show it. Gemini is a fake.

private let rate = Recording.sampleRate

/// `seconds` of something SpeechAnalyzer hears as speech.
private func speech(seconds: Double) -> [Float] {
    var seed: UInt32 = 54_321
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        let inPause = t.truncatingRemainder(dividingBy: 1) >= 0.75
        let syllable = inPause ? 0 : pow(sin(.pi * (t * 4).truncatingRemainder(dividingBy: 1)), 2)
        var voice = 0.0
        for harmonic in 1...12 { voice += sin(2 * .pi * 140 * Double(harmonic) * t) / Double(harmonic) }
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = Double(seed >> 8) / Double(1 << 24) - 0.5
        return Float(0.08 * syllable * voice + 0.002 * noise)
    }
}

private let blocks = """
    <summary>
    Обсудили релиз. Решили выпускать в пятницу.
    </summary>
    <key_points>
    - Импорт работает
    • Длинные файлы грузятся долго
    1. Нужно резать на части
    </key_points>
    <decided>
    - Релиз в пятницу
    </decided>
    <tasks>
    - Sam | Разрезать файлы на части | до четверга
    - Аня | Проверить длинные файлы |
    - | Забронировать переговорку |
    - Купить торт
    </tasks>
    <open>
    - None
    </open>
    """

/// Text-only requests and what they're answered.
private final class FakeText: Sendable {
    let requests = OSAllocatedUnfairLock(initialState: [(text: String, prompt: String)]())
    let answer: @Sendable () throws -> String

    init(answer: @escaping @Sendable () throws -> String = { blocks }) {
        self.answer = answer
    }

    var count: Int { requests.withLock { $0.count } }

    func send(_ text: String, _ prompt: String) async throws -> CloudResult {
        requests.withLock { $0.append((text, prompt)) }
        var result = CloudResult(text: try answer())
        result.costUSD = 0.002
        return result
    }
}

@Suite struct CallSummaryParserTests {
    @Test func everyBlockIsRead() throws {
        let summary = try #require(CallSummaryParser.parse("[00:01-00:02] Sam: Привет\n" + blocks))
        #expect(summary.summary == "Обсудили релиз. Решили выпускать в пятницу.")
        #expect(summary.keyPoints == ["Импорт работает", "Длинные файлы грузятся долго", "Нужно резать на части"])
        #expect(summary.decided == ["Релиз в пятницу"])
        #expect(summary.tasks.map(\.owner) == ["Sam", "Аня", nil, nil])
        #expect(summary.tasks.map(\.text) == ["Разрезать файлы на части", "Проверить длинные файлы",
                                              "Забронировать переговорку", "Купить торт"])
        #expect(summary.tasks.map(\.due) == ["до четверга", nil, nil, nil])
        #expect(summary.tasks.allSatisfy { !$0.done })
        // "None" is nothing.
        #expect(summary.open.isEmpty)
    }

    @Test func aMissingOrBrokenBlockLosesOnlyItself() throws {
        let answer = """
            Sure, here it is.
            <summary>A short call.</summary>
            <decided>
            - Ship it
            <tasks>
            * **Sam** | Write the notes | Friday
            </tasks>
            <open>
            2) Who pays?
            </open>
            Hope that helps!
            """
        let summary = try #require(CallSummaryParser.parse(answer))
        #expect(summary.summary == "A short call.")
        // Never closed before the next block opened: lost.
        #expect(summary.decided.isEmpty)
        // Not there at all.
        #expect(summary.keyPoints.isEmpty)
        #expect(summary.tasks == [CallTask(id: summary.tasks[0].id, owner: "Sam", text: "Write the notes", due: "Friday")])
        #expect(summary.open == ["Who pays?"])
        // Cut off inside the last block: everything closed before it stays.
        let cut = try #require(CallSummaryParser.parse("<summary>Да.</summary>\n<key_points>\n- Один\n- Два"))
        #expect(cut.summary == "Да." && cut.keyPoints.isEmpty)
        // Nothing whole: no summary.
        #expect(CallSummaryParser.parse("[00:01-00:02] Sam: Hi\n<summary>Cut off") == nil)
        #expect(CallSummaryParser.parse("No blocks here.") == nil)
        #expect(CallSummaryParser.blocksFound(in: answer) == 3)
    }

    @Test func emptyBlocksAreAnEmptySummary() throws {
        let summary = try #require(CallSummaryParser.parse(
            "<summary></summary>\n<key_points>\n</key_points>\n<decided>\n-\n</decided>\n<tasks>\n- | |\n</tasks>\n<open></open>"))
        #expect(summary.isEmpty)
    }

    @Test func theTranscriptStopsWhereTheBlocksStart() {
        let answer = """
            [00:01-00:03] Sam: Привет
            [00:04-00:06] Аня: Да, слышу
            <summary>
            Короткий созвон.
            </summary>
            <key_points>
            - [00:05] Аня: всё слышно
            - 10:30 встреча перенесена
            </key_points>
            <tasks>
            - Sam | Отправить заметки |
            </tasks>
            """
        let parsed = CallTranscriptParser.parse(answer, side: .remote, duration: 60, speakers: ["Sam"])
        #expect(parsed.segments.map(\.text) == ["Привет", "Да, слышу"])
        #expect(parsed.skipped == 0 && parsed.format == .lines)
        // A stray closing tag ends it too.
        let stray = CallTranscriptParser.parse("[00:01-00:02] Sam: Hi\n</summary>\n- point", side: .remote,
                                               duration: 60)
        #expect(stray.segments.count == 1 && stray.skipped == 0)
        // Blocks with no speech before them: nothing said, not unreadable.
        #expect(CallTranscriptParser.parse("NO SPEECH\n<summary></summary>", side: .remote, duration: 60).format == .empty)
    }

    @Test func ticksAreKeptForTheSameTasks() {
        let old = CallSummary(tasks: [
            CallTask(owner: "Sam", text: "Send the notes.", done: true),
            CallTask(text: "Book the room", done: false),
            CallTask(text: "Gone now", done: true),
        ])
        let new = CallSummary(tasks: [
            CallTask(owner: "Participant 1", text: "send the notes"),
            CallTask(text: "Buy a cake"),
            CallTask(text: "Book  the room!"),
        ])
        let kept = new.keepingDone(from: old)
        #expect(kept.tasks.map(\.done) == [true, false, false])
        #expect(kept.tasks[0].id == old.tasks[0].id && kept.tasks[2].id == old.tasks[1].id)
        #expect(kept.tasks[0].owner == "Participant 1")
        #expect(new.keepingDone(from: nil) == new)
    }

    @Test func oldRecordsAndOddSummariesStillRead() throws {
        let old = #"{"id":"00000000-0000-4000-8000-000000000001","startedAt":"2026-10-01T10:00:00Z","appName":"Zoom","status":"done"}"#
        let record = try JSONDecoder.iso8601.decode(CallRecord.self, from: Data(old.utf8))
        #expect(record.summary == nil && record.summaryError == nil)
        let odd = #"""
            {"id":"00000000-0000-4000-8000-000000000002","startedAt":"2026-10-01T10:00:00Z","appName":"Zoom",
             "status":"done","summary":{"summary":"Hi","tasks":[{"text":"Do it","done":true},{"owner":"Sam"}],
             "future":1}}
            """#
        let summary = try #require(try JSONDecoder.iso8601.decode(CallRecord.self, from: Data(odd.utf8)).summary)
        #expect(summary.summary == "Hi" && summary.keyPoints.isEmpty)
        #expect(summary.tasks.map(\.text) == ["Do it"] && summary.tasks[0].done)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
@Suite(.serialized) struct CallSummaryTranscriberTests {
    private static func store(seconds: TimeInterval = 10) -> (CallStore, CallRecord) {
        let store = CallStore(paths: .temporary(), settings: .inMemory())
        store.load()
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Zoom", service: .zoom, status: .done)
        call.micFile = "mic.m4a"
        call.micSeconds = seconds
        call.remoteFile = "remote.m4a"
        call.remoteSeconds = seconds
        store.upsert(call)
        return (store, call)
    }

    @Test func aCallOfOneChunkIsSummedUpInTheSameAnswer() async throws {
        let (store, call) = Self.store()
        let audio = speech(seconds: 10)
        let prompts = OSAllocatedUnfairLock(initialState: [String]())
        let text = FakeText()
        let transcriber = CallTranscriber(store: store, send: { _, prompt, _, _ in
            prompts.withLock { $0.append(prompt) }
            var result = CloudResult(text: "[00:01-00:02] Аня: Привет\n[00:03-00:04] Sam: Hi\n" + blocks)
            result.costUSD = 0.01
            return result
        }, sendText: { try await text.send($0, $1) })
        transcriber.userName = { "Sam" }
        transcriber.read = { _, range in Array(audio[range]) }
        transcriber.transcribe(call.id)
        await transcriber.waitUntilIdle()
        let done = try #require(store.call(id: call.id))
        #expect(done.status == .done && done.summaryError == nil)
        #expect(done.transcript?.segments.map(\.text) == ["Привет", "Hi"])
        #expect(done.summary?.decided == ["Релиз в пятницу"] && done.summary?.tasks.count == 4)
        #expect(text.count == 0, "no second request")
        #expect(done.costUSD == 0.01)
        let prompt = try #require(prompts.withLock { $0.first })
        #expect(prompt.contains(CallPrompts.format(summary: true, me: "Sam")))
        #expect(prompt.contains("Answer with the transcript first, nothing before it:"))
        #expect(prompt.contains("<tasks>\n- owner | task | due\n</tasks>"))
        #expect(prompt.contains("named exactly as in the transcript (\"Sam\", \"Participant 1\")"))
        #expect(prompt.contains("rather than invent something to fill it"))
        #expect(!prompt.contains("nothing before or after it"))
        let answers = try FileManager.default.contentsOfDirectory(atPath: store.answersFolder(for: call.id).path)
        #expect(answers == ["1-mix.txt"])
    }

    @Test func anAnswerWithoutTheBlocksGetsTheTextRequest() async throws {
        let (store, call) = Self.store()
        let audio = speech(seconds: 10)
        let text = FakeText()
        let transcriber = CallTranscriber(store: store, send: { _, _, _, _ in
            CloudResult(text: "[00:01-00:02] Аня: Привет")
        }, sendText: { try await text.send($0, $1) })
        transcriber.read = { _, range in Array(audio[range]) }
        transcriber.transcribe(call.id)
        await transcriber.waitUntilIdle()
        let done = try #require(store.call(id: call.id))
        #expect(text.count == 1)
        #expect(done.summary?.summary.hasPrefix("Обсудили релиз") == true)
        #expect(done.costUSD == 0.002)
    }

    @Test func aLongCallIsSummedUpInOneMoreTextRequest() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let audio = speech(seconds: 25)
        let prompts = OSAllocatedUnfairLock(initialState: [String]())
        let text = FakeText()
        let answers = AppPaths.temporary().root.appendingPathComponent("answers", isDirectory: true)
        let plan = CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: URL(fileURLWithPath: "/mic.m4a"),
                                        remoteSamples: audio.count, micSamples: audio.count, mutes: [],
                                        userName: "Sam", service: "Zoom", answers: answers, callID: UUID())
        let outcome = try await CallTranscriber.run(plan, maxChunkSeconds: 10, send: { _, prompt, _, _ in
            let index = prompts.withLock { $0.append(prompt); return $0.count }
            var result = CloudResult(text: "[00:01-00:03] Sam: Привет (\(index))\n[00:04-00:05] Аня: Да")
            result.costUSD = 0.01
            return result
        }, summarize: { try await text.send($0, $1) }, read: { _, range in Array(audio[range]) }, log: log)
        let chunkPrompts = prompts.withLock { $0 }
        #expect(chunkPrompts.count == 3)
        #expect(chunkPrompts.allSatisfy { $0.contains(CallPrompts.format) && !$0.contains("<summary>") })
        let request = try #require(text.requests.withLock { $0.first })
        #expect(text.count == 1)
        // The whole merged transcript, with times on the call's clock and the speakers as named.
        #expect(request.text.hasPrefix("[00:01-00:03] Sam: Привет (1)\n[00:04-00:05] Аня: Да\n[00:09-"))
        #expect(request.text.contains("Sam: Привет (3)"))
        #expect(request.text.components(separatedBy: "\n").count == 6)
        #expect(request.prompt.contains("Sam recorded it.") && request.prompt.contains("a call on Zoom"))
        // They may only have listened: the summary doesn't make them the one who ran it.
        #expect(request.prompt.contains("Sam may not have spoken at all, only listened: don't say they led the call or "
                                        + "said something unless the transcript shows it."))
        #expect(request.prompt.contains("Answer with only the five blocks, nothing before or after them."))
        #expect(request.prompt.contains(CallSummaryPrompt.blocks(me: "Sam")))
        #expect(outcome.summary?.keyPoints.count == 3 && outcome.summaryError == nil)
        #expect(abs((outcome.costUSD ?? 0) - 0.032) < 1e-9, "three chunks and the summary")
        #expect(try String(contentsOf: answers.appendingPathComponent("summary.txt"), encoding: .utf8) == blocks)
        log.flush()
        let logged = log.retainedText()
        #expect(logged.contains("[calls] summary.request") && logged.contains("phrases=6") && logged.contains("blocks=5"))
        #expect(!logged.contains("Привет") && !logged.contains("релиз"))
    }

    @Test func aFailedSummaryKeepsTheTranscriptAndSummarizeTriesAgain() async throws {
        let audio = speech(seconds: 25)
        let failing = FakeText { throw AppError.openRouterMissingKey }
        let plan = CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: nil,
                                        remoteSamples: audio.count, micSamples: 0, mutes: [],
                                        userName: "Sam", service: nil)
        let outcome = try await CallTranscriber.run(plan, maxChunkSeconds: 10, send: { _, _, _, _ in
            var result = CloudResult(text: "[00:01-00:03] Аня: Привет")
            result.costUSD = 0.01
            return result
        }, summarize: { try await failing.send($0, $1) }, read: { _, range in Array(audio[range]) })
        #expect(outcome.transcript.segments.count == 3)
        #expect(outcome.summary == nil && outcome.summaryError == AppError.openRouterMissingKey.localizedDescription)
        #expect(abs((outcome.costUSD ?? 0) - 0.03) < 1e-9)

        // The call as it's saved then: done, its transcript, why the summary failed. Summarize tries again.
        let (store, call) = Self.store(seconds: 25)
        store.update(call.id) {
            $0.transcript = outcome.transcript
            $0.summaryError = outcome.summaryError
            $0.costUSD = outcome.costUSD
        }
        let text = FakeText()
        let transcriber = CallTranscriber(store: store, send: { _, _, _, _ in
            Issue.record("no audio is sent again")
            return CloudResult(text: "")
        }, sendText: { try await text.send($0, $1) })
        transcriber.summarize(call.id)
        #expect(store.summarizing.contains(call.id))
        #expect(store.call(id: call.id)?.summaryError == nil)
        await transcriber.waitUntilIdle()
        let done = try #require(store.call(id: call.id))
        #expect(!store.summarizing.contains(call.id))
        #expect(done.status == .done && done.summaryError == nil && done.summary?.tasks.count == 4)
        #expect(abs((done.costUSD ?? 0) - 0.032) < 1e-9)
        #expect(FileManager.default.fileExists(
            atPath: store.answersFolder(for: call.id).appendingPathComponent("summary.txt").path))
    }

    @Test func summarizeSumsUpACallTranscribedBefore() async throws {
        let (store, call) = Self.store()
        store.update(call.id) {
            $0.transcript = CallTranscript(segments: [
                .init(start: 1, end: 3, side: .local, speaker: "Me", text: "I’ll send the notes."),
                .init(start: 4, end: 6, side: .remote, speaker: "Participant 1", text: "Thanks."),
            ])
            $0.costUSD = 0.05
        }
        let text = FakeText { "Here:\n<summary>Notes.</summary>\n<tasks>\n- Me | Send the notes | today\n</tasks>" }
        let transcriber = CallTranscriber(store: store, send: { _, _, _, _ in CloudResult(text: "") },
                                          sendText: { try await text.send($0, $1) })
        transcriber.summarize(call.id)
        await transcriber.waitUntilIdle()
        let done = try #require(store.call(id: call.id))
        #expect(done.summary?.summary == "Notes.")
        #expect(done.summary?.tasks.first?.owner == "Me" && done.summary?.tasks.first?.due == "today")
        #expect(abs((done.costUSD ?? 0) - 0.052) < 1e-9)
        let request = try #require(text.requests.withLock { $0.first })
        #expect(request.text == "[00:01-00:03] Me: I’ll send the notes.\n[00:04-00:06] Participant 1: Thanks.")
        #expect(request.prompt.contains("The person who recorded it is called \"Me\". They may not have spoken at all, "
                                        + "only listened: don't say \"Me\" led the call or said something unless the "
                                        + "transcript shows it."))
        // A summary that fails says why, and the call stays as it was.
        let failing = FakeText { "I can't." }
        let again = CallTranscriber(store: store, send: { _, _, _, _ in CloudResult(text: "") },
                                    sendText: { try await failing.send($0, $1) })
        again.summarize(call.id)
        await again.waitUntilIdle()
        let failed = try #require(store.call(id: call.id))
        #expect(failed.summaryError == "Gemini’s answer had no summary in it" && failed.summary?.summary == "Notes.")
        #expect(failed.transcript?.segments.count == 2 && failed.status == .done)
    }

    @Test func ticksAreSavedAndSurviveTranscribeAgain() async throws {
        let paths = AppPaths.temporary()
        let store = CallStore(paths: paths, settings: .inMemory())
        store.load()
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Zoom", service: .zoom, status: .done)
        call.micFile = "mic.m4a"
        call.micSeconds = 10
        store.upsert(call)
        let audio = speech(seconds: 10)
        let answer = OSAllocatedUnfairLock(initialState: "[00:01-00:02] Sam: Hi\n" + blocks)
        let transcriber = CallTranscriber(store: store) { _, _, _, _ in CloudResult(text: answer.withLock { $0 }) }
        transcriber.read = { _, range in Array(audio[range]) }
        transcriber.transcribe(call.id)
        await transcriber.waitUntilIdle()
        let task = try #require(store.call(id: call.id)?.summary?.tasks.first)
        store.setTask(task.id, done: true, in: call.id)
        await store.flush()
        let saved = try CallStore.readRecords(from: Data(contentsOf: paths.callsFile))
        #expect(saved.first?.summary?.tasks.first?.done == true)
        #expect(saved.first?.summary?.tasks.dropFirst().allSatisfy { !$0.done } == true)

        // Transcribe Again: the same task, written a little differently, stays ticked; a new one isn't.
        answer.withLock {
            $0 = "[00:01-00:02] Sam: Hi\n<tasks>\n- Sam | разрезать файлы на части. | четверг\n- Sam | Новое |\n</tasks>"
        }
        transcriber.retranscribe(call.id)
        await transcriber.waitUntilIdle()
        let tasks = try #require(store.call(id: call.id)?.summary?.tasks)
        #expect(tasks.map(\.done) == [true, false])
        #expect(tasks[0].id == task.id && tasks[0].due == "четверг")
    }
}

@Suite struct CallSummaryFormatTests {
    private static func call() -> CallRecord {
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Zoom", status: .done)
        call.transcript = CallTranscript(segments: [
            .init(start: 1, end: 2, side: .remote, speaker: "Participant 1", text: "Hi"),
            .init(start: 3, end: 4, side: .local, speaker: "Sam", text: "Hello"),
        ])
        call.speakerNames = ["Participant 1": "Matvey"]
        call.summary = CallSummary(
            summary: "A short call.", keyPoints: ["One", "Two"], decided: [],
            tasks: [
                CallTask(owner: "participant 1", text: "Send the notes", due: "Friday", done: true),
                CallTask(owner: "Аня", text: "Book the room"),
                CallTask(text: "Buy a cake"),
            ],
            open: ["Who pays?"])
        return call
    }

    @Test func ownersAreShownAsRenamed() {
        let call = Self.call()
        let tasks = call.summary!.tasks
        #expect(CallFormat.ownerSpeaker(call, tasks[0]) == "Participant 1")
        #expect(CallFormat.ownerName(call, tasks[0]) == "Matvey")
        // Not one of the call's speakers: as written, no color.
        #expect(CallFormat.ownerSpeaker(call, tasks[1]) == nil && CallFormat.ownerName(call, tasks[1]) == "Аня")
        #expect(CallFormat.ownerName(call, tasks[2]) == nil)
    }

    @Test func theSummaryCopiesAsTextWithItsHeadings() {
        let call = Self.call()
        #expect(CallFormat.summaryText(call) == """
            Summary
            A short call.

            Key points
            - One
            - Two

            Tasks
            [x] Matvey: Send the notes (Friday)
            [ ] Аня: Book the room
            [ ] Buy a cake

            Open
            - Who pays?
            """)
        // Copy Transcript stays the transcript.
        #expect(CallFormat.copyText(call) == "[00:01] Matvey: Hi\n[00:03] Sam: Hello")
        var none = call
        none.summary = nil
        #expect(CallFormat.summaryText(none).isEmpty)
    }

    @Test func theListCountsTasksDone() {
        var call = Self.call()
        #expect(CallFormat.taskCount(call) == "1/3 tasks")
        call.summary?.tasks = [CallTask(text: "Only", done: false)]
        #expect(CallFormat.taskCount(call) == "0/1 task")
        call.summary?.tasks = []
        #expect(CallFormat.taskCount(call) == nil)
        call.summary = nil
        #expect(CallFormat.taskCount(call) == nil)
    }
}

extension CallSummaryTranscriberTests {
    private static func log() -> (DiagnosticLog, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("summary-log-\(UUID().uuidString)",
                                                                                  isDirectory: true)
        let log = DiagnosticLog()
        log.start(directory: folder)
        return (log, folder)
    }
}

// The call's speakers marked in a summary's text ("{{Аня|Ане}}", `CallMention`), so a rename on the call's page renames
// them in the summary too.
@Suite struct CallSummaryMentionTests {
    private static func call(renames: [String: String] = ["Participant 1": "Matvey"]) -> CallRecord {
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Zoom", status: .done)
        call.transcript = CallTranscript(segments: [
            .init(start: 1, end: 2, side: .remote, speaker: "Participant 1", text: "Hi"),
            .init(start: 3, end: 4, side: .remote, speaker: "Аня", text: "Привет"),
            .init(start: 5, end: 6, side: .local, speaker: "Sam", text: "Hello"),
        ])
        call.speakerNames = renames
        return call
    }

    @Test func thePromptAsksForMarkedMentionsWithAnExample() {
        let blocks = CallSummaryPrompt.blocks(me: "Sam")
        #expect(blocks.contains("write every mention of someone who speaks in the call as {{Name|word}}"))
        #expect(blocks.contains("Name exactly as the transcript names them"))
        #expect(blocks.contains("when the word is the name itself, {{Name}} is enough"))
        #expect(blocks.contains(#""{{Аня|Ане}} нужно проверить длинные файлы""#))
        #expect(blocks.contains(#""{{Sam}} will send the notes""#) && blocks.contains("{{Participant 2}}"))
        #expect(blocks.contains("The owner in <tasks> stays a plain name"))
        // Still only what was said, and the quotes and hyphens.
        #expect(blocks.contains("Only write what was said in the call"))
        #expect(blocks.contains(#"straight quotes "like this""#) && blocks.contains(#"plain hyphen "-""#))
        // Both ways a summary is asked for.
        #expect(CallPrompts.format(summary: true, me: "Sam").contains(blocks))
        #expect(CallSummaryPrompt.text(me: "Sam", service: nil).contains(blocks))
        #expect(CallSummaryPrompt.blocks(me: "Me").contains(#""{{Me}} will send the notes""#))
    }

    @Test func everyShapeOfMarkIsRead() {
        typealias P = CallMention.Piece
        #expect(CallMention.pieces("{{Аня|Ане}} нужно проверить") == [
            P.mention(speaker: "Аня", form: "Ане"), .text(" нужно проверить"),
        ])
        #expect(CallMention.pieces("Ask {{Participant 2}}.") == [
            .text("Ask "), .mention(speaker: "Participant 2", form: "Participant 2"), .text("."),
        ])
        // Spaces inside, an empty form, a form with no name.
        #expect(CallMention.pieces("{{ Аня | Аней }}") == [.mention(speaker: "Аня", form: "Аней")])
        #expect(CallMention.pieces("{{Аня|}}") == [.mention(speaker: "Аня", form: "Аня")])
        #expect(CallMention.pieces("с {{|Аней}}") == [.text("с Аней")])
        // Not marks: left as written.
        #expect(CallMention.pieces("No marks here") == [.text("No marks here")])
        #expect(CallMention.pieces("{Аня} and }} and {{") == [.text("{Аня} and }} and {{")])
        #expect(CallMention.pieces("Unclosed {{Аня|Ане нужно") == [.text("Unclosed {{Аня|Ане нужно")])
        // Empty: nothing to show.
        #expect(CallMention.pieces("{{}}").isEmpty && CallMention.pieces("{{ | }}").isEmpty)
        let long = String(repeating: "a", count: CallMention.maxLength + 1)
        #expect(CallMention.pieces("x {{\(long)}}") == [.text("x {{\(long)}}")])
        // Opened inside another: the inner one is the mark.
        #expect(CallMention.pieces("{{a {{Аня|Ане}} b}}") == [
            .text("{{a "), .mention(speaker: "Аня", form: "Ане"), .text(" b}}"),
        ])
        #expect(CallMention.plain("{{Аня|Ане}} и {{Sam}}") == "Ане и Sam")
        #expect(CallMention.names("{{Аня|Ане}} и {{Sam}}") == "Аня и Sam")
    }

    @Test func aRenamedSpeakerShowsTheirNewNameAndTheOthersTheWordWritten() {
        let call = Self.call()
        let text = "{{Participant 1|Первому участнику}} и {{Аня|Ане}} нужно написать {{Sam}} и {{Петя|Пете}}"
        #expect(CallFormat.plain(call, text) == "Matvey и Ане нужно написать Sam и Пете")
        #expect(CallFormat.shown(call, text).compactMap(\.speaker) == ["Participant 1", "Аня", "Sam"])
        // Matched case aside, like owners.
        #expect(CallFormat.plain(call, "{{participant 1|него}}") == "Matvey")
        // Nobody renamed: every word as the model wrote it.
        let plain = Self.call(renames: [:])
        #expect(CallFormat.plain(plain, text) == "Первому участнику и Ане нужно написать Sam и Пете")
        // Renamed later: the summary follows.
        var renamed = plain
        renamed.speakerNames = ["Аня": "Anna"]
        #expect(CallFormat.plain(renamed, text) == "Первому участнику и Anna нужно написать Sam и Пете")
    }

    @Test func aSummaryWithoutMarksShowsAsWritten() {
        let call = Self.call()
        let old = "Participant 1 asked Аня to {check} the files."
        #expect(CallFormat.plain(call, old) == old)
        #expect(CallFormat.shown(call, old) == [CallFormat.Shown(text: old)])
    }

    @Test func theCopiedSummaryHasTheNewNames() {
        var call = Self.call()
        call.summary = CallSummary(
            summary: "{{Participant 1}} and {{Аня}} went over the release.",
            keyPoints: ["{{Аня|Ане}} нужно проверить файлы"], decided: ["Ship on Friday, as {{Sam}} said."],
            tasks: [CallTask(owner: "Аня", text: "Написать {{Participant 1|первому участнику}}", due: "до {{Sam|Сэма}}")],
            open: ["Whether {{Participant 1}} pays"])
        #expect(CallFormat.summaryText(call) == """
            Summary
            Matvey and Аня went over the release.

            Key points
            - Ане нужно проверить файлы

            Decided
            - Ship on Friday, as Sam said.

            Tasks
            [ ] Аня: Написать Matvey (до Сэма)

            Open
            - Whether Matvey pays
            """)
    }

    @Test func tasksAreReadWithMarksInThem() throws {
        let summary = try #require(CallSummaryParser.parse("""
            <tasks>
            - Sam | Написать {{Аня|Ане}} и {{Participant 1}} | пятница
            - {{Аня}} | Проверить файлы |
            - {{Аня|Ане}} позвонить
            - | Спросить {{Participant 2|второго}} |
            </tasks>
            """))
        #expect(summary.tasks.map(\.owner) == ["Sam", "Аня", nil, nil])
        #expect(summary.tasks.map(\.text) == ["Написать {{Аня|Ане}} и {{Participant 1}}", "Проверить файлы",
                                              "{{Аня|Ане}} позвонить", "Спросить {{Participant 2|второго}}"])
        #expect(summary.tasks.map(\.due) == ["пятница", nil, nil, nil])
        // Ticks kept whether or not the task's mentions are marked.
        let old = CallSummary(tasks: [CallTask(text: "Написать Ане и Participant 1", done: true)])
        #expect(summary.keepingDone(from: old).tasks[0].done)
    }
}

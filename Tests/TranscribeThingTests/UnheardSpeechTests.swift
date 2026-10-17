import Foundation
import Testing
@testable import TranscribeThing

// MARK: - A cloud model that hears no speech in a recording full of it: kept in History, not thrown away

@MainActor
@Suite(.serialized) struct UnheardSpeechTests {
    typealias H = DictationControllerTests

    /// The reported dictation: 32 s, 21.7 s of it voiced.
    static func longSpeech() -> Recording {
        Recording(samples: Array(repeating: 0.1, count: 16_000 * 32),
                  speech: SpeechStats(voicedSeconds: 21.67, peakDBFS: -12, isSilent: false))
    }

    static func speech(voiced: Double) -> Recording {
        Recording(samples: Array(repeating: 0.1, count: 16_000 * 3),
                  speech: SpeechStats(voicedSeconds: voiced, peakDBFS: -12, isSilent: false))
    }

    /// Gemini's empty answer as the service hands it on: no text, the whole answer in `rawAnswer`.
    static func empty(_ engine: EngineID, answer: String = "<transcript></transcript>") -> TranscriptResult {
        var result = TranscriptResult(text: "", engine: engine, processingTime: 7.26)
        result.rawAnswer = answer
        result.answerTags = .pair
        result.finishReason = "stop"
        result.usage = TokenUsage(promptTokens: 2476, completionTokens: 9, reasoningTokens: 0)
        return result
    }

    /// Flash's answer without tags is pasted: it tags its answers, and one that doesn't is still words.
    @Test func flashsUntaggedAnswerIsStillPasted() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in
            var result = TranscriptResult(text: "Созвонимся завтра.", engine: engine, processingTime: 0.1)
            result.answerTags = TaggedTranscript.Tags.none
            return result
        }
        h.controller.insertOverride = { text in pasted.append(text); return .pasted }
        h.controller.enqueue(Self.speech(voiced: 2.5), engine: .geminiFlash)
        try await waitUntil { !pasted.isEmpty }
        #expect(pasted == ["Созвонимся завтра."])
    }

    /// Gemini polished 21.7 s of speech into an empty `<message>`: the recording stays as a failed row with the answer,
    /// the notice offers Retry and says it's kept, and Retry then pastes what the next answer has.
    @Test func longSpeechWithAnEmptyAnswerIsKeptWithTheAnswer() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var answers = ["<message>\n\n</message>", "<message>Созвонимся завтра в десять.</message>"]
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: answers.removeFirst(), engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { text in pasted.append(text); return .pasted }
        let r = Self.longSpeech()
        h.controller.enqueue(r, engine: .geminiFlash, polishes: true)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }

        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.status == .failed && entry.engine == .geminiFlash)
        #expect(entry.errorMessage == "Gemini 3.8 Flash heard no speech")
        #expect(entry.modelAnswer == "<message>\n\n</message>", "the answer as it came, tags and all")
        #expect(entry.audioFileName != nil)
        #expect(h.controller.retainedRecordingIDs.contains(r.id))
        #expect(pasted.isEmpty)

        let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
        #expect(notice.dedupeKey == "error.heardNoSpeech.geminiFlash")
        #expect(notice.title == "Gemini 3.8 Flash heard no speech")
        #expect(notice.body == "Your recording is saved in History, where another model can try it too.")
        #expect(notice.style == .warning && notice.actions.map(\.kind) == [.retry])
        #expect(!h.toasts.notices.contains { $0.dedupeKey == "error.noSpeech" })
        #expect(h.pill.errorMessage == PillMetrics.keptNoSpeechText)
        #expect(h.pill.errorModel == .gemini)

        // Retry: the same model, polished again, and this time it hears it.
        h.controller.perform(try #require(notice.actions.first), from: notice)
        try await waitUntil { !pasted.isEmpty && h.controller.machine.activeJobs == 0 }
        #expect(pasted.first?.hasPrefix("Созвонимся завтра в десять") == true)
        let done = try #require(h.history.entry(id: r.id))
        #expect(done.status == .success && done.currentVersion?.kind == .polish(by: .geminiFlash))
        #expect(done.modelAnswer == nil, "a transcript has nothing to explain")
    }

    /// From Home, the kept row takes Transcribe With like any failed one: Parakeet writes it.
    @Test func theKeptRowCanBeTranscribedWithAnotherModel() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.controller.transcribeOverride = { _, engine in
            engine == .parakeet ? TranscriptResult(text: "Привет, это Parakeet.", engine: engine, processingTime: 0.1)
                : Self.empty(engine)
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = Self.longSpeech()
        h.controller.enqueue(r, engine: .geminiFlash)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id)?.status == .failed }
        let failed = try #require(h.history.entry(id: r.id))
        #expect(failed.errorMessage == "Gemini 3.8 Flash heard no speech")
        #expect(failed.modelAnswer == "<transcript></transcript>")

        h.controller.retry(failed, with: .parakeet)
        try await waitUntil { h.history.entry(id: r.id)?.status == .success }
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.text == "Привет, это Parakeet." && entry.engine == .parakeet)
    }

    /// Below the threshold an empty answer is silence, as before: nothing kept, "No speech detected" in the pill.
    /// Parakeet's empty answer is silence whatever the speech: the threshold is for cloud models only.
    @Test func littleSpeechOrALocalModelIsStillSilence() async throws {
        let cases: [(EngineID, Recording)] = [
            (.geminiFlash, Self.speech(voiced: DictationController.keepsUnheardSpeechVoicedSeconds - 0.1)),
            (.geminiFlash, Self.speech(voiced: 0.6)),
            (.parakeet, Self.longSpeech()),
        ]
        for (engine, recording) in cases {
            let h = H.make(keyStatus: .valid(KeyInfo()))
            h.controller.transcribeOverride = { _, engine in Self.empty(engine) }
            h.controller.insertOverride = { _ in Issue.record("nothing should be pasted"); return .pasted }
            h.controller.enqueue(recording, engine: engine)
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            #expect(h.history.entries.isEmpty, "\(engine)")
            #expect(h.pill.errorMessage == PillMetrics.noSpeechText, "\(engine)")
            #expect(h.toasts.notices.isEmpty, "\(engine)")
            #expect(!h.controller.retainedRecordingIDs.contains(recording.id), "\(engine)")
        }
    }

    /// Right at the threshold it's kept; with no pill (Never) the notice still says so.
    @Test func theThresholdKeepsAndNeverModeStillSaysSo() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        h.settings.pillMode = .never
        h.controller.transcribeOverride = { _, engine in Self.empty(engine) }
        let r = Self.speech(voiced: DictationController.keepsUnheardSpeechVoicedSeconds)
        h.controller.enqueue(r, engine: .geminiFlash, translates: true)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        #expect(h.history.entry(id: r.id)?.status == .failed)
        #expect(h.toasts.notices.map(\.dedupeKey) == ["error.heardNoSpeech.geminiFlash"])
    }

    /// The answer rides along in history.json (here on an old row by the retired Gemini 4 Argon), and an entry without
    /// one, or with something odd there, still reads.
    @Test func theAnswerIsStoredAndReadLeniently() throws {
        var entry = TranscriptEntry(text: "", engine: .geminiArgon, status: .failed, audioDuration: 32,
                                    voicedSeconds: 21.67, errorMessage: "Gemini 4 Argon heard no speech")
        entry.modelAnswer = "<message></message>"
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(TranscriptEntry.self, from: data) == entry)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["modelAnswer"] = ["unexpected": 1]
        let odd = try JSONDecoder().decode(TranscriptEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(odd.modelAnswer == nil && odd.status == .failed)
        object["modelAnswer"] = nil
        let plain = try JSONDecoder().decode(TranscriptEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(plain.modelAnswer == nil)
    }

    @Test func theRowShowsTheAnswerOnHover() {
        #expect(HistoryRowText.modelAnswerTooltip(nil) == nil)
        #expect(HistoryRowText.modelAnswerTooltip("<message></message>") == "Model’s answer: <message></message>")
        #expect(HistoryRowText.modelAnswerTooltip(" \n") == "Model’s answer: nothing at all")
        let long = HistoryRowText.modelAnswerTooltip(String(repeating: "a", count: 900))
        #expect(long?.count == "Model’s answer: ".count + HistoryRowText.modelAnswerTooltipLimit)
    }

    /// Home's Retry on a failed row that hears no speech again keeps the answer on the row.
    @Test func homeKeepsTheAnswerOnAFailedRow() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        var calls = 0
        h.controller.transcribeOverride = { _, engine in
            calls += 1
            if calls == 1 { throw AppError.timeout(engine) }
            return Self.empty(engine, answer: "<transcript>\n</transcript>")
        }
        let r = Self.longSpeech()
        h.controller.enqueue(r, engine: .geminiFlash)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id)?.status == .failed }
        h.controller.retry(try #require(h.history.entry(id: r.id)), with: .geminiFlash)
        try await waitUntil { calls == 2 && h.controller.runningVersions.isEmpty }
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.status == .failed && entry.engine == .geminiFlash)
        #expect(entry.modelAnswer == "<transcript>\n</transcript>")
    }
}

// MARK: - The log says how the empty answer looked, never what it said

extension DiagnosticDictationTests {
    @Test func anEmptyAnswerIsLoggedByItsShapeNotItsWords() async throws {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("tt-unheard-\(UUID().uuidString)",
                                                                              isDirectory: true)
        DiagnosticLog.shared.start(directory: logs)
        defer {
            DiagnosticLog.shared.stop()
            DiagnosticLog.shared.flush()
            try? FileManager.default.removeItem(at: logs)
        }
        let h = DictationControllerTests.make(keyStatus: .valid(KeyInfo()))
        h.controller.transcribeOverride = { _, engine in
            UnheardSpeechTests.empty(engine, answer: "<transcript></transcript>\nOnly a confidential whisper.")
        }
        let r = UnheardSpeechTests.longSpeech()
        h.controller.enqueue(r, engine: .geminiFlash)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        let text = DiagnosticLog.shared.retainedText()
        // Its own line: tests running alongside log their dictations to the same log.
        let line = try #require(text.split(separator: "\n").first {
            $0.contains("job.finished engine=geminiFlash outcome=noSpeech") && $0.contains("voiced=21.67")
        })
        for field in ["kept=yes", "answerChars=54", "tags=pair", "transcriptTags=yes", "messageTags=no",
                      "onlyTags=no", "noSpeechWords=no", "outsideChars=28", "finish=stop", "reasoningTokens=0",
                      "outputTokens=9"] {
            #expect(line.contains(field), "\(field) in \(line)")
        }
        #expect(!text.contains("confidential"), "never the answer's words")
    }
}

// MARK: - Reading the transcript out of an answer: nothing said is dropped, nothing remarked is pasted

@Suite struct AnswerExtractionTests {
    typealias T = TaggedTranscript

    @Test func emptyTagsAreNoSpeech() {
        #expect(T.extract("<message>\n\n</message>", open: Polish.open, close: Polish.close) == ("", .pair))
        #expect(T.extract("<transcript>  </transcript>") == ("", .pair))
        #expect(Polish.message(from: "<message></message>") == "")
    }

    @Test func textBeforeTheTagsIsLeftOut() {
        #expect(T.extract("Вот сообщение:\n<message>Привет, как дела?</message>", open: Polish.open, close: Polish.close)
                == ("Привет, как дела?", .pair))
    }

    @Test func aCodeFenceIsTakenOff() {
        #expect(T.extract("```xml\n<transcript>Привет.</transcript>\n```") == ("Привет.", .pair))
        #expect(T.extract("```\nПривет, это без тегов.\n```") == ("Привет, это без тегов.", .none))
        #expect(T.extract("```text\n<transcript></transcript>\n```") == ("", .pair))
        // Not a fence around the whole answer: as it is.
        #expect(T.extract("Use ``` for code.") == ("Use ``` for code.", .none))
    }

    /// An empty pair with what was said written outside it: those words, not nothing.
    @Test func wordsOutsideAnEmptyPairAreTheTranscript() {
        let after = "<transcript></transcript>\nДавай завтра созвонимся в десять утра."
        #expect(T.extract(after) == ("Давай завтра созвонимся в десять утра.", .outside))
        let before = "Давай завтра созвонимся в десять утра.\n<message></message>"
        #expect(T.extract(before, open: Polish.open, close: Polish.close)
                == ("Давай завтра созвонимся в десять утра.", .outside))
        #expect(T.extract("```\n<transcript></transcript>\nДавай завтра созвонимся в десять.\n```")
                == ("Давай завтра созвонимся в десять.", .outside))
    }

    /// A remark about the audio, or a word or two, is not what was said: the pair's emptiness stands.
    @Test func remarksOutsideAnEmptyPairAreNotPasted() {
        #expect(T.extract("<transcript></transcript> Only background noise, no speech.") == ("", .pair))
        #expect(T.extract("The audio is silent.\n<transcript></transcript>") == ("", .pair))
        #expect(T.extract("<message></message>\nЯ слышу только чужие голоса из видео.", open: Polish.open,
                          close: Polish.close) == ("", .pair))
        #expect(T.extract("Речи нет, только дыхание и клавиатура. <transcript></transcript>") == ("", .pair))
        #expect(T.extract("<transcript></transcript> ok") == ("", .pair))
    }

    /// Thinking in the answer that ends in an empty pair: the model decided there was nothing, drafts aside.
    @Test func anEmptyLastPairAfterDraftsStaysEmpty() {
        let answer = "Draft: <transcript>Привет, это фоновое видео</transcript>\nThat's a video, not you.\n<transcript></transcript>"
        #expect(T.extract(answer) == ("", .several))
    }

    @Test func theOtherTagsAreReadToo() {
        #expect(T.extract("<message>Привет.</message>") == ("Привет.", .other))
        #expect(T.extract("<transcript>Привет.</transcript>", open: Polish.open, close: Polish.close) == ("Привет.", .other))
        #expect(Polish.message(from: "<transcript>Привет.</transcript>") == "Привет.")
        // The asked-for tags win when both are there.
        #expect(T.extract("<message>a</message><transcript>b</transcript>") == ("b", .pair))
    }

    @Test func aBareNoSpeechIsNoText() {
        #expect(T.extract("NO SPEECH") == ("", .none))
        #expect(T.extract(" no speech.\n") == ("", .none))
        #expect(T.extract("<transcript>No speech.</transcript>") == ("No speech.", .pair), "said, in the tags")
    }

    @Test func theShapeSaysHowItLookedWithoutItsWords() {
        #expect(T.shape(of: "<message>\n</message>") == T.Shape(
            characters: 20, hasTranscriptTags: false, hasMessageTags: true, isOnlyTags: true,
            isNoSpeechLiteral: false, charactersOutsideTags: 0))
        #expect(T.shape(of: "NO SPEECH") == T.Shape(
            characters: 9, hasTranscriptTags: false, hasMessageTags: false, isOnlyTags: false,
            isNoSpeechLiteral: true, charactersOutsideTags: nil))
        #expect(T.shape(of: "Note.\n<transcript></transcript>\nHi").charactersOutsideTags == 7)
        #expect(T.shape(of: "```\n<transcript></transcript>\n```").isOnlyTags)
    }

    /// The client keeps the whole answer beside the transcript it read out of it.
    @Test func theClientKeepsTheRawAnswer() async throws {
        let answer = "<transcript>\n\n</transcript>"
        let (client, _) = StubURLProtocol.client([.stream(SSE.answer(answer))])
        let result = try await client.transcribe(audio: Data("dictation".utf8), format: "m4a",
                                                 model: "google/gemini-3.8-flash", systemPrompt: EngineID.geminiSystemPrompt,
                                                 effort: .medium, maxTokens: 32_768, apiKey: "sk-or-v1-test", timeout: 30)
        #expect(result.text == "" && result.answerTags == .pair)
        #expect(result.rawAnswer == answer)
    }
}

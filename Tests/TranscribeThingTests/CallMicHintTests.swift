import Foundation
import os
import Testing
@testable import TranscribeThing

// When the person spoke, from their own mic (`CallMicHint`): the local model's phrases go in each request's prompt
// instead of a sample of their voice, with the times of that request's audio; the other side's echo on the mic is left
// out; a mic that heard nothing of theirs says no voice is theirs; without the model the sample goes as before.
// Parakeet and Gemini are fakes.

private let rate = Recording.sampleRate

/// `seconds` of something SpeechAnalyzer hears as speech: a voice with harmonics in syllables, over faint noise.
private func speechLike(seconds: Double) -> [Float] {
    var seed: UInt32 = 12_345
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

/// A track `seconds` long with `speech` (start, length) in it, faint noise elsewhere (none with `noise` false).
private func track(_ seconds: Double, speech: [(at: Double, length: Double)], noise: Bool = true) -> [Float] {
    var out = [Float](repeating: 0, count: Int(seconds * rate))
    if noise {
        var seed: UInt32 = 777
        for index in out.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            out[index] = 0.002 * (Float(seed >> 8) / Float(1 << 24) - 0.5)
        }
    }
    for stretch in speech {
        let start = Int(stretch.at * rate)
        for (offset, sample) in speechLike(seconds: stretch.length).enumerated() where start + offset < out.count {
            out[start + offset] = sample
        }
    }
    return out
}

/// The local model, made up: one word over all of what it's given that's louder than faint noise, "фраза 1", "фраза
/// 2"… in the order it's given stretches. It can fail instead.
private final class FakeParakeet: Sendable {
    /// The length of each stretch it was given, in samples.
    let heard = OSAllocatedUnfairLock(initialState: [Int]())
    /// How many times it was told a call's mic was done.
    let done = OSAllocatedUnfairLock(initialState: 0)
    let failure: AppError?

    init(failing failure: AppError? = nil) {
        self.failure = failure
    }

    var listener: CallTranscriber.MicListener {
        CallTranscriber.MicListener(isAvailable: { true }, words: { try self.words($0) },
                                    done: { self.done.withLock { $0 += 1 } })
    }

    func words(_ samples: [Float]) throws -> [TimedWord] {
        if let failure { throw failure }
        let number = heard.withLock { $0.append(samples.count); return $0.count }
        guard let first = samples.firstIndex(where: { abs($0) > 0.01 }),
              let last = samples.lastIndex(where: { abs($0) > 0.01 }) else { return [] }
        return [TimedWord(text: "фраза \(number)", start: Double(first) / rate, end: Double(last + 1) / rate)]
    }
}

/// What each request was sent, and Gemini's made-up answers by request (from 1).
private final class Gemini: Sendable {
    struct Request: Sendable {
        var prompt: String
        var seconds: TimeInterval
        var sample: Data?
    }

    let requests = OSAllocatedUnfairLock(initialState: [Request]())
    let answer: @Sendable (_ index: Int) throws -> String

    init(_ answer: @escaping @Sendable (_ index: Int) throws -> String = { _ in "[00:01-00:03] Аня: Привет." }) {
        self.answer = answer
    }

    var prompts: [String] { requests.withLock { $0.map(\.prompt) } }
    var samples: [Data?] { requests.withLock { $0.map(\.sample) } }

    func send(_ audio: Data, _ prompt: String, _ seconds: TimeInterval, _ sample: Data?) async throws -> CloudResult {
        let index = requests.withLock {
            $0.append(Request(prompt: prompt, seconds: seconds, sample: sample))
            return $0.count
        }
        #expect(!audio.isEmpty)
        var result = CloudResult(text: try answer(index))
        result.finishReason = "stop"
        return result
    }
}

/// A call on Zoom from these tracks, Sam's.
private func plan(mic: [Float], remote: [Float], mutes: [CallInterval] = [],
                  callID: UUID? = nil) -> CallTranscriber.Plan {
    CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: URL(fileURLWithPath: "/mic.m4a"),
                         remoteSamples: remote.count, micSamples: mic.count, mutes: mutes, userName: "Sam",
                         service: "Zoom", callID: callID)
}

/// Reads the tracks of `plan(mic:remote:)`.
private func reader(mic: [Float], remote: [Float]) -> @Sendable (URL, Range<Int>) throws -> [Float] {
    { url, range in
        let samples = url.lastPathComponent == "mic.m4a" ? mic : remote
        return Array(samples[range.clamped(to: 0..<samples.count)])
    }
}

private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedWord {
    TimedWord(text: text, start: start, end: end)
}

@Suite(.serialized) struct CallMicHintTests {
    private static func log() -> (DiagnosticLog, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("calls-log-\(UUID().uuidString)",
                                                                                   isDirectory: true)
        let log = DiagnosticLog()
        log.start(directory: folder)
        return (log, folder)
    }

    /// Words make a phrase until a pause over 0.8 s, or until it has run past 15 s; punctuation on its own goes on the
    /// word before it.
    @Test func phrasesComeFromWordsByPausesAndLength() {
        var words = [word("Да", 0, 0.3), word("так", 0.5, 0.8), word("просто.", 1.5, 2), word("Ну", 2.9, 3.1),
                     word("?", 3.1, 3.2)]
        words += (10...27).map { word("слово", Double($0), Double($0) + 0.5) }
        let phrases = CallMicHint.phrases(words.shuffled())
        #expect(phrases.map(\.text).prefix(2) == ["Да так просто.", "Ну?"])
        #expect(phrases.map(\.start) == [0, 2.9, 10, 26])
        #expect(phrases.map(\.end) == [2, 3.2, 25.5, 27.5])
        #expect(phrases[2].text.split(separator: " ").count == 16)
        #expect(CallMicHint.phrases([word(" ", 1, 2)]).isEmpty)
    }

    /// A phrase is the person's when the mic is louder than the other side over its voiced frames, at the median: not
    /// when the other side is as loud or louder (their voice back through the speakers), nor where the mic heard no
    /// voice.
    @Test func onlyTheMicsOwnVoiceIsKept() {
        let phrase = CallMicHint.Phrase(start: 0, end: 1, text: "Да")
        let mic = [Float](repeating: -30, count: 100), voiced = [Bool](repeating: true, count: 100)
        func own(_ remote: [Float]?, voiced: [Bool] = voiced) -> Bool {
            CallMicHint.isOwnVoice(phrase, mic: mic, remote: remote, voiced: voiced)
        }
        #expect(own(nil), "no other side recorded")
        #expect(own([Float](repeating: -31, count: 100)))
        #expect(!own([Float](repeating: -30, count: 100)), "as loud")
        #expect(!own([Float](repeating: -20, count: 100)), "louder")
        // Louder than the mic in a third of the frames only: the median is still the mic's.
        #expect(own([Float](repeating: -20, count: 33) + [Float](repeating: -60, count: 67)))
        #expect(!own(nil, voiced: [Bool](repeating: false, count: 100)), "no voice on the mic")
        // The other side's track over before the phrase: silence there.
        #expect(own([Float](repeating: -20, count: 10)))
    }

    /// The model hears only the mic's speech: each run of it with half a second either side, runs 2 s apart or less in
    /// one piece, and further apart too while they fit in the model's 15 s; none longer than two minutes, a long one
    /// cut in its longest pause near that, else where it's quietest.
    @Test func piecesAreTheMicsSpeechCutWherePaused() {
        var voiced = [Bool](repeating: false, count: 30_100)
        for range in [100..<300, 400..<600, 1000..<1100, 2000..<2100, 3000..<14_500, 14_600..<30_000] {
            for frame in range { voiced[frame] = true }
        }
        var levels = voiced.map { $0 ? Float(-20) : -60 }
        levels[26_000] = -40
        #expect(CallMicHint.pieces(voiced: voiced, levels: levels)
                == [50..<1150, 1950..<2150, 2950..<14_550, 14_550..<26_000, 26_000..<30_050])
        let quiet = CallMicHint.pieces(voiced: [Bool](repeating: false, count: 1000),
                                       levels: [Float](repeating: -60, count: 1000))
        #expect(quiet.isEmpty)
    }

    /// The person's mic heard by the local model: each chunk's prompt has the phrases in its stretch, times from its
    /// own start, in place of "may not speak"; no sample of their voice goes, so each request has one audio again.
    /// The answer's times stay the chunk's. Logged with counts, never the words.
    @Test func theHintGoesInEachChunksPromptInsteadOfTheSample() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let mic = track(40, speech: [(2, 5), (24, 5)])
        let remote = track(40, speech: [(9, 8), (31, 7)], noise: false)
        let gemini = Gemini { index in "[00:02-00:06] Sam: Привет (\(index))\n[00:09-00:12] Аня: Да" }
        let parakeet = FakeParakeet()
        let id = UUID()
        let outcome = try await CallTranscriber.run(
            plan(mic: mic, remote: remote, callID: id), maxChunkSeconds: 20,
            send: { try await gemini.send($0, $1, $2, $3) }, mic: parakeet.listener,
            read: reader(mic: mic, remote: remote), log: log)

        #expect(gemini.samples == [nil, nil], "no sample of their voice")
        #expect(outcome.sampleSeconds == nil && outcome.micPhrases == 2)
        #expect(parakeet.heard.withLock { $0.count } == 2, "the mic's two stretches of speech, nothing else")
        #expect(parakeet.done.withLock { $0 } == 1)
        let prompts = gemini.prompts
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("<mic>\n[00:02-00:07] фраза 1\n</mic>"))
        #expect(prompts[1].contains("<mic>\n[00:04-00:09] фраза 2\n</mic>"), "times from the second chunk's start")
        for prompt in prompts {
            #expect(prompt.hasPrefix("This audio is a recording of a call on Zoom"))
            #expect(prompt.contains("Sam's own microphone, recorded apart from the call, picked up these phrases from "
                                    + "them (times are MM:SS from the start of this audio)."))
            #expect(prompt.contains("a voice talking at these times, saying roughly this, is Sam; a voice talking at "
                                    + "other times is someone else."))
            #expect(!prompt.contains("may not speak at all") && !prompt.contains("two audios"))
        }
        #expect(outcome.transcript.segments.filter { $0.speaker == "Sam" }.map(\.start) == [2, 22])

        log.flush()
        let text = log.retainedText()
        #expect(text.contains("[calls] transcription.micHint call=\(CallTranscriber.shortID(id)) phrases=2 "
                              + "droppedAsEcho=0 words=2 pieces=2 heard="))
        #expect(text.contains("micPhrases=2"))
        #expect(!text.contains("фраза"), "never the words")
    }

    /// The other side coming back through the speakers into the mic, quieter than it went out: Parakeet hears it, and
    /// it's left out.
    @Test func theOtherSidesEchoOnTheMicIsLeftOut() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let remote = track(30, speech: [(18, 5)], noise: false)
        var mic = track(30, speech: [(2, 5)])
        for index in Int(18 * rate)..<Int(23 * rate) { mic[index] += 0.3 * remote[index] }
        let gemini = Gemini()
        let parakeet = FakeParakeet()
        let outcome = try await CallTranscriber.run(
            plan(mic: mic, remote: remote, callID: UUID()), send: { try await gemini.send($0, $1, $2, $3) },
            mic: parakeet.listener, read: reader(mic: [Float](mic), remote: remote), log: log)
        #expect(parakeet.heard.withLock { $0.count } == 2, "the model heard both")
        let prompt = try #require(gemini.prompts.first)
        #expect(prompt.contains("<mic>\n[00:02-00:07] фраза 1\n</mic>") && !prompt.contains("фраза 2"))
        #expect(outcome.micPhrases == 1 && gemini.samples == [nil])
        log.flush()
        #expect(log.retainedText().contains("phrases=1 droppedAsEcho=1 words=2 pieces=2"))
    }

    /// A mic that heard nothing of the person says so: no voice is theirs, in the whole recording for a call of one
    /// chunk, in this part of it for one of several. A call muted all through says both. No sample goes either way.
    @Test func aSilentMicSaysNoVoiceIsTheirs() async throws {
        let remote = track(40, speech: [(8, 10), (21, 15)], noise: false)
        let quiet = track(20, speech: [])
        let parakeet = FakeParakeet()
        let gemini = Gemini()
        let one = try await CallTranscriber.run(
            plan(mic: quiet, remote: Array(remote.prefix(quiet.count))),
            send: { try await gemini.send($0, $1, $2, $3) },
            mic: parakeet.listener, read: reader(mic: quiet, remote: remote))
        #expect(parakeet.heard.withLock { $0.isEmpty } && parakeet.done.withLock { $0 } == 1)
        let whole = try #require(gemini.prompts.first)
        #expect(whole.contains("Sam's own microphone, recorded apart from the call, heard no speech from them in this "
                               + "whole recording: they only listened or were muted. No voice in it is Sam."))
        #expect(!whole.contains("<mic>") && !whole.contains("may not speak at all"))
        #expect(one.micPhrases == 0 && gemini.samples == [nil])

        // Two chunks, the person speaking in the first only.
        let mic = track(40, speech: [(2, 5)])
        let parts = Gemini()
        _ = try await CallTranscriber.run(plan(mic: mic, remote: remote), maxChunkSeconds: 20,
                                          send: { try await parts.send($0, $1, $2, $3) },
                                          mic: FakeParakeet().listener, read: reader(mic: mic, remote: remote))
        let prompts = parts.prompts
        #expect(prompts.count == 2 && prompts[0].contains("<mic>\n[00:02-00:07] фраза 1\n</mic>"))
        #expect(prompts[1].contains("Sam's own microphone, recorded apart from the call, heard no speech from them in "
                                    + "this part of the call: they only listened or were muted. No voice in it is "
                                    + "Sam."))
        #expect(parts.samples == [nil, nil])

        // Muted all through: the mic is silent in the mix and to the model.
        let muted = Gemini()
        let speaking = track(20, speech: [(2, 15)])
        let silenced = FakeParakeet()
        _ = try await CallTranscriber.run(plan(mic: speaking, remote: Array(remote.prefix(speaking.count)),
                                               mutes: [CallInterval(start: 0, end: 20)]),
                                          send: { try await muted.send($0, $1, $2, $3) }, mic: silenced.listener,
                                          read: reader(mic: speaking, remote: remote))
        let prompt = try #require(muted.prompts.first)
        #expect(silenced.heard.withLock { $0.isEmpty })
        #expect(prompt.contains("heard no speech from them in this whole recording"))
        #expect(prompt.contains("Sam was muted for the whole call: no voice in it is Sam."))
    }

    /// Past the end of the mic's track nothing is known of the person: a chunk there gets neither the hint nor a
    /// sample, only "may not speak".
    @Test func aChunkPastTheMicsEndGetsNoHint() async throws {
        let mic = track(12, speech: [(2, 5)])
        let remote = track(30, speech: [(15, 10)], noise: false)
        let gemini = Gemini()
        _ = try await CallTranscriber.run(plan(mic: mic, remote: remote), maxChunkSeconds: 10,
                                          send: { try await gemini.send($0, $1, $2, $3) },
                                          mic: FakeParakeet().listener, read: reader(mic: mic, remote: remote))
        let prompts = gemini.prompts
        #expect(prompts.count == 3)
        #expect(prompts[0].contains("<mic>\n[00:02-00:07] фраза 1\n</mic>"))
        for prompt in prompts.dropFirst() {
            #expect(prompt.contains("Sam may not speak at all in this call") && !prompt.contains("recorded apart"))
        }
        #expect(gemini.samples == [nil, nil, nil])
    }

    /// Without the model (it failed here, or isn't downloaded), the sample of the person's voice goes as before, and
    /// the failure is logged, never what was said.
    @Test func withoutTheModelTheSampleGoesAsBefore() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let mic = track(40, speech: [(2, 5), (24, 5)])
        let remote = track(40, speech: [(9, 8), (31, 7)], noise: false)
        let gemini = Gemini()
        let parakeet = FakeParakeet(failing: .modelNotDownloaded(.parakeet))
        let outcome = try await CallTranscriber.run(
            plan(mic: mic, remote: remote, callID: UUID()), maxChunkSeconds: 20,
            send: { try await gemini.send($0, $1, $2, $3) }, mic: parakeet.listener,
            read: reader(mic: mic, remote: remote), log: log)
        let samples = gemini.samples
        #expect(samples.count == 2 && samples[0] != nil && samples[1] == samples[0])
        #expect(outcome.sampleSeconds != nil && outcome.micPhrases == nil)
        #expect(parakeet.done.withLock { $0 } == 1)
        for prompt in gemini.prompts {
            #expect(prompt.hasPrefix(CallPrompts.voiceSampleParagraph(me: "Sam")))
            #expect(prompt.contains("Name a voice Sam only when it matches the sample or the conversation makes it "
                                    + "clear"))
            #expect(!prompt.contains("<mic>"))
        }
        log.flush()
        #expect(log.retainedText().range(
            of: #"transcription\.micHint call=\w+ error=modelNotDownloaded\.parakeet seconds=[\d.]+ fallback=sample"#,
            options: .regularExpression) != nil)
    }

    /// A request for what an answer left out carries the mic's phrases of its own stretch, times from its audio's
    /// start, and no sample.
    @Test func theRestOfAChunkIsAskedForWithItsStretchsHint() async throws {
        let mic = track(200, speech: [(30, 5), (150, 5)])
        let remote = track(200, speech: [(0, 28), (37, 111), (157, 43)], noise: false)
        let gemini = Gemini { index in
            index == 1 ? "[00:01-00:05] Аня: Привет.\n[00:30-00:35] Sam: Да.\n[00:40-00:50] Аня: Давай обсудим."
                : "NO SPEECH"
        }
        let outcome = try await CallTranscriber.run(plan(mic: mic, remote: remote),
                                                    send: { try await gemini.send($0, $1, $2, $3) },
                                                    mic: FakeParakeet().listener,
                                                    read: reader(mic: mic, remote: remote))
        let requests = gemini.requests.withLock { $0 }
        #expect(requests.count == 2 && outcome.resumed == 1)
        #expect(abs(requests[1].seconds - 155) < 0.01, "from 0:45 to the end")
        #expect(requests.allSatisfy { $0.sample == nil })
        #expect(requests[0].prompt.contains("<mic>\n[00:30-00:35] фраза 1\n[02:30-02:35] фраза 2\n</mic>"))
        #expect(requests[1].prompt.contains("<mic>\n[01:45-01:50] фраза 2\n</mic>"))
        #expect(!requests[1].prompt.contains("фраза 1"))
    }

    /// A call made from a file has no mic of its own: nothing is heard, no hint, no sample, the file's prompt.
    @Test func aFilesCallIsUnchanged() async throws {
        let audio = track(20, speech: [(1, 15)])
        let gemini = Gemini()
        let parakeet = FakeParakeet()
        let plan = CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: nil,
                                        remoteSamples: audio.count, micSamples: 0, mutes: [], userName: "Sam",
                                        service: nil, file: "Interview.m4a")
        _ = try await CallTranscriber.run(plan, send: { try await gemini.send($0, $1, $2, $3) }, mic: parakeet.listener,
                                          read: { _, range in Array(audio[range]) })
        #expect(parakeet.heard.withLock { $0.isEmpty } && parakeet.done.withLock { $0 } == 0)
        let prompt = try #require(gemini.prompts.first)
        #expect(prompt.hasPrefix("This audio is a recording from the file \"Interview.m4a\""))
        #expect(!prompt.contains("<mic>") && !prompt.contains("microphone, recorded apart"))
        #expect(gemini.samples == [nil])
    }

    /// The prompts with the mic's hint, word for word (`LiveCallPromptText`); without it, as before.
    @Test func thePromptsWithTheMicAreWordForWord() {
        let phrases = [CallMicHint.Phrase(start: 20.4, end: 26.3, text: "Да так просто получилось."),
                       CallMicHint.Phrase(start: 65.5, end: 69.2, text: "Ну давай.")]
        #expect(CallPrompts.call(me: "Sam", service: "Zoom", roster: [], mutes: [], seconds: 600, micHint: phrases)
                == LiveCallPromptText.callMicHint)
        #expect(CallPrompts.call(me: "Me", service: nil, roster: ["Participant 1"],
                                 mutes: [CallInterval(start: 65, end: 72.5)], seconds: 600, micHint: [],
                                 wholeCall: false) == LiveCallPromptText.callMicSilent)
        #expect(CallPrompts.call(me: "Sam", service: "Zoom", roster: [], mutes: [], summary: true)
                == LiveCallPromptText.callNamed)
    }

    /// The hint for a request's stretch: the phrases that overlap it, cut to it, times from its start; nil past the
    /// mic's end (a few seconds' slack: the tracks rarely end together).
    @Test func eachRequestGetsThePhrasesOfItsStretch() {
        let hint = CallMicHint.Hint(phrases: [.init(start: 5, end: 8, text: "a"), .init(start: 18, end: 23, text: "b"),
                                              .init(start: 40, end: 44, text: "c")], micSeconds: 50)
        #expect(hint.phrases(from: 0, seconds: 20) == [.init(start: 5, end: 8, text: "a"),
                                                        .init(start: 18, end: 20, text: "b")])
        #expect(hint.phrases(from: 20, seconds: 20) == [.init(start: 0, end: 3, text: "b")])
        #expect(hint.phrases(from: 30, seconds: 25) == [.init(start: 10, end: 14, text: "c")], "within the slack")
        #expect(hint.phrases(from: 40, seconds: 20) == nil, "past the mic's end")
    }
}

/// The live listener: Parakeet through `ModelStore`, loaded for a call's mic when it isn't, and let go after unless a
/// model Switch model reaches uses it.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CallMicListenerTests {
    private func store(usedByLineup: Bool, installed: Bool = true) -> (ModelStore, FakeEngine) {
        let settings = AppSettings.inMemory()
        if !usedByLineup {
            settings.lineup.main = .gemini
            settings.lineup.setSwitchable(.parakeet, false)
        }
        let engine = FakeEngine(.parakeet, installed: installed, transcript: "слово")
        let store = ModelStore(paths: .temporary(), settings: settings, engines: [.parakeet: engine],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        return (store, engine)
    }

    @Test func theModelHearsTheMicAndIsLetGoWhenNothingElseUsesIt() async throws {
        let (store, engine) = store(usedByLineup: false)
        let listener = CallTranscriber.localParakeet(models: store)
        await store.refreshFromDisk()
        #expect(listener.isAvailable())
        let words = try await listener.words([Float](repeating: 0, count: 16_000))
        #expect(words == [TimedWord(text: "слово", start: 0, end: 1)])
        #expect(store.state(of: .parakeet) == .ready)
        await listener.done()
        #expect(store.state(of: .parakeet) == .installed)
        #expect(!(await engine.isLoaded))

        // Dictation uses it: it stays loaded.
        let (used, usedEngine) = self.store(usedByLineup: true)
        let kept = CallTranscriber.localParakeet(models: used)
        await used.refreshFromDisk()
        _ = try await kept.words([Float](repeating: 0, count: 16_000))
        await kept.done()
        #expect(used.state(of: .parakeet) == .ready)
        #expect(await usedEngine.isLoaded)

        // Not downloaded: the call takes the sample instead.
        let (missing, _) = self.store(usedByLineup: false, installed: false)
        await missing.refreshFromDisk()
        #expect(!CallTranscriber.localParakeet(models: missing).isAvailable())
    }

    /// The listener isn't used when it says the model isn't there: the call's requests carry the sample.
    @Test func aCallTakesTheSampleWhenTheModelIsntThere() async throws {
        let calls = CallStore(paths: .temporary(), settings: .inMemory())
        calls.load()
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Zoom", service: .zoom, status: .done)
        call.micFile = "mic.m4a"
        call.micSeconds = 20
        call.remoteFile = "remote.m4a"
        call.remoteSeconds = 20
        calls.upsert(call)
        let mic = track(20, speech: [(1, 4), (10, 5)])
        let remote = track(20, speech: [(6, 3), (16, 3)], noise: false)
        let gemini = Gemini()
        let heard = OSAllocatedUnfairLock(initialState: 0)
        let available = OSAllocatedUnfairLock(initialState: false)
        let transcriber = CallTranscriber(store: calls) { try await gemini.send($0, $1, $2, $3) }
        transcriber.userName = { "Sam" }
        transcriber.read = reader(mic: mic, remote: remote)
        transcriber.micListener = CallTranscriber.MicListener(
            isAvailable: { available.withLock { $0 } },
            words: { _ in
                heard.withLock { $0 += 1 }
                return [TimedWord(text: "да", start: 0.5, end: 1)]
            })
        transcriber.transcribe(call.id)
        await transcriber.waitUntilIdle()
        #expect(heard.withLock { $0 } == 0)
        #expect(gemini.samples.count == 1 && gemini.samples[0] != nil)
        #expect(calls.call(id: call.id)?.status == .done)

        available.withLock { $0 = true }
        transcriber.retranscribe(call.id)
        await transcriber.waitUntilIdle()
        #expect(heard.withLock { $0 } == 1, "the mic's two bits of speech, close enough for one pass of the model")
        #expect(gemini.samples.count == 2 && gemini.samples[1] == nil)
        #expect(gemini.prompts[1].contains("<mic>\n"))
    }
}

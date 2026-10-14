import Foundation
import os
import Testing
@testable import TranscribeThing

// Audio and video dropped on Calls: each file becomes a call record of its own (`CallStore.addImported`), transcribed
// at once whatever Record calls says (`CallTranscriber.importFile`), with a prompt for a recording of anything
// (`CallPrompts.file`); what couldn't be read is said (`CallImport`). No real request: Gemini is a fake.

/// `seconds` of speech-like sound, as a file's sound reads.
private func fileAudio(_ name: String, seconds: Double = 6, url: URL? = nil, isVideo: Bool = false) -> ImportedAudio {
    let samples = ImportedAudioTests.speechLike(seconds: seconds, rate: Recording.sampleRate)
    return ImportedAudio(fileName: name, samples: samples, speech: SpeechAnalyzer.stats(for: samples), url: url,
                         isVideo: isVideo)
}

/// An empty file named `name` in a folder of its own, made at `created`.
private func fileOnDisk(_ name: String, created: Date) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("call-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data([0]).write(to: url)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
    return url
}

@MainActor @Suite(.serialized) struct CallImportRecordTests {
    /// A video's sound is kept in the call's folder as its one track; the video itself stays where it was, its path
    /// and that it's a video kept for a later look at its picture. The call starts when the file was made.
    @Test func aFileBecomesACallWithItsSoundAndWhereItCameFrom() async throws {
        let paths = AppPaths.temporary()
        let store = CallStore(paths: paths, settings: .inMemory())
        store.load()
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let url = try fileOnDisk("Interview.mp4", created: created)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let record = try #require(await store.addImported(fileAudio("Interview.mp4", url: url, isVideo: true), now: now))
        #expect(record.file == CallFileSource(name: "Interview.mp4", path: url.standardizedFileURL.path, isVideo: true,
                                              importedAt: now))
        #expect(record.isImported && record.status == .transcribing)
        #expect(record.startedAt == created && record.endedAt == created.addingTimeInterval(record.duration))
        #expect(record.title == "Interview.mp4" && record.bundleID == nil && !record.manual)
        // One mixed track, kept as the other side's: no mic to take the person's voice from.
        #expect(record.micFile == nil && record.remoteFile == CallStore.importedAudioFile)
        #expect(abs(record.duration - 6) < 0.05)
        let audio = try #require(store.audioURL(of: record, track: .remote))
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(abs(Double(try CallAudio.read(audio, range: 0..<16_000).count) - 16_000) < 1)
        // Only the sound is kept: no copy of the video in the call's folder.
        let kept = try FileManager.default.contentsOfDirectory(atPath: store.folder(for: record.id).path)
        #expect(kept == [CallStore.importedAudioFile])

        // Saved: a new store reads it back as it was.
        let reread = CallStore(paths: paths, settings: .inMemory())
        reread.load()
        let back = try #require(reread.call(id: record.id))
        #expect(back.file == record.file && back.remoteSeconds == record.remoteSeconds)
    }

    /// No file to ask (a test's, or one gone): the call starts now.
    @Test func withoutACreationDateTheCallStartsNow() async throws {
        let store = CallStore(paths: .temporary(), settings: .inMemory())
        store.load()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try #require(await store.addImported(fileAudio("memo.m4a"), now: now))
        #expect(record.startedAt == now && record.file?.isVideo == false && record.file?.path == "")
    }

    /// Auto-delete counts from when a file came in, not from its creation date: an old recording dropped today stays.
    @Test func autoDeleteCountsFromWhenAFileCameIn() {
        let settings = AppSettings.inMemory()
        settings.autoDeleteHistoryDays = 30
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-90 * 86_400)
        var dropped = CallRecord(id: UUID(), startedAt: old, appName: "Lecture.m4a", status: .done)
        dropped.file = CallFileSource(name: "Lecture.m4a", path: "/x/Lecture.m4a", isVideo: false,
                                      importedAt: now.addingTimeInterval(-86_400))
        var droppedLongAgo = dropped
        droppedLongAgo.id = UUID()
        droppedLongAgo.file?.importedAt = old
        let recorded = CallRecord(id: UUID(), startedAt: old, appName: "Zoom", status: .done)
        let store = CallStore.preview(calls: [dropped, droppedLongAgo, recorded], settings: settings)
        store.deleteExpired(now: now)
        #expect(store.calls.map(\.id) == [dropped.id])
    }

    /// A record written by a build before files has none; one with a file keeps it through a save.
    @Test func theFileIsReadLeniently() throws {
        let old = #"{"version":1,"calls":[{"id":"00000000-0000-4000-8000-000000000001","#
            + #""startedAt":"2026-10-01T10:00:00Z","appName":"Zoom","status":"done"}]}"#
        #expect(try CallStore.readRecords(from: Data(old.utf8)).first?.file == nil)

        var call = CallRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_790_000_000), appName: "a.mov",
                              status: .done)
        call.file = CallFileSource(name: "a.mov", path: "/Users/x/a.mov", isVideo: true,
                                   importedAt: Date(timeIntervalSince1970: 1_790_000_100))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(CallRecord.self, from: encoder.encode(call)) == call)
    }
}

@MainActor @Suite(.serialized) struct CallImportTranscriptionTests {
    /// What a fake Gemini was sent.
    private final class Sent: Sendable {
        let prompts = OSAllocatedUnfairLock(initialState: [String]())
        let samples = OSAllocatedUnfairLock(initialState: [Data?]())
    }

    /// A dropped file is transcribed at once whether Record calls is Off, Ask First or Automatically: the person asked
    /// for this one. It goes without a voice sample, its prompt names the file, and a phrase without a speaker is
    /// "Speaker 1".
    @Test(arguments: [CallRecordingMode.off, .ask, .automatic])
    func aDroppedFileIsTranscribedWhateverTheMode(_ mode: CallRecordingMode) async throws {
        let settings = AppSettings.inMemory()
        settings.callRecording = mode
        let store = CallStore(paths: .temporary(), settings: settings)
        store.load()
        let sent = Sent()
        let transcriber = CallTranscriber(store: store) { _, prompt, _, sample in
            sent.prompts.withLock { $0.append(prompt) }
            sent.samples.withLock { $0.append(sample) }
            return CloudResult(text: "[00:01-00:02] Привет всем.\n[00:03-00:04] Sam: Hi.", costUSD: 0.002)
        }
        transcriber.userName = { "Sam" }

        let record = try #require(await transcriber.importFile(fileAudio("Standup.mp4", isVideo: true)))
        #expect(store.call(id: record.id)?.status == .transcribing)
        await transcriber.waitUntilIdle()
        let done = try #require(store.call(id: record.id))
        #expect(done.status == .done && done.costUSD == 0.002)
        #expect(done.transcript?.segments.map(\.speaker) == [CallPrompts.firstSpeaker, "Sam"])
        let prompt = try #require(sent.prompts.withLock { $0 }.first)
        #expect(prompt.contains("This audio is a recording from the file \"Standup.mp4\""))
        #expect(!prompt.contains("sample") && !prompt.contains("muted"))
        #expect(sent.samples.withLock { $0 } == [nil])
    }

    /// The prompt for a file: a recording of anything, the person maybe not in it, unnamed voices "Speaker 1, 2...",
    /// the same format and summary blocks as a call's with their style rules, said of a recording.
    @Test func theFilePromptAsksAboutARecordingOfAnything() {
        let prompt = CallPrompts.file(name: "Lecture 4.m4a", me: "Sam", roster: ["Олег", "Speaker 1"], summary: true)
        #expect(prompt.hasPrefix("This audio is a recording from the file \"Lecture 4.m4a\". It may be a call, an "
                                 + "interview, a meeting, a lecture"))
        #expect(prompt.contains("The person who asked for this transcript is Sam."))
        #expect(prompt.contains("They may be one of the speakers, or not be in it at all. Name a voice Sam only when "
                                + "the conversation makes it clear it's them"))
        #expect(prompt.contains("\"Speaker 1\", \"Speaker 2\" and so on"))
        #expect(prompt.contains("Earlier in this recording these speakers were heard: Олег, Speaker 1."))
        #expect(prompt.contains("for example: [01:05-01:12] Speaker 1: Да, слышу тебя хорошо."))
        #expect(prompt.contains("Sum up the recording in these five blocks"))
        #expect(prompt.contains("named exactly as in the transcript (\"Sam\", \"Speaker 1\")"))
        #expect(prompt.contains("Use straight quotes \"like this\"") && prompt.contains("never a long dash"))
        #expect(!prompt.contains("Participant") && !prompt.contains("the call") && !prompt.contains("muted"))

        let unnamed = CallPrompts.file(name: "a.mp3", me: "Me", roster: [])
        #expect(unnamed.contains("Call the person who asked for this transcript \"Me\"."))
        #expect(unnamed.contains("Name a voice \"Me\" only when the conversation makes it clear it's them;"))
        #expect(unnamed.hasSuffix(CallPrompts.format(summary: false, subject: "recording", firstSpeaker: "Speaker 1")))
        #expect(!unnamed.contains("<summary>"))
    }

    /// A live call's prompts are word for word what they were before files could become calls (`LiveCallPromptText`).
    @Test func aCallsPromptIsUnchanged() {
        #expect(CallPrompts.call(me: "Sam", service: "Zoom", roster: [], mutes: [], summary: true)
                == LiveCallPromptText.callNamed)
        #expect(CallPrompts.call(me: "Me", service: nil, roster: ["Олег", "Participant 1"], local: ["Sam"],
                                 mutes: [CallInterval(start: 65, end: 72.5)], seconds: 600, voiceSample: true,
                                 summary: false) == LiveCallPromptText.callUnnamed)
        #expect(CallSummaryPrompt.text(me: "Sam", service: "Zoom") == LiveCallPromptText.summaryNamed)
        #expect(CallSummaryPrompt.text(me: "Me", service: nil) == LiveCallPromptText.summaryUnnamed)
    }

    /// A long file's summary comes from its transcript, asked about as a recording, not as Sam's call.
    @Test func aFilesSummaryIsAskedAboutARecording() {
        let prompt = CallSummaryPrompt.text(me: "Sam", file: "Lecture 4.m4a")
        #expect(prompt.contains("the transcript of a recording from the file \"Lecture 4.m4a\""))
        #expect(prompt.contains("Sam may not be one of the speakers at all"))
        #expect(prompt.contains("Sum up the recording") && !prompt.contains("recorded it"))
    }
}

@MainActor @Suite(.serialized) struct CallImportFlowTests {
    private final class Made {
        var files: [String] = []
        var opened: [[UUID]] = []
    }

    /// Each file reads in a moment; a ".txt" isn't audio, a ".wav" is silent, a ".full" can't be saved.
    private static func make() -> (CallImport, Made) {
        let imports = CallImport()
        let made = Made()
        imports.settle = .zero
        imports.read = { url async throws(ImportedAudio.ReadError) -> ImportedAudio in
            try? await Task.sleep(for: .milliseconds(10))
            switch url.pathExtension {
            case "txt": throw .unreadable
            case "wav": throw .silent
            default: return fileAudio(url.lastPathComponent, seconds: 1)
            }
        }
        imports.start = { file in
            guard !file.fileName.hasSuffix(".full") else { return nil }
            made.files.append(file.fileName)
            return UUID()
        }
        imports.onImported = { made.opened.append($0) }
        return (imports, made)
    }

    private static func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    /// Several files at once: each its own call, read one after another, the bar naming the one being read.
    @Test func eachFileBecomesACallOfItsOwn() async throws {
        let (imports, made) = Self.make()
        imports.add([Self.url("one.mp4"), Self.url("two.m4a")])
        imports.add([Self.url("three.mov")])
        #expect(imports.reading == ["one.mp4", "two.m4a", "three.mov"])
        await imports.waitUntilRead()
        #expect(made.files == ["one.mp4", "two.m4a", "three.mov"])
        #expect(made.opened.map(\.count) == [3] && imports.reading.isEmpty)
        #expect(imports.problem == nil && !imports.showsProblem)
    }

    /// Files that can't be read are said the way Home says them, one alert for the batch; the rest become calls.
    @Test func filesThatCantBeReadAreSaid() async throws {
        let (imports, made) = Self.make()
        imports.add([Self.url("notes.txt"), Self.url("talk.mp3"), Self.url("quiet.wav")])
        await imports.waitUntilRead()
        #expect(made.files == ["talk.mp3"])
        #expect(imports.showsProblem)
        #expect(imports.problem == FileImport.Problem(title: "Can’t transcribe “notes.txt” (and 1 more)",
                                                      message: ImportedAudio.ReadError.unreadable.message))
        imports.problemDismissed()
        #expect(imports.problem == nil && !imports.showsProblem)
    }

    /// A file read whose sound couldn't be kept says so, and no call is opened.
    @Test func aFileThatCantBeSavedIsSaid() async throws {
        let (imports, made) = Self.make()
        imports.add([Self.url("big.full")])
        await imports.waitUntilRead()
        #expect(made.files.isEmpty && made.opened.isEmpty)
        #expect(imports.problem == FileImport.Problem(title: "Can’t transcribe “big.full”",
                                                      message: CallImport.unsavedMessage))
    }

    /// A second batch's problem waits for the first's alert to go.
    @Test func problemsComeOneAfterAnother() async throws {
        let (imports, _) = Self.make()
        imports.add([Self.url("a.txt")])
        await imports.waitUntilRead()
        imports.add([Self.url("b.wav")])
        await imports.waitUntilRead()
        #expect(imports.problem?.title == "Can’t transcribe “a.txt”")
        imports.problemDismissed()
        try await waitUntil { imports.showsProblem }
        #expect(imports.problem == FileImport.Problem(title: "Can’t transcribe “b.wav”",
                                                      message: ImportedAudio.ReadError.silent.message))
    }
}

@MainActor @Suite struct CallImportFormatTests {
    /// A call made from a file is named by the file, says where it was, has no notes about mutes, and is found by its
    /// name.
    @Test func aFilesCallReadsAsTheFile() {
        let calls = PreviewFixtures.importedCalls()
        let video = calls[0], audio = calls[1]
        #expect(CallFormat.title(video) == "Design review.mov" && CallFormat.shortTitle(video) == "Design review.mov")
        #expect(CallFormat.place(video) == "From a video in ~/Movies")
        #expect(CallFormat.place(audio) == "From an audio file in ~/Downloads")
        #expect(CallFormat.notes(video).isEmpty && CallFormat.problems(video).isEmpty)
        #expect(CallsList.filter(calls + PreviewFixtures.calls(), query: "lecture").map(\.id) == [audio.id])
    }
}

#if DEBUG
@MainActor @Suite(.serialized) struct CallImportHubTests {
    /// The Hub window closed while a file was still read: the call is made all the same, and nothing is opened.
    @Test func aFileReadAfterTheWindowClosedStillBecomesACall() async throws {
        let env = AppEnvironment.preview()
        var context: HubContext? = HubContext(env: env)
        weak let gone = context
        let imports = try #require(context?.callImports)
        let made = OSAllocatedUnfairLock(initialState: [String]())
        imports.read = { url async throws(ImportedAudio.ReadError) -> ImportedAudio in
            try? await Task.sleep(for: .milliseconds(50))
            return fileAudio(url.lastPathComponent, seconds: 1)
        }
        imports.start = { file in
            made.withLock { $0.append(file.fileName) }
            return UUID()
        }
        env.windows.hubSection = .calls
        imports.add([URL(fileURLWithPath: "/tmp/Interview.mp4")])
        context = nil
        #expect(gone == nil)
        await imports.waitUntilRead()
        #expect(made.withLock { $0 } == ["Interview.mp4"])
        #expect(env.windows.openCallID == nil && env.windows.hubSection == .calls)
    }

    /// Several files dropped at once: the first opens on its page, so the batch is seen wherever its dates put it.
    @Test func aBatchOpensItsFirstCall() {
        let env = AppEnvironment.preview()
        let context = HubContext(env: env)
        let first = UUID(), second = UUID()
        env.windows.hubSection = .general
        context.callsImported([first, second])
        #expect(env.windows.openCallID == nil && env.windows.hubSection == .general)
        env.windows.hubSection = .calls
        context.callsImported([first, second])
        #expect(env.windows.openCallID == first && env.windows.hubSection == .callDetail)
    }

    /// Deleting a call made from a file says the file itself stays; a recorded call's alert is as it was.
    @Test func deletingAFilesCallSaysTheFileStays() throws {
        let video = try #require(PreviewFixtures.importedCalls().first)
        #expect(CallDeleteAlert.message(for: video)
                == "Its transcript and the sound kept with it go too. “Design review.mov” stays where it is. "
                + "This can’t be undone.")
        let recorded = try #require(PreviewFixtures.calls().first { $0.file == nil })
        #expect(CallDeleteAlert.message(for: recorded) == "Its recording and transcript go too. This can’t be undone.")
    }
}
#endif

import Foundation
import Testing
@testable import TranscribeThing

// GigaAM, a second model on this Mac next to Parakeet, in three versions: CTC greedy decoding and where a long
// recording is cut, its engine, choice and versions, each version's install from its own zip (never the real ones,
// never the real Downloads folder), the version picked and what it loads and unloads, the lineup and Pasting rules it
// joins, which models on this Mac launch loads and in what order, fallbacks with two models on this Mac, its copy and
// History's names, and the CLI. The model itself runs only on a real install (`--batch`, the app).

@Suite struct GigaAMDecodingTests {
    private let vocabulary = [" ", "а", "б", "в"]
    private let blank = 4

    @Test func repeatsCollapseAndBlanksSeparateThem() {
        // а а _ а б _ _ " " в в: the first two а are one, the blank lets the third through.
        let ids = [1, 1, 4, 1, 2, 4, 4, 0, 3, 3]
        #expect(GigaAMEngine.decode(ids, vocabulary: vocabulary, blank: blank) == "ааб в")
    }

    @Test func piecesJoinWithTheirSpaceMarks() {
        // GigaAM v3 e2e's SentencePiece pieces: "▁" starts a word, "<unk>" is dropped.
        let pieces = ["<unk>", "▁", "▁При", "вет", ",", "▁мир", "!"]
        let ids = [2, 3, 3, 7, 4, 0, 7, 5, 6]
        #expect(GigaAMEngine.decode(ids, vocabulary: pieces, blank: 7, pieces: true) == "Привет, мир!")
    }

    @Test func spacesAreTrimmedAndNeverDoubled() {
        #expect(GigaAMEngine.decode([0, 1, 4, 0, 0, 4, 0, 2, 0], vocabulary: vocabulary, blank: blank) == "а б")
        #expect(GigaAMEngine.decode([4, 4, 4], vocabulary: vocabulary, blank: blank) == "")
    }
}

@Suite struct GigaAMChunkerTests {
    private let rate = GigaAMChunker.sampleRate

    @Test func aShortRecordingIsOneStretch() {
        let samples = [Float](repeating: 0.1, count: rate * 7)
        #expect(GigaAMChunker.split(samples, maxLength: rate * 25) == [0..<samples.count])
        #expect(GigaAMChunker.split([], maxLength: rate * 25).isEmpty)
    }

    @Test func aLongRecordingIsCutInItsPause() {
        // 40 s of "speech" with a 300 ms pause at 19 s: the cut lands inside it, and nothing is lost or repeated.
        var samples = [Float](repeating: 0.2, count: rate * 40)
        for i in (rate * 19)..<(rate * 19 + rate * 3 / 10) { samples[i] = 0 }
        let ranges = GigaAMChunker.split(samples, maxLength: rate * 25)
        #expect(ranges.count == 2)
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == samples.count)
        #expect(ranges[0].upperBound == ranges[1].lowerBound)
        let cut = ranges[0].upperBound
        #expect(cut >= rate * 19 && cut <= rate * 19 + rate * 3 / 10, "cut at \(Double(cut) / Double(rate)) s")
    }

    @Test func withNoPauseEveryStretchStillFits() {
        let samples = [Float](repeating: 0.2, count: rate * 90)
        let ranges = GigaAMChunker.split(samples, maxLength: rate * 25)
        #expect(ranges.allSatisfy { $0.count <= rate * 25 })
        #expect(ranges.reduce(0) { $0 + $1.count } == samples.count)
    }
}

// MARK: - Engine, choice and versions

@Suite struct GigaAMModelTests {
    @Test func gigaamIsOneLocalModelInThreeVersions() {
        #expect(EngineID.gigaam.rawValue == "gigaam" && ModelChoice.gigaam.rawValue == "gigaam")
        #expect(EngineID.localEngines == [.parakeet, .gigaam], "Parakeet first")
        let gigaam = EngineID.gigaam
        #expect(gigaam.isLocal && !gigaam.isCloud && !gigaam.isGemini && !gigaam.isRetired)
        #expect(gigaam.modelName == "GigaAM" && gigaam.displayName == "GigaAM" && gigaam.shortName == "GigaAM")
        #expect(gigaam.providerLine == "Sber · on your Mac")
        #expect(gigaam.badges == ["Private", "Offline"], "Parakeet's, without Recommended")
        #expect(gigaam.glyph == "G" && gigaam.symbolName != EngineID.parakeet.symbolName)
        #expect(gigaam.approxDownloadBytes == nil, "each version's own")
        #expect(gigaam.provider == nil && gigaam.openRouterModelID == nil && gigaam.cloudTimeout == 0)
        #expect(gigaam.reasoningEfforts.isEmpty && gigaam.defaultReasoningEffort == nil)
        let choice = ModelChoice.gigaam
        #expect(choice.modelName == "GigaAM" && choice.shortName == "GigaAM" && choice.chipName == "GigaAM")
        #expect(choice.isLocal && !choice.isGemini && choice.defaultColor == .green)
        #expect(Set(ModelChoice.allCases.map(\.defaultColor)).count == ModelChoice.allCases.count, "its own color")
    }

    @Test func eachVersionHasItsNameFilesAndSizes() {
        typealias V = GigaAMEngine.Variant
        #expect(V.allCases == [.v3, .v3e2e, .multilingual] && V.default == .v3)
        #expect(V.allCases.map(\.rawValue) == ["gigaam-v3-ctc", "gigaam-v3-e2e-ctc", "gigaam-multilingual-600m-ctc"])
        #expect(V.allCases.map(\.versionName) == ["v3", "v3 e2e", "Multilingual"])
        #expect(V.allCases.map(\.displayName) == ["GigaAM v3", "GigaAM v3 e2e", "GigaAM Multilingual"])
        #expect(V.allCases.map(\.facts) == ["Russian · no punctuation", "Russian · punctuation",
                                            "Russian, English and more · no punctuation"])
        #expect(V.allCases.map(\.zipName)
                == ["gigaam-v3-ctc.zip", "gigaam-v3-e2e-ctc.zip", "gigaam-multilingual-600m-ctc.zip"])
        #expect(V.allCases.map(\.downloadBytes) == [409_369_862, 409_641_058, 1_082_718_871])
        #expect(V.allCases.map(\.installedBytes) == [443_353_203, 443_698_324, 1_173_144_132])
        #expect(V.v3.sha256 == "c2d31e7dba58b5a5aed45abeb60ccc617c6a4ccb5531f30887d2a26e05e34f17")
        #expect(V.v3e2e.sha256 == "eb2c35f78382e7c12dd5ff0a1eec9367c28a349d2f9ac48c744510c17ec3b658")
        #expect(V.multilingual.sha256 == "4384fe127886f666e419b6b0c00599b8b767dfefb3abddae32c87e7a699dab3a")
        #expect(GigaAMSource.releaseURL(.v3e2e).absoluteString
                == "https://github.com/xcviko/transcribe-thing/releases/download/gigaam-1/gigaam-v3-e2e-ctc.zip")
        let live = GigaAMSource.live(.multilingual)
        #expect(live.fileName == "gigaam-multilingual-600m-ctc.zip" && live.expectedBytes == 1_082_718_871)
        #expect(live.localZip?.lastPathComponent == "gigaam-multilingual-600m-ctc.zip")
        #expect(live.localZip?.deletingLastPathComponent().lastPathComponent == "Downloads")
    }

    /// Each version installs, loads and is deleted on its own; Parakeet stays "parakeet" in the logs.
    @Test func localModelsAreParakeetAndEachVersion() {
        #expect(LocalModel.all == [.parakeet, .gigaam(.v3), .gigaam(.v3e2e), .gigaam(.multilingual)])
        #expect(LocalModel.all.map(\.id) == ["parakeet", "gigaam-v3-ctc", "gigaam-v3-e2e-ctc",
                                             "gigaam-multilingual-600m-ctc"])
        #expect(LocalModel.all.map(\.engine) == [.parakeet, .gigaam, .gigaam, .gigaam])
        let e2e = LocalModel.gigaam(.v3e2e)
        #expect(e2e.displayName == "GigaAM v3 e2e" && e2e.modelID == "gigaam-v3-e2e-ctc")
        #expect(e2e.approxDownloadBytes == 409_641_058 && e2e.approxInstalledBytes == 443_698_324)
        #expect(e2e.approxInstallPeakBytes == 409_641_058 + 443_698_324, "the zip and its unpacked folder at once")
        #expect(e2e.downloadHost == "GitHub" && LocalModel.parakeet.downloadHost == "Hugging Face")
        #expect(LocalModel.parakeet.displayName == "Parakeet v3" && LocalModel.parakeet.modelID == nil)
        #expect(LocalModel.parakeet.approxDownloadBytes == 632_321_326)
        #expect(LocalModel.parakeet.approxInstalledBytes == 632_321_326)
        #expect(LocalModel.parakeet.approxInstallPeakBytes == 632_321_326)
    }

    /// GigaAM is GigaAM wherever a job or History names it; a version's transcript is named by its version.
    @Test func choiceAndEngineMapBothWays() {
        #expect(ModelChoice(engine: .gigaam) == .gigaam && ModelChoice.gigaam.engine == .gigaam)
        #expect(ModelChoice(stored: "gigaam") == .gigaam && ModelChoice.read(["gigaam", "x"]) == [.gigaam])
        let kind = TranscriptVersionKind.transcription(.gigaam)
        #expect(kind.rawValue == "gigaam" && TranscriptVersionKind(rawValue: "gigaam") == kind)
        #expect(kind.dictationModel == .gigaam)
        #expect(kind.displayName(modelID: "gigaam-v3-e2e-ctc") == "GigaAM v3 e2e")
        #expect(kind.displayName(modelID: nil) == "GigaAM" && kind.displayName(modelID: "something") == "GigaAM")
        #expect(TranscriptVersionKind.transcription(.parakeet).displayName(modelID: "gigaam-v3-ctc") == "Parakeet v3")
    }
}

// MARK: - Install

/// A fake GigaAM install file in a temp folder: `<variant>/` with every part, zipped as the script zips it.
private struct FakeInstall {
    let root: URL
    let variant: GigaAMEngine.Variant
    let zip: URL
    let sha256: String
    let bytes: Int64

    /// `weightBytes`: the encoder's weights, random (so the zip is about that big). `folder`: what the zip holds,
    /// the variant's folder unless given.
    init(_ variant: GigaAMEngine.Variant = .v3, weightBytes: Int = 1_024, folder: String? = nil,
         root: URL? = nil) throws {
        let fm = FileManager.default
        self.variant = variant
        self.root = root ?? fm.temporaryDirectory.appendingPathComponent("gigaam-tests-\(UUID().uuidString)",
                                                                         isDirectory: true)
        let source = self.root.appendingPathComponent("source-\(variant.rawValue)/\(folder ?? variant.rawValue)",
                                                      isDirectory: true)
        for part in GigaAMEngine.requiredParts {
            let url = source.appendingPathComponent(part)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data(count: part == "Encoder.mlmodelc/weights/weight.bin" ? weightBytes : 16)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try data.write(to: url)
        }
        let downloads = self.root.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        zip = downloads.appendingPathComponent(variant.zipName)
        try Self.ditto(["-c", "-k", "--keepParent", source.path, zip.path])
        sha256 = try GigaAMSource.sha256(of: zip)
        bytes = try #require((fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value)
    }

    var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    var unpacked: URL { root.appendingPathComponent("source-\(variant.rawValue)/\(variant.rawValue)") }

    /// The zip in "Downloads", and no release.
    func source(sha256: String? = nil, bytes: Int64? = nil, zip: URL? = nil,
                remote: URL? = nil,
                download: @escaping @Sendable (URL, URL, @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Void
                    = { _, _, _ in Issue.record("no release to fetch") }) -> GigaAMSource {
        GigaAMSource(fileName: variant.zipName, localZip: zip ?? self.zip, remote: remote,
                     expectedBytes: bytes ?? self.bytes, sha256: sha256 ?? self.sha256, download: download)
    }

    func engine(_ source: GigaAMSource) -> GigaAMEngine {
        GigaAMEngine(variant: variant, modelsRoot: models, source: source)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

/// What a download reported, from any thread.
private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

@Suite struct GigaAMInstallTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A version's folder is `<Models>/<variant>`, on the GPU; it counts as installed with every part Core ML reads
    /// and nothing an unfinished install left.
    @Test func installedNeedsEveryPartAndNoLeftovers() throws {
        let install = try FakeInstall(.v3e2e)
        defer { install.remove() }
        let engine = install.engine(install.source())
        #expect(engine.engineID == .gigaam && engine.variant == .v3e2e && engine.computeUnits == .cpuAndGPU)
        #expect(engine.directory == install.models.appendingPathComponent("gigaam-v3-e2e-ctc", isDirectory: true))
        #expect(engine.storageURLs == [engine.directory, engine.stagingDirectory])
        #expect(engine.stagingDirectory.lastPathComponent == "gigaam-v3-e2e-ctc.partial")
        #expect(!engine.isInstalled())

        try FileManager.default.createDirectory(at: install.models, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: install.unpacked, to: engine.directory)
        #expect(engine.isInstalled())

        let partial = engine.directory.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin.partial")
        try Data().write(to: partial)
        #expect(!engine.isInstalled(), "a partial file inside")
        try FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: engine.stagingDirectory, withIntermediateDirectories: true)
        #expect(!engine.isInstalled(), "an unfinished download beside it")
        try FileManager.default.removeItem(at: engine.stagingDirectory)
        #expect(engine.isInstalled())

        for part in ["Encoder.mlmodelc/weights/weight.bin", "Frontend.mlmodelc/coremldata.bin", "vocabulary.json"] {
            let url = engine.directory.appendingPathComponent(part)
            let data = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            #expect(!engine.isInstalled(), "without \(part)")
            try data.write(to: url)
        }
        #expect(engine.isInstalled())
        #expect(engine.bytesOnDisk() > 0)
    }

    /// The zip in Downloads is copied with byte progress, checked, unpacked and moved into place; the download folder
    /// goes, and the zip in Downloads stays as it was.
    @Test func installsFromTheZipInDownloads() async throws {
        let install = try FakeInstall(.v3, weightBytes: 9 << 20)
        defer { install.remove() }
        let engine = install.engine(install.source())
        #expect(await engine.remoteDownloadBytes() == install.bytes)
        let fractions = Fractions()
        try await engine.download { fractions.add($0) }
        #expect(engine.isInstalled())
        #expect(!exists(engine.stagingDirectory), "the download folder goes")
        #expect(try FileManager.default.contentsOfDirectory(atPath: install.models.path) == ["gigaam-v3-ctc"])
        #expect(try GigaAMSource.sha256(of: install.zip) == install.sha256, "the zip in Downloads is left alone")
        #expect(try FileManager.default.contentsOfDirectory(atPath: install.zip.deletingLastPathComponent().path)
                == ["gigaam-v3-ctc.zip"])
        let values = fractions.all
        #expect(values.last == 1)
        #expect(values.contains { $0 > 0 && $0 < 1 }, "byte progress on the way: \(values)")
        #expect(values == values.sorted())
    }

    /// Two versions install side by side, each from its own zip into its own folder; deleting one leaves the other.
    @Test func eachVersionInstallsOnItsOwn() async throws {
        let v3 = try FakeInstall(.v3)
        defer { v3.remove() }
        let e2e = try FakeInstall(.v3e2e, root: v3.root)
        let first = v3.engine(v3.source()), second = e2e.engine(e2e.source())
        try await first.download { _ in }
        #expect(first.isInstalled() && !second.isInstalled())
        try await second.download { _ in }
        #expect(first.isInstalled() && second.isInstalled())
        #expect(try FileManager.default.contentsOfDirectory(atPath: v3.models.path).sorted()
                == ["gigaam-v3-ctc", "gigaam-v3-e2e-ctc"])
        try await first.deleteFiles()
        #expect(!first.isInstalled() && second.isInstalled())
    }

    @Test func aZipOfAnotherChecksumOrSizeIsRefusedAndLeavesNothing() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        for source in [install.source(sha256: String(repeating: "0", count: 64)), install.source(bytes: install.bytes + 1)] {
            let engine = install.engine(source)
            await #expect(throws: GigaAMSource.Failure.wrongFile("gigaam-v3-ctc.zip")) {
                try await engine.download { _ in }
            }
            #expect(!engine.isInstalled() && !exists(engine.directory) && !exists(engine.stagingDirectory))
        }
        #expect(GigaAMSource.Failure.wrongFile("gigaam-v3-ctc.zip").errorDescription
                == "gigaam-v3-ctc.zip isn’t the right file: its size or checksum doesn’t match.")
    }

    /// A file that checks out but isn't a zip, and a zip without the version's folder: refused, nothing left.
    @Test func aBadZipIsRefusedAndLeavesNothing() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        let junk = install.root.appendingPathComponent("junk.zip")
        var data = Data(count: 2_048)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try data.write(to: junk)
        let engine = install.engine(install.source(sha256: try GigaAMSource.sha256(of: junk), bytes: 2_048, zip: junk))
        await #expect(throws: GigaAMSource.Failure.badArchive("gigaam-v3-ctc.zip")) { try await engine.download { _ in } }
        #expect(!engine.isInstalled() && !exists(engine.directory) && !exists(engine.stagingDirectory))

        // The e2e zip holding v3's folder isn't e2e.
        let other = try FakeInstall(.v3e2e, folder: "gigaam-v3-ctc")
        defer { other.remove() }
        let wrong = other.engine(other.source())
        await #expect(throws: GigaAMSource.Failure.notTheModel("gigaam-v3-e2e-ctc.zip")) {
            try await wrong.download { _ in }
        }
        #expect(!wrong.isInstalled() && !exists(wrong.directory) && !exists(wrong.stagingDirectory))
    }

    /// What an unfinished download left goes before the next one; one cut off right after its move has the model in
    /// place already, and needs no zip at all.
    @Test func leftoversOfAnUnfinishedInstallGo() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        let engine = install.engine(install.source())
        try FileManager.default.createDirectory(at: engine.stagingDirectory.appendingPathComponent("unpacked"),
                                                withIntermediateDirectories: true)
        try Data(count: 64).write(to: engine.stagingDirectory.appendingPathComponent("gigaam-v3-ctc.zip"))
        try await engine.download { _ in }
        #expect(engine.isInstalled() && !exists(engine.stagingDirectory))

        try FileManager.default.createDirectory(at: engine.stagingDirectory, withIntermediateDirectories: true)
        #expect(!engine.isInstalled())
        let noZip = install.engine(install.source(zip: install.root.appendingPathComponent("nowhere.zip")))
        try await noZip.download { _ in }
        #expect(noZip.isInstalled() && !exists(noZip.stagingDirectory))
    }

    /// No zip in Downloads and no release: the version isn't published yet. A release that answers 404 is the same; a
    /// connection that fails says so.
    @Test func withNoSourceTheVersionIsntPublishedYet() async throws {
        let install = try FakeInstall(.multilingual)
        defer { install.remove() }
        let missing = install.root.appendingPathComponent("Downloads/elsewhere/gigaam-multilingual-600m-ctc.zip")
        let notPublished = LocalEngineError.notPublished(file: "gigaam-multilingual-600m-ctc.zip")
        let none = install.engine(install.source(zip: missing))
        await #expect(throws: notPublished) { try await none.download { _ in } }
        #expect(!exists(none.directory) && !exists(none.stagingDirectory))

        let release = URL(string: "https://example.invalid/gigaam.zip")!
        let notFound = install.engine(install.source(zip: missing, remote: release) { _, _, _ in
            throw UpdateDownload.HTTPStatus(status: 404)
        })
        await #expect(throws: notPublished) { try await notFound.download { _ in } }
        #expect(!exists(notFound.stagingDirectory))

        let offline = install.engine(install.source(zip: missing, remote: release) { _, _, _ in
            throw URLError(.notConnectedToInternet)
        })
        await #expect(throws: URLError.self) { try await offline.download { _ in } }
        #expect(!exists(offline.stagingDirectory))
    }

    /// Without the zip in Downloads, the release is fetched, with its progress.
    @Test func installsFromTheRelease() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        let zip = install.zip
        let release = URL(string: "https://example.invalid/gigaam.zip")!
        let engine = install.engine(install.source(zip: install.root.appendingPathComponent("none.zip"),
                                                   remote: release) { url, destination, progress in
            #expect(url == release)
            try FileManager.default.copyItem(at: zip, to: destination)
            progress(1, nil)
        })
        let fractions = Fractions()
        try await engine.download { fractions.add($0) }
        #expect(engine.isInstalled() && !exists(engine.stagingDirectory))
        #expect(fractions.all.last == 1)
    }

    /// Cancelled mid-download, it stops and leaves nothing behind.
    @Test func aCancelledDownloadLeavesNothing() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        let started = Flag(false)
        let engine = install.engine(install.source(zip: install.root.appendingPathComponent("none.zip"),
                                                   remote: URL(string: "https://example.invalid/gigaam.zip")!) { _, _, _ in
            started.set(true)
            try await Task.sleep(for: .seconds(30))
        })
        let task = Task { try await engine.download { _ in } }
        while !started.get() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(exists(engine.stagingDirectory))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!engine.isInstalled() && !exists(engine.stagingDirectory))
    }

    @Test func deleteRemovesTheFolderAndAnyDownload() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        let engine = install.engine(install.source())
        try await engine.download { _ in }
        try FileManager.default.createDirectory(at: engine.stagingDirectory, withIntermediateDirectories: true)
        try await engine.deleteFiles()
        #expect(!exists(engine.directory) && !exists(engine.stagingDirectory) && !engine.isInstalled())
        #expect(engine.bytesOnDisk() == 0)
    }

    /// A folder read as it is (the comparison) never downloads, and an engine that isn't loaded doesn't transcribe.
    @Test func aFolderReadAsItIsNeverDownloads() async throws {
        let engine = GigaAMEngine(variant: .v3, directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("gigaam-none-\(UUID().uuidString)"))
        #expect(engine.computeUnits == .all, "the comparison's own default")
        await #expect(throws: LocalEngineError.notInstalled) { try await engine.download { _ in } }
        await #expect(throws: LocalEngineError.notLoaded) { try await engine.transcribe([0]) }
    }
}

// MARK: - ModelStore with GigaAM's versions

@MainActor
@Suite(.timeLimit(.minutes(1))) struct GigaAMModelStoreTests {
    private func makeStore(_ settings: AppSettings? = nil,
                           _ engines: [LocalModel: any LocalEngine]) -> ModelStore {
        ModelStore(paths: .temporary(), settings: settings ?? .inMemory(), engines: engines, gate: InferenceGate(),
                   freeDiskBytes: { 50_000_000_000 })
    }

    /// A store with fake engines: Parakeet, and each GigaAM version, `installed` the ones on disk.
    private func makeFakes(_ settings: AppSettings, installed: Set<LocalModel>)
        -> (ModelStore, [LocalModel: FakeEngine]) {
        var fakes: [LocalModel: FakeEngine] = [:]
        for model in LocalModel.all {
            fakes[model] = FakeEngine(model.engine, installed: installed.contains(model), transcript: "by \(model.id)")
        }
        return (makeStore(settings, fakes), fakes)
    }

    /// Downloaded from a zip through ModelStore: GigaAM's picked version ends installed, not loaded, while nothing
    /// uses it.
    @Test func aDownloadThroughTheStoreInstallsThePickedVersion() async throws {
        let install = try FakeInstall(.v3e2e)
        defer { install.remove() }
        let settings = AppSettings.inMemory()
        settings.gigaamVariant = .v3e2e
        let store = makeStore(settings, [.gigaam(.v3e2e): install.engine(install.source())])
        var finished: [LocalModel] = []
        store.onDownloadFinished = { finished.append($0) }
        store.download(.gigaam)
        #expect(store.state(model: .gigaam(.v3e2e)).downloadProgress?.totalBytes == 409_641_058)
        await waitForObserved { store.state(of: .gigaam) == .installed }
        await store.waitForDownloadToSettle(.gigaam)
        #expect(store.state(model: .gigaam(.v3e2e)) == .installed && store.state(model: .gigaam(.v3)) == .notInstalled)
        #expect(finished == [.gigaam(.v3e2e)] && store.lastErrors[.gigaam] == nil)
        #expect(store.diskUsageBytes > 0)
    }

    /// With no source, the row says it plainly, and the error is its own.
    @Test func withNoSourceTheStoreSaysItIsntPublished() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        let store = makeStore(nil, [.gigaam(.v3): install.engine(install.source(zip: install.root.appendingPathComponent("no.zip")))])
        var failures: [AppError] = []
        store.onFailure = { _, error in failures.append(error) }
        store.download(.gigaam)
        await waitForObserved { if case .failed = store.state(of: .gigaam) { true } else { false } }
        let error = AppError.modelNotPublished(.gigaam, file: "gigaam-v3-ctc.zip")
        #expect(store.lastErrors[.gigaam] == error && failures == [error])
        #expect(store.state(of: .gigaam)
                == .failed("Not published yet. Put gigaam-v3-ctc.zip in your Downloads folder, then Retry."))
        await #expect(throws: error) { try await store.transcribeLocal(.gigaam, samples: [0]) }
    }

    /// Picking a version that isn't downloaded shows its Download; the one already on disk stays there, unloaded.
    @Test func pickingAVersionKeepsTheOthersOnDiskAndUnloadsThem() async throws {
        let settings = AppSettings.inMemory()
        settings.lineup.setSwitchable(.gigaam, true)
        let (store, fakes) = makeFakes(settings, installed: [.parakeet, .gigaam(.v3)])
        store.start()
        await waitForObserved { store.state(model: .gigaam(.v3)) == .ready }
        #expect(await fakes[.gigaam(.v3)]!.isLoaded)
        store.pickGigaAMVariant(.v3e2e)
        #expect(settings.gigaamVariant == .v3e2e)
        #expect(store.state(of: .gigaam) == .notInstalled, "e2e's own state: Download")
        await waitForObserved { store.state(model: .gigaam(.v3)) == .installed }
        #expect(await !fakes[.gigaam(.v3)]!.isLoaded, "unloaded, still on disk")
        #expect(fakes[.gigaam(.v3)]!.isInstalled())
    }

    /// Picking a version on disk while GigaAM is in use loads it and unloads the other: one loaded at a time. Every
    /// dictation runs the picked one, and its transcript says which.
    @Test func pickingAVersionOnDiskSwapsWhatsLoaded() async throws {
        let settings = AppSettings.inMemory()
        settings.lineup.setSwitchable(.gigaam, true)
        let (store, fakes) = makeFakes(settings, installed: [.parakeet, .gigaam(.v3), .gigaam(.v3e2e)])
        store.start()
        await waitForObserved { store.state(model: .gigaam(.v3)) == .ready }
        #expect(await !fakes[.gigaam(.v3e2e)]!.isLoaded, "only the picked one loads at launch")
        store.pickGigaAMVariant(.v3e2e)
        await waitForObserved {
            store.state(model: .gigaam(.v3e2e)) == .ready && store.state(model: .gigaam(.v3)) == .installed
        }
        #expect(await fakes[.gigaam(.v3e2e)]!.isLoaded)
        #expect(await !fakes[.gigaam(.v3)]!.isLoaded)

        let account = OpenRouterAccount(keyStore: .inMemory(), client: OpenRouterClient(), debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: OpenRouterClient())
        let result = try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)),
                                                  engine: .gigaam)
        #expect(result.text == "by gigaam-v3-e2e-ctc" && result.modelID == "gigaam-v3-e2e-ctc")
        #expect(result.metadata().modelID == "gigaam-v3-e2e-ctc")
        let parakeet = try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)),
                                                    engine: .parakeet)
        #expect(parakeet.modelID == nil, "Parakeet records none, as before")
    }

    /// Delete frees a version that isn't picked; the picked one keeps its state.
    @Test func aVersionThatIsntPickedDeletesOnItsOwn() async throws {
        let settings = AppSettings.inMemory()
        let (store, fakes) = makeFakes(settings, installed: [.parakeet, .gigaam(.v3), .gigaam(.multilingual)])
        await store.refreshFromDisk()
        await store.delete(model: .gigaam(.multilingual))
        #expect(store.state(model: .gigaam(.multilingual)) == .notInstalled && !fakes[.gigaam(.multilingual)]!.isInstalled())
        #expect(store.state(of: .gigaam) == .installed && fakes[.gigaam(.v3)]!.isInstalled())
    }

    /// Launch loads only the models on this Mac the lineup reaches, GigaAM in its picked version.
    @Test func launchLoadsOnlyWhatTheLineupUses() async throws {
        let settings = AppSettings.inMemory()
        let (store, fakes) = makeFakes(settings, installed: [.parakeet, .gigaam(.v3)])
        store.start()
        await waitForObserved { store.state(of: .parakeet) == .ready }
        await waitForObserved { store.state(of: .gigaam) == .installed }
        #expect(await fakes[.gigaam(.v3)]!.loadCount == 0)
    }

    /// Both in use: Parakeet loads first, and GigaAM only once Parakeet is ready.
    @Test func launchLoadsParakeetFirstThenGigaAM() async throws {
        let settings = AppSettings.inMemory()
        settings.lineup.setSwitchable(.gigaam, true)
        settings.gigaamVariant = .multilingual
        let (store, fakes) = makeFakes(settings, installed: [.parakeet, .gigaam(.v3), .gigaam(.multilingual)])
        let gate = await fakes[.parakeet]!.gateLoads()
        store.start()
        await gate.arrival(1)
        #expect(store.state(of: .gigaam).isPreparing)
        #expect(await fakes[.gigaam(.multilingual)]!.loadCount == 0, "waits for Parakeet")
        gate.openForGood()
        await waitForObserved { store.state(of: .parakeet) == .ready && store.state(of: .gigaam) == .ready }
        #expect(await fakes[.gigaam(.multilingual)]!.loadCount == 1)
        #expect(await fakes[.gigaam(.v3)]!.loadCount == 0)
    }

    /// GigaAM as the main model, Parakeet switched off: only GigaAM loads.
    @Test func launchLoadsGigaAMAloneWhenOnlyItIsUsed() async throws {
        let settings = AppSettings.inMemory()
        settings.lineup.main = .gigaam
        settings.lineup.setSwitchable(.parakeet, false)
        #expect(settings.localModelsInUse == [.gigaam])
        let (store, fakes) = makeFakes(settings, installed: [.parakeet, .gigaam(.v3)])
        store.start()
        await waitForObserved { store.state(of: .gigaam) == .ready }
        await waitForObserved { store.state(of: .parakeet) == .installed }
        #expect(await fakes[.parakeet]!.loadCount == 0)
    }

    /// A download of the picked version the lineup uses loads it; one it doesn't use, or another version, stays
    /// installed.
    @Test func aDownloadedVersionInUseLoads() async throws {
        let settings = AppSettings.inMemory()
        let (store, _) = makeFakes(settings, installed: [])
        store.download(.gigaam)
        await waitForObserved { store.state(of: .gigaam) == .installed }
        settings.lineup.setSwitchable(.gigaam, true)
        store.download(model: .gigaam(.v3e2e))
        await waitForObserved { store.state(model: .gigaam(.v3e2e)) == .installed }
        #expect(store.state(model: .gigaam(.v3e2e)) == .installed, "not the picked version: stays on disk")
        await store.delete(.gigaam)
        store.download(.gigaam)
        await waitForObserved { store.state(of: .gigaam) == .ready }
    }

    /// The preview reads its engines' states through the page's settings: GigaAM's pick is the page's.
    @Test func thePreviewFollowsThePagesPick() {
        let settings = AppSettings.inMemory()
        settings.gigaamVariant = .multilingual
        let store = ModelStore.preview(states: [.gigaam: .ready], models: [.gigaam(.v3): .installed],
                                       settings: settings)
        #expect(store.state(model: .gigaam(.multilingual)) == .ready && store.state(model: .gigaam(.v3)) == .installed)
        #expect(store.diskUsageBytes == 1_173_144_132 + 443_353_203)
        settings.gigaamVariant = .v3
        #expect(store.state(of: .gigaam) == .installed)
    }
}

// MARK: - Settings

private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "transcribe-thing-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@MainActor
private func load(_ defaults: UserDefaults) -> AppSettings {
    AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
}

@MainActor
@Suite struct GigaAMSettingsTests {
    /// A fresh install lists GigaAM last, switched off, in its own green, in v3: nothing loads it until it's picked.
    @Test func aFreshInstallListsGigaAMLastSwitchedOff() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.lineup.order == [.parakeet, .gemini, .carbon, .gigaam])
            #expect(settings.lineup.main == .parakeet && !settings.lineup.isSwitchable(.gigaam))
            #expect(settings.lineup.cycle == [.parakeet, .gemini])
            #expect(settings.modelColors[.gigaam] == .green)
            #expect(settings.localModelsInUse == [.parakeet] && !settings.usesLocalModel(.gigaam))
            #expect(settings.gigaamVariant == .v3 && settings.localModel(for: .gigaam) == .gigaam(.v3))
        }
    }

    /// The picked version is stored by its raw value and read back; one this build doesn't know leaves v3.
    @Test func thePickedVersionPersists() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            settings.gigaamVariant = .v3e2e
            #expect(defaults.string(forKey: SettingsKey.gigaamVariant.defaultsKey) == "gigaam-v3-e2e-ctc")
            #expect(load(defaults).gigaamVariant == .v3e2e)
            defaults.set("gigaam-v4-ctc", forKey: SettingsKey.gigaamVariant.defaultsKey)
            #expect(load(defaults).gigaamVariant == .v3)
        }
    }

    /// Where there's room GigaAM goes by its version; the others by their own names.
    @Test func namesFollowThePick() {
        let settings = AppSettings.inMemory()
        settings.gigaamVariant = .multilingual
        #expect(settings.modelName(of: .gigaam) == "GigaAM Multilingual" && settings.chipName(of: .gigaam) == "GigaAM Multilingual")
        #expect(settings.engineName(.gigaam) == "GigaAM Multilingual")
        #expect(settings.modelName(of: .parakeet) == "Parakeet v3" && settings.chipName(of: .parakeet) == "Parakeet")
        #expect(settings.engineName(.geminiFlash) == "Gemini 3.8 Flash")
        #expect(settings.localModel(for: .parakeet) == .parakeet && settings.localModel(for: .geminiFlash) == nil)
    }

    /// A lineup stored before GigaAM gets it appended at the end, switched off; the main model, the order and
    /// hands-free stay. One from before Carbon gets Carbon, then GigaAM.
    @Test func aLineupFromBeforeGigaAMGetsItAppendedSwitchedOff() throws {
        try withDefaults { defaults in
            let old = #"{"main":"gemini","order":["carbon","gemini","parakeet"],"switchable":["parakeet","carbon"]}"#
            defaults.set(Data(old.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("carbon", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.carbon, .gemini, .parakeet, .gigaam])
            #expect(settings.lineup.main == .gemini && settings.lineup.cycle == [.gemini, .parakeet, .carbon])
            #expect(!settings.lineup.isSwitchable(.gigaam) && settings.handsFreeChoice == .carbon)
            #expect(load(defaults).lineup.order == [.carbon, .gemini, .parakeet, .gigaam], "stored as read")
        }
        try withDefaults { defaults in
            let older = #"{"main":"parakeet","order":["gemini","parakeet"],"switchable":["gemini"]}"#
            defaults.set(Data(older.utf8), forKey: SettingsKey.lineup.defaultsKey)
            #expect(load(defaults).lineup.order == [.gemini, .parakeet, .carbon, .gigaam])
        }
    }

    /// Switched on, GigaAM is in use and can be hands-free's model; as the main model too.
    @Test func gigaamInTheCycleIsInUse() throws {
        let settings = AppSettings.inMemory()
        settings.lineup.setSwitchable(.gigaam, true)
        settings.handsFreeModel = .gigaam
        #expect(settings.handsFreeChoice == .gigaam)
        #expect(settings.localModelsInUse == [.parakeet, .gigaam])
        settings.lineup.setSwitchable(.gigaam, false)
        #expect(settings.handsFreeChoice == nil && settings.localModelsInUse == [.parakeet])
        settings.lineup.main = .gigaam
        #expect(settings.mainEngine == .gigaam && settings.usesLocalModel(.gigaam))
        #expect(!settings.usesLocalModel(.geminiFlash), "a cloud model is no model on this Mac")
    }

    /// Pasting's rules from before GigaAM: it starts with Parakeet's checks, once, and keeps its own after.
    @Test func gigaamStartsWithParakeetsPastingRulesOnce() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["parakeet", "gemini", "carbon"]),
                         forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            defaults.set(try JSONEncoder().encode(["gemini"]), forKey: SettingsKey.modelsRemovingFinalPeriod.defaultsKey)
            defaults.set(true, forKey: SettingsKey.carbonPastingAdded.defaultsKey)
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace == [.parakeet, .gemini, .carbon, .gigaam])
            #expect(settings.modelsRemovingFinalPeriod == [.gemini])
            #expect(settings.addsSpace(by: .gigaam, in: .handsFree))
            #expect(defaults.bool(forKey: SettingsKey.gigaamPastingAdded.defaultsKey))
            settings.modelsAddingSpace.remove(.gigaam)
            settings.modelsRemovingFinalPeriod.insert(.gigaam)
            let reloaded = load(defaults)
            #expect(reloaded.modelsAddingSpace == [.parakeet, .gemini, .carbon], "a choice made since stays")
            #expect(reloaded.modelsRemovingFinalPeriod == [.gemini, .gigaam])
        }
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace.isEmpty && settings.modelsRemovingFinalPeriod.isEmpty)
            #expect(defaults.bool(forKey: SettingsKey.gigaamPastingAdded.defaultsKey))
        }
        #expect(AppSettings.withGigaAMLikeParakeet([.parakeet]) == [.parakeet, .gigaam])
        #expect(AppSettings.withGigaAMLikeParakeet([.gigaam, .gemini]) == [.gemini])
    }
}

// MARK: - Fallbacks

@MainActor
@Suite(.serialized) struct GigaAMFallbackTests {
    typealias H = DictationControllerTests

    /// Gemini refuses a dictation: the notice offers the models on this Mac that are downloaded, Parakeet first.
    @Test func aRefusedDictationOffersTheInstalledModelsOnThisMacParakeetFirst() async throws {
        let cases: [([EngineID: LocalModelState], EngineID?)] = [
            ([.parakeet: .ready, .gigaam: .ready], .parakeet),
            ([.parakeet: .notInstalled, .gigaam: .installed], .gigaam),
            ([.parakeet: .downloading(DownloadProgress(fraction: 0.3)), .gigaam: .ready], .gigaam),
            ([.parakeet: .notInstalled, .gigaam: .notInstalled], nil),
        ]
        for (models, fallback) in cases {
            let h = H.make(models: models, keyStatus: .valid(KeyInfo()))
            h.controller.transcribeOverride = { _, _ in throw AppError.openRouterRefused("refused") }
            let r = H.recording()
            h.controller.enqueue(r, engine: .geminiFlash)
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
            #expect(notice.actions.map(\.kind) == [.retry] + (fallback.map { [.retryWith($0)] } ?? []), "\(models)")
        }
    }

    /// A Gemini main model without a key: "Use GigaAM" where Parakeet isn't downloaded, and it becomes the main
    /// model, named by its version.
    @Test func aKeylessGeminiMainModelOffersGigaAMWithoutParakeet() throws {
        let (rig, _) = SwitchModelControllerTests.make(key: .missing, models: [.parakeet: .notInstalled, .gigaam: .ready])
        rig.h.settings.lineup.main = .gemini
        rig.h.controller.send(.handsFreeToggle)
        let notice = try #require(rig.h.toasts.notices.first)
        #expect(notice.actions.contains { $0.kind == .selectEngine(.gigaam) })
        try rig.click(.selectEngine(.gigaam), in: notice.dedupeKey)
        #expect(rig.h.settings.lineup.main == .gigaam)
        #expect(rig.notice("engine.selected")?.title == "Now using GigaAM v3")
    }

    /// A dictation waiting for GigaAM to load offers Parakeet, ready now.
    @Test func waitingForGigaAMOffersParakeet() async throws {
        let h = H.make(models: [.parakeet: .ready, .gigaam: .preparing(since: Date())], keyStatus: .valid(KeyInfo()))
        h.controller.waitNoticeDelayOverride = 0.05
        h.controller.transcribeOverride = { _, engine in
            if engine == .gigaam { try await Task.sleep(for: .seconds(5)) }
            return TranscriptResult(text: "by \(engine.rawValue)", engine: engine, processingTime: 0.2)
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .gigaam)
        try await waitUntil { h.toasts.notices.contains { $0.dedupeKey == "slow.\(r.id)" } }
        let wait = try #require(h.toasts.notices.first { $0.dedupeKey == "slow.\(r.id)" })
        #expect(wait.title == "Getting GigaAM ready…")
        #expect(wait.body == "The first run on this Mac takes a moment.")
        #expect(wait.actions.map(\.kind) == [.retryWith(.parakeet)])
        #expect(wait.actions.first?.title == "Use Parakeet v3 Instead")
        h.controller.handle(.cancel)
    }

    /// Parakeet's wait never offers GigaAM, which writes far fewer languages.
    @Test func waitingForParakeetNeverOffersGigaAM() async throws {
        let h = H.make(models: [.parakeet: .preparing(since: Date()), .gigaam: .ready], keyStatus: .valid(KeyInfo()))
        h.controller.waitNoticeDelayOverride = 0.05
        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .seconds(5))
            return TranscriptResult(text: "late", engine: engine, processingTime: 5)
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet)
        try await waitUntil { h.toasts.notices.contains { $0.dedupeKey == "slow.\(r.id)" } }
        let wait = try #require(h.toasts.notices.first { $0.dedupeKey == "slow.\(r.id)" })
        #expect(wait.body == "The first run on this Mac takes a moment.")
        #expect(wait.actions.isEmpty)
        h.controller.handle(.cancel)
    }
}

// MARK: - Copy and History

@MainActor
@Suite struct GigaAMCopyTests {
    private func attention(_ engine: EngineID, _ state: LocalModelState, error: AppError? = nil) -> AttentionItem? {
        HubAttention.items(HubAttention.Input(microphone: .granted, accessibility: .granted,
                                              accessibilityLikelyStale: false, fnKeyUsage: .doNothing,
                                              pushToTalkUsesFn: true, engine: engine, localState: state,
                                              keyStatus: .missing, localError: error)).first
    }

    /// Each version's size is its download's until it's done, then what it takes on this Mac.
    @Test func sizesAreEachVersions() {
        #expect(ModelStatusText.describe(.notInstalled, model: .gigaam(.v3)).text == "Not downloaded · 409 MB")
        #expect(ModelStatusText.describe(.ready, model: .gigaam(.v3)).text == "Ready · 443 MB")
        #expect(ModelStatusText.describe(.notInstalled, model: .gigaam(.multilingual)).text == "Not downloaded · 1.1 GB")
        #expect(ModelStatusText.describe(.installed, model: .gigaam(.multilingual)).text == "Downloaded · 1.2 GB")
        #expect(ModelStatusText.describe(.ready, model: .parakeet).text == "Ready · 632 MB")
        #expect(ModelStatusText.describe(.ready, engine: .parakeet).text == "Ready · 632 MB")
    }

    /// Loading takes seconds on the GPU: Parakeet's words, nothing about minutes.
    @Test func loadingCopyIsParakeetsAsBefore() {
        #expect(attention(.gigaam, .preparing(since: Date()))?.body
                == "Loading the model into memory. After installing it or updating macOS, this takes about half a minute.")
        #expect(AppError.modelPreparing(.gigaam).notice(recordingID: nil, fallbackEngine: nil).body
                == "The first run on this Mac takes a moment.")
    }

    /// Not published yet: said plainly, with what to do, wherever the failure shows.
    @Test func notPublishedSaysWhatToDo() {
        let error = AppError.modelNotPublished(.gigaam, file: "gigaam-v3-e2e-ctc.zip")
        let notice = error.notice(recordingID: nil, fallbackEngine: .parakeet)
        #expect(notice.title == "GigaAM isn’t published yet")
        #expect(notice.body == "Put gigaam-v3-e2e-ctc.zip in your Downloads folder, then download it again.")
        #expect(notice.actions.map(\.kind) == [.openHub(.models)])
        #expect(error.code == "modelNotPublished.gigaam" && !error.isRetryable)
        #expect(ModelFailure(error) == .notPublished && ModelFailure(error).label == "Not published yet")
        #expect(ModelStatusText.describe(.failed("x"), model: .gigaam(.v3e2e), localError: error).text
                == "Not published yet")
        #expect(EngineReadiness.of(.gigaam, localState: .failed("x"), keyStatus: .missing, localError: error)
                == .failed("Not published yet"))
        #expect(attention(.gigaam, .failed("x"), error: error)?.title == "GigaAM isn’t published yet")
        #expect(ModelStore.describeDownloadFailure(URLError(.cannotFindHost), host: "GitHub") == "Couldn’t reach GitHub.")
        #expect(ModelStore.describeDownloadFailure(URLError(.cannotFindHost)) == "Couldn’t reach Hugging Face.")
    }

    /// History names a GigaAM transcript by the version that wrote it, and Transcribe With by the one it would run.
    @Test func historyNamesTheVersion() {
        var result = TranscriptResult(text: "привет", engine: .gigaam, processingTime: 0.3)
        result.modelID = GigaAMEngine.Variant.v3e2e.rawValue
        let version = result.version(.transcription(.gigaam))
        #expect(VersionDetails.lines(for: version).first == "GigaAM v3 e2e")
        #expect(VersionDetails.lines(for: version).dropFirst().first == "gigaam-v3-e2e-ctc")
        let entry = TranscriptEntry(engine: .gigaam, audioDuration: 4, voicedSeconds: 3, audioFileName: "a.m4a",
                                    versions: [version])
        let settings = AppSettings.inMemory()
        settings.gigaamVariant = .multilingual
        let menu = VersionsMenu.make(for: entry, running: nil, readiness: { _ in .ready },
                                     engineName: settings.engineName)
        #expect(menu.versions.map(\.title) == ["GigaAM v3 e2e"])
        #expect(!menu.actions.contains { $0.kind == .transcription(.gigaam) }, "GigaAM ran on it: a version, not an action")

        let parakeet = TranscriptEntry(text: "hi", engine: .parakeet, audioDuration: 4, voicedSeconds: 3,
                                       audioFileName: "a.m4a")
        let offered = VersionsMenu.make(for: parakeet, running: nil, readiness: { _ in .ready },
                                        engineName: settings.engineName)
        #expect(offered.actions.first { $0.kind == .transcription(.gigaam) }?.title == "GigaAM Multilingual")
        #expect(offered.actions.first { $0.kind == .transcription(.geminiFlash) }?.title == "Gemini 3.8 Flash")
        let imports = ImportChoices.make(main: .gigaam, readiness: { _ in .ready }, engineName: settings.engineName)
        #expect(imports.first?.title == "GigaAM Multilingual")
    }
}

// MARK: - CLI

@Suite struct GigaAMCLITests {
    private func options(_ extra: String...) -> EngineCLI.Options? {
        EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
    }

    @Test func gigaamTakesAVersion() {
        #expect(options("--engine", "gigaam")?.engine == .gigaam)
        #expect(options("--engine", "gigaam")?.gigaamVariant == .v3, "v3 unless given")
        #expect(options("--engine", "gigaam", "--gigaam-version", "e2e")?.gigaamVariant == .v3e2e)
        #expect(options("--engine", "gigaam", "--gigaam-version", "multilingual")?.gigaamVariant == .multilingual)
        #expect(options("--engine", "gigaam", "--gigaam-version", "gigaam-v3-e2e-ctc")?.gigaamVariant == .v3e2e)
        #expect(options("--engine", "gigaam", "--gigaam-version", "v4") == nil)
        #expect(options("--engine", "parakeet", "--gigaam-version", "e2e") == nil, "GigaAM's only")
        #expect(options("--engine", "gigaam", "--parakeet-compute", "gpu") == nil, "Parakeet's diagnostic only")
        #expect(options("--engine", "gigaam", "--download")?.download == true)
        #expect(EngineCLI.Options.usage.contains("--engine parakeet|gigaam|geminiFlash|geminiCarbon "))
        #expect(EngineCLI.Options.usage.contains("[--gigaam-version v3|e2e|multilingual]"))
        #expect(EngineCLI.cloudModelLines().allSatisfy { !$0.contains("gigaam") }, "not a cloud model")
    }

    /// `--model-status` lists each version by what `--engine` and `--gigaam-version` take.
    @Test func modelStatusListsEachVersion() {
        let line = EngineCLI.modelStatusLine(.gigaam(.v3e2e), status: "installed", bytes: 443_698_324, path: "/M/x")
        #expect(line.hasPrefix("gigaam e2e") && line.contains("GigaAM v3 e2e") && line.hasSuffix("444 MB on disk · /M/x"))
        #expect(EngineCLI.modelStatusLine(.parakeet, status: "not installed", bytes: 0, path: "/p").hasPrefix("parakeet "))
        #expect(LocalModel.all.compactMap(\.variant).map(\.cliName) == ["v3", "e2e", "multilingual"])
    }
}

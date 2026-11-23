import Foundation
import Testing
@testable import TranscribeThing

// GigaAM v3, the one model on this Mac since Parakeet, GigaAM v3 e2e and Multilingual were retired: CTC greedy
// decoding and where a long recording is cut, its engine and choice, its install from its zip (never the real one,
// never the real Downloads folder) beside a retired version's folder, what launch loads, the lineup and Pasting rules it
// has from Parakeet, the fallback it is for Gemini, its copy and History's names (the retired versions' too, never
// offered), and the CLI. The model itself runs only on a real install (`--batch`, the app).

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
    /// GigaAM v3 is the one model on this Mac, named by its version everywhere, as Parakeet v3 was.
    @Test func gigaamV3IsTheOneModelOnThisMac() {
        #expect(EngineID.gigaam.rawValue == "gigaam" && ModelChoice.gigaam.rawValue == "gigaam")
        #expect(EngineID.localEngines == [.gigaam] && EngineID.default == .gigaam)
        let gigaam = EngineID.gigaam
        #expect(gigaam.isLocal && !gigaam.isCloud && !gigaam.isGemini && !gigaam.isRetired)
        #expect(gigaam.modelName == "GigaAM v3" && gigaam.displayName == "GigaAM v3" && gigaam.shortName == "GigaAM v3")
        #expect(gigaam.providerLine == "Sber · on your Mac")
        #expect(gigaam.factLine == "Russian · plain text, no punctuation · fast on the GPU")
        #expect(gigaam.badges == ["Private", "Offline"])
        #expect(gigaam.glyph == "G" && gigaam.symbolName != EngineID.parakeet.symbolName)
        #expect(gigaam.approxDownloadBytes == 409_369_862, "v3's zip")
        #expect(gigaam.provider == nil && gigaam.openRouterModelID == nil && gigaam.cloudTimeout == 0)
        #expect(gigaam.reasoningEfforts.isEmpty && gigaam.defaultReasoningEffort == nil)
        let choice = ModelChoice.gigaam
        #expect(choice.modelName == "GigaAM v3" && choice.compactName == "GigaAM v3" && choice.chipName == "GigaAM v3")
        #expect(choice.shortName == "GigaAM", "one word for chains and narrow columns")
        #expect(choice.isLocal && !choice.isGemini && choice.defaultColor == .green)
        #expect(Set(ModelChoice.allCases.map(\.defaultColor)).count == ModelChoice.allCases.count, "its own color")
    }

    /// Each version keeps its name, folder and zip: v3 to run, the retired two for History and their leftovers.
    @Test func eachVersionHasItsNameFilesAndSizes() {
        typealias V = GigaAMEngine.Variant
        #expect(V.allCases == [.v3, .v3e2e, .multilingual] && V.default == .v3)
        #expect(V.allCases.filter(\.isRetired) == [.v3e2e, .multilingual] && V.offered == [.v3])
        #expect(V.allCases.map(\.rawValue) == ["gigaam-v3-ctc", "gigaam-v3-e2e-ctc", "gigaam-multilingual-600m-ctc"])
        #expect(V.allCases.map(\.versionName) == ["v3", "v3 e2e", "Multilingual"])
        #expect(V.allCases.map(\.displayName) == ["GigaAM v3", "GigaAM v3 e2e", "GigaAM Multilingual"])
        #expect(V.allCases.map(\.zipName)
                == ["gigaam-v3-ctc.zip", "gigaam-v3-e2e-ctc.zip", "gigaam-multilingual-600m-ctc.zip"])
        #expect(V.allCases.map(\.downloadBytes) == [409_369_862, 409_641_058, 1_082_718_871])
        #expect(V.allCases.map(\.installedBytes) == [443_353_203, 443_698_324, 1_173_144_132])
        #expect(V.v3.sha256 == "c2d31e7dba58b5a5aed45abeb60ccc617c6a4ccb5531f30887d2a26e05e34f17")
        #expect(GigaAMSource.releaseURL(.v3).absoluteString
                == "https://github.com/xcviko/transcribe-thing/releases/download/gigaam-1/gigaam-v3-ctc.zip")
        let live = GigaAMSource.live(.v3)
        #expect(live.fileName == "gigaam-v3-ctc.zip" && live.expectedBytes == 409_369_862)
        #expect(live.localZip?.lastPathComponent == "gigaam-v3-ctc.zip", "the zip in Downloads still wins")
        #expect(live.localZip?.deletingLastPathComponent().lastPathComponent == "Downloads")
    }

    /// The app runs v3 alone: it's the one model on this Mac that downloads, loads and is deleted.
    @Test func theModelOnThisMacIsV3() {
        #expect(LocalModel.all == [.gigaam(.v3)])
        #expect(LocalModel(engine: .gigaam) == .gigaam(.v3))
        #expect(LocalModel(engine: .parakeet) == nil && LocalModel(engine: .geminiFlash) == nil)
        let v3 = LocalModel.gigaam(.v3)
        #expect(v3.id == "gigaam-v3-ctc" && v3.engine == .gigaam && v3.variant == .v3)
        #expect(v3.displayName == "GigaAM v3" && v3.modelID == "gigaam-v3-ctc")
        #expect(v3.approxDownloadBytes == 409_369_862 && v3.approxInstalledBytes == 443_353_203)
        #expect(v3.approxInstallPeakBytes == 409_369_862 + 443_353_203, "the zip and its unpacked folder at once")
        #expect(v3.downloadHost == "GitHub")
        #expect(Array(ModelStore.makeEngines(paths: .temporary()).keys) == [.gigaam(.v3)])
    }

    /// GigaAM is GigaAM wherever a job or History names it; a version's transcript is its own kind.
    @Test func choiceAndEngineMapBothWays() {
        #expect(ModelChoice(engine: .gigaam) == .gigaam && ModelChoice.gigaam.engine == .gigaam)
        #expect(ModelChoice(stored: "gigaam") == .gigaam && ModelChoice.read(["gigaam", "x"]) == [.gigaam])
        let kind = TranscriptVersionKind.gigaam(.v3e2e)
        #expect(kind.engine == .gigaam && kind.dictationModel == .gigaam && kind.isTranscript)
        #expect(kind.displayName == "GigaAM v3 e2e" && !kind.isOffered)
        #expect(TranscriptVersionKind.gigaam(.v3).isOffered)
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

    /// v3 installs beside what a retired version left, in a folder of its own: the leftover's folders are the ones
    /// that version's engine wrote (`RetiredLocalModel`), and deleting v3 leaves them.
    @Test func v3InstallsBesideARetiredVersionsFolder() async throws {
        let v3 = try FakeInstall(.v3)
        defer { v3.remove() }
        let e2e = try FakeInstall(.v3e2e, root: v3.root)
        let first = v3.engine(v3.source()), retired = e2e.engine(e2e.source())
        // As an older build left it.
        try await retired.download { _ in }
        try await first.download { _ in }
        #expect(first.isInstalled() && retired.isInstalled())
        #expect(try FileManager.default.contentsOfDirectory(atPath: v3.models.path).sorted()
                == ["gigaam-v3-ctc", "gigaam-v3-e2e-ctc"])
        #expect(RetiredLocalModel.gigaamV3e2e.folders(in: v3.models).map(\.path) == retired.storageURLs.map(\.path))
        #expect(Array(ModelStore.scanLeftovers(in: v3.models).keys) == [.gigaamV3e2e])
        try await first.deleteFiles()
        #expect(!first.isInstalled() && retired.isInstalled())
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

// MARK: - ModelStore with GigaAM v3

@MainActor
@Suite(.timeLimit(.minutes(1))) struct GigaAMModelStoreTests {
    private func makeStore(_ settings: AppSettings? = nil,
                           _ engines: [LocalModel: any LocalEngine]) -> ModelStore {
        ModelStore(paths: .temporary(), settings: settings ?? .inMemory(), engines: engines, gate: InferenceGate(),
                   freeDiskBytes: { 50_000_000_000 })
    }

    /// A store with a fake GigaAM v3, on disk or not, writing "by gigaam-v3-ctc".
    private func makeFake(_ settings: AppSettings, installed: Bool) -> (ModelStore, FakeEngine) {
        let fake = FakeEngine(.gigaam, installed: installed, transcript: "by gigaam-v3-ctc")
        return (makeStore(settings, [.gigaam(.v3): fake]), fake)
    }

    /// Downloaded from its zip through ModelStore: GigaAM v3 ends installed, not loaded, while nothing uses it.
    @Test func aDownloadThroughTheStoreInstallsV3() async throws {
        let install = try FakeInstall(.v3)
        defer { install.remove() }
        let settings = AppSettings.inMemory()
        settings.lineup.main = .gemini
        settings.lineup.setSwitchable(.gigaam, false)
        let store = makeStore(settings, [.gigaam(.v3): install.engine(install.source())])
        var finished: [LocalModel] = []
        store.onDownloadFinished = { finished.append($0) }
        store.download(.gigaam)
        #expect(store.state(model: .gigaam(.v3)).downloadProgress?.totalBytes == 409_369_862)
        await waitForObserved { store.state(of: .gigaam) == .installed }
        await store.waitForDownloadToSettle(.gigaam)
        #expect(finished == [.gigaam(.v3)] && store.lastErrors[.gigaam] == nil)
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

    /// Every GigaAM dictation is v3's, and its transcript says so.
    @Test func aDictationIsV3s() async throws {
        let (store, _) = makeFake(.inMemory(), installed: true)
        await store.refreshFromDisk()
        let account = OpenRouterAccount(keyStore: .inMemory(), client: OpenRouterClient(), debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: OpenRouterClient())
        let result = try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)),
                                                  engine: .gigaam)
        #expect(result.text == "by gigaam-v3-ctc" && result.modelID == "gigaam-v3-ctc")
        #expect(result.version().kind == .gigaam(.v3))
    }

    /// Launch loads GigaAM v3 when the lineup reaches it (a fresh install's main model), and leaves it on disk when
    /// it doesn't.
    @Test func launchLoadsGigaAMWhenTheLineupUsesIt() async throws {
        let used = AppSettings.inMemory()
        #expect(used.localModelsInUse == [.gigaam])
        let (store, fake) = makeFake(used, installed: true)
        store.start()
        await waitForObserved { store.state(of: .gigaam) == .ready }
        #expect(await fake.loadCount == 1)

        let unused = AppSettings.inMemory()
        unused.lineup.main = .gemini
        unused.lineup.setSwitchable(.gigaam, false)
        let (idle, idleFake) = makeFake(unused, installed: true)
        idle.start()
        await waitForObserved { idle.state(of: .gigaam) == .installed }
        #expect(await idleFake.loadCount == 0)
    }

    /// A download the lineup uses loads once it lands; delete frees it.
    @Test func aDownloadInUseLoadsAndDeleteFreesIt() async throws {
        let settings = AppSettings.inMemory()
        let (store, fake) = makeFake(settings, installed: false)
        await store.refreshFromDisk()
        store.download(.gigaam)
        await waitForObserved { store.state(of: .gigaam) == .ready }
        #expect(await fake.isLoaded)
        await store.delete(.gigaam)
        #expect(store.state(of: .gigaam) == .notInstalled && !fake.isInstalled())
    }

    /// The preview takes what retired models left too, and counts it in what's on disk.
    @Test func thePreviewListsLeftovers() {
        let store = ModelStore.preview(states: [.gigaam: .ready], leftovers: [.gigaamMultilingual: 1_000, .parakeet: 500])
        #expect(store.state(of: .gigaam) == .ready && store.state(model: .gigaam(.v3)) == .ready)
        #expect(store.leftoverModels == [.parakeet, .gigaamMultilingual], "Parakeet first")
        #expect(store.diskUsageBytes == 443_353_203 + 1_500)
        #expect(ModelStore.preview(states: [.parakeet: .ready]).state(of: .parakeet) == .notInstalled,
                "nothing runs Parakeet on this Mac")
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
    /// A fresh install starts on GigaAM v3, in its own green, Gemini 3.8 Flash its one step: Parakeet's shape.
    @Test func aFreshInstallStartsOnGigaAMv3() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gigaam, .gemini, .hydrogen, .neon, .carbon])
            #expect(settings.lineup.main == .gigaam && settings.lineup.cycle == [.gigaam, .gemini])
            #expect(settings.modelColors[.gigaam] == .green)
            #expect(settings.localModelsInUse == [.gigaam] && settings.usesLocalModel(.gigaam))
            #expect(settings.mainEngine == .gigaam && LocalModel(engine: settings.mainEngine) == .gigaam(.v3))
        }
    }

    /// A lineup stored before GigaAM had Parakeet: GigaAM takes its place, and Hydrogen and Neon, which came after,
    /// are appended in the default order, switched off. The main model, the rest of the order and hands-free stay.
    @Test func aLineupFromBeforeGigaAMHasItWhereParakeetWas() throws {
        try withDefaults { defaults in
            let old = #"{"main":"gemini","order":["carbon","gemini","parakeet"],"switchable":["parakeet","carbon"]}"#
            defaults.set(Data(old.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("carbon", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.carbon, .gemini, .gigaam, .hydrogen, .neon])
            #expect(settings.lineup.main == .gemini && settings.lineup.cycle == [.gemini, .gigaam, .carbon])
            #expect(settings.handsFreeChoice == .carbon && !settings.lineup.isSwitchable(.hydrogen))
            #expect(load(defaults).lineup.order == [.carbon, .gemini, .gigaam, .hydrogen, .neon], "stored as read")
        }
        try withDefaults { defaults in
            let older = #"{"main":"parakeet","order":["gemini","parakeet"],"switchable":["gemini"]}"#
            defaults.set(Data(older.utf8), forKey: SettingsKey.lineup.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gemini, .gigaam, .hydrogen, .neon, .carbon])
            #expect(settings.lineup.main == .gigaam && settings.lineup.cycle == [.gigaam, .gemini])
        }
    }

    /// Switched on beside another main model, GigaAM is in use and can be hands-free's model; switched off, nothing
    /// on this Mac is.
    @Test func gigaamInTheCycleIsInUse() throws {
        let settings = AppSettings.inMemory()
        settings.lineup.main = .gemini
        #expect(settings.localModelsInUse == [.gigaam], "switched on when it stopped being main")
        settings.handsFreeModel = .gigaam
        #expect(settings.handsFreeChoice == .gigaam)
        settings.lineup.setSwitchable(.gigaam, false)
        #expect(settings.handsFreeChoice == nil && settings.localModelsInUse.isEmpty)
        settings.lineup.main = .gigaam
        #expect(settings.mainEngine == .gigaam && settings.usesLocalModel(.gigaam))
        #expect(!settings.usesLocalModel(.geminiFlash), "a cloud model is no model on this Mac")
    }

    /// Pasting's rules from before GigaAM: it starts with the checks Parakeet had, once, and keeps its own after;
    /// Parakeet's own go with it. (Hydrogen and Neon, which came after, start with Flash's.)
    @Test func gigaamStartsWithParakeetsPastingRulesOnce() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["parakeet", "gemini", "carbon"]),
                         forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            defaults.set(try JSONEncoder().encode(["gemini"]), forKey: SettingsKey.modelsRemovingFinalPeriod.defaultsKey)
            defaults.set(true, forKey: SettingsKey.carbonPastingAdded.defaultsKey)
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace == [.gigaam, .gemini, .hydrogen, .neon, .carbon])
            #expect(settings.modelsRemovingFinalPeriod == [.gemini, .hydrogen, .neon])
            #expect(settings.addsSpace(by: .gigaam, in: .handsFree))
            #expect(defaults.bool(forKey: SettingsKey.gigaamPastingAdded.defaultsKey))
            #expect(try JSONDecoder().decode([String].self,
                                             from: #require(defaults.data(forKey: SettingsKey.modelsAddingSpace.defaultsKey)))
                    == ["gigaam", "gemini", "hydrogen", "neon", "carbon"], "stored back without Parakeet")
            settings.modelsAddingSpace.remove(.gigaam)
            settings.modelsRemovingFinalPeriod.insert(.gigaam)
            let reloaded = load(defaults)
            #expect(reloaded.modelsAddingSpace == [.gemini, .hydrogen, .neon, .carbon], "a choice made since stays")
            #expect(reloaded.modelsRemovingFinalPeriod == [.gemini, .hydrogen, .neon, .gigaam])
        }
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace.isEmpty && settings.modelsRemovingFinalPeriod.isEmpty)
            #expect(defaults.bool(forKey: SettingsKey.gigaamPastingAdded.defaultsKey))
        }
        #expect(AppSettings.withGigaAMLikeParakeet([.gemini], parakeet: true) == [.gemini, .gigaam])
        #expect(AppSettings.withGigaAMLikeParakeet([.gigaam, .gemini], parakeet: false) == [.gemini])
    }
}

// MARK: - Fallbacks

@MainActor
@Suite(.serialized) struct GigaAMFallbackTests {
    typealias H = DictationControllerTests

    /// Gemini refuses a dictation: the notice offers GigaAM v3 beside Retry once it's downloaded, never while it isn't
    /// there yet.
    @Test func aRefusedDictationOffersGigaAMv3OnceItsDownloaded() async throws {
        let cases: [(LocalModelState, Bool)] = [
            (.ready, true), (.installed, true), (.preparing(since: Date()), true),
            (.downloading(DownloadProgress(fraction: 0.3)), false), (.notInstalled, false),
        ]
        for (state, offered) in cases {
            let h = H.make(models: [.gigaam: state], keyStatus: .valid(KeyInfo()))
            h.settings.lineup.main = .gemini
            h.controller.transcribeOverride = { _, _ in throw AppError.openRouterRefused("refused") }
            let r = H.recording()
            h.controller.enqueue(r, engine: .geminiFlash)
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
            #expect(notice.actions.map(\.kind) == [.retry] + (offered ? [.retryWith(.gigaam)] : []), "\(state)")
            if offered { #expect(notice.actions.last?.title == "Use GigaAM v3 Instead") }
        }
    }

    /// A Gemini main model without a key: "Use GigaAM v3", and it becomes the main model.
    @Test func aKeylessGeminiMainModelOffersGigaAM() throws {
        let (rig, _) = SwitchModelControllerTests.make(key: .missing, models: [.gigaam: .ready])
        rig.h.settings.lineup.main = .gemini
        rig.h.controller.send(.handsFreeToggle)
        let notice = try #require(rig.h.toasts.notices.first)
        let use = try #require(notice.actions.first { $0.kind == .selectEngine(.gigaam) })
        #expect(use.title == "Use GigaAM v3")
        try rig.click(.selectEngine(.gigaam), in: notice.dedupeKey)
        #expect(rig.h.settings.lineup.main == .gigaam)
        #expect(rig.notice("engine.selected")?.title == "Now using GigaAM v3")
    }

    /// A dictation waiting for GigaAM to load says so, and offers no other model: Gemini never takes another model's
    /// place, and there's no other model on this Mac.
    @Test func waitingForGigaAMOffersNothingElse() async throws {
        let h = H.make(models: [.gigaam: .preparing(since: Date())], keyStatus: .valid(KeyInfo()))
        h.controller.waitNoticeDelayOverride = 0.05
        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .seconds(5))
            return TranscriptResult(text: "late", engine: engine, processingTime: 5)
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .gigaam)
        try await waitUntil { h.toasts.notices.contains { $0.dedupeKey == "slow.\(r.id)" } }
        let wait = try #require(h.toasts.notices.first { $0.dedupeKey == "slow.\(r.id)" })
        #expect(wait.title == "Getting GigaAM v3 ready…")
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

    /// Its size is the download's until it's done, then what it takes on this Mac, by the model and by the engine.
    @Test func sizesAreV3s() {
        #expect(ModelStatusText.describe(.notInstalled, model: .gigaam(.v3)).text == "Not downloaded · 409 MB")
        #expect(ModelStatusText.describe(.ready, model: .gigaam(.v3)).text == "Ready · 443 MB")
        #expect(ModelStatusText.describe(.notInstalled, engine: .gigaam).text == "Not downloaded · 409 MB")
        #expect(ModelStatusText.describe(.installed, engine: .gigaam).text == "Downloaded · 443 MB")
        let missing = attention(.gigaam, .notInstalled)
        #expect(missing?.title == "GigaAM v3 isn’t downloaded yet")
        #expect(missing?.body == "Download it (409 MB) to start dictating, or pick another model.")
        #expect(missing?.action == .download(.gigaam))
        #expect(AppError.modelNotDownloaded(.gigaam).notice(recordingID: nil, fallbackEngine: nil).body
                == "Download it (about 409 MB) or pick another model.")
    }

    /// Loading takes seconds on the GPU: the same words as before, nothing about minutes.
    @Test func loadingCopyIsAsBefore() {
        #expect(attention(.gigaam, .preparing(since: Date()))?.body
                == "Loading the model into memory. After installing it or updating macOS, this takes about half a minute.")
        #expect(AppError.modelPreparing(.gigaam).notice(recordingID: nil, fallbackEngine: nil).body
                == "The first run on this Mac takes a moment.")
    }

    /// Not published yet: said plainly, with what to do, wherever the failure shows.
    @Test func notPublishedSaysWhatToDo() {
        let error = AppError.modelNotPublished(.gigaam, file: "gigaam-v3-ctc.zip")
        let notice = error.notice(recordingID: nil, fallbackEngine: nil)
        #expect(notice.title == "GigaAM v3 isn’t published yet")
        #expect(notice.body == "Put gigaam-v3-ctc.zip in your Downloads folder, then download it again.")
        #expect(notice.actions.map(\.kind) == [.openHub(.models)])
        #expect(error.code == "modelNotPublished.gigaam" && !error.isRetryable)
        #expect(ModelFailure(error) == .notPublished && ModelFailure(error).label == "Not published yet")
        #expect(ModelStatusText.describe(.failed("x"), model: .gigaam(.v3), localError: error).text
                == "Not published yet")
        #expect(EngineReadiness.of(.gigaam, localState: .failed("x"), keyStatus: .missing, localError: error)
                == .failed("Not published yet"))
        #expect(attention(.gigaam, .failed("x"), error: error)?.title == "GigaAM v3 isn’t published yet")
        #expect(ModelStore.describeDownloadFailure(URLError(.cannotFindHost), host: "GitHub") == "Couldn’t reach GitHub.")
        #expect(ModelStore.describeDownloadFailure(URLError(.cannotFindHost)) == "Couldn’t reach the server.")
    }

    /// History names a GigaAM transcript by the version that wrote it, a retired one too; only v3 makes another.
    @Test func historyNamesTheVersion() {
        var result = TranscriptResult(text: "привет", engine: .gigaam, processingTime: 0.3)
        result.modelID = GigaAMEngine.Variant.v3e2e.rawValue
        let version = result.version()
        #expect(version.kind == .gigaam(.v3e2e), "the version that wrote it, from its model")
        #expect(VersionDetails.lines(for: version).first == "GigaAM v3 e2e")
        #expect(VersionDetails.lines(for: version).dropFirst().first == "gigaam-v3-e2e-ctc")
        let entry = TranscriptEntry(engine: .gigaam, audioDuration: 4, voicedSeconds: 3, audioFileName: "a.m4a",
                                    versions: [version])
        let menu = VersionsMenu.make(for: entry, running: nil, readiness: { _ in .ready })
        #expect(menu.versions.map(\.title) == ["GigaAM v3 e2e"])
        #expect(menu.actions.filter { $0.kind.engine == .gigaam }.map(\.kind) == [.gigaam(.v3)])
        let imports = ImportChoices.make(lineup: .default, readiness: { _ in .ready })
        #expect(imports.rows(.transcribe).first?.model.modelName == "GigaAM v3", "the main model first")
        let kinds = ImportChoices.Mode.allCases.flatMap { imports.rows($0) }.compactMap(\.kind)
        #expect(kinds.filter { $0.engine == .gigaam } == [.gigaam(.v3)])
    }
}

// MARK: - CLI

@Suite struct GigaAMCLITests {
    private func options(_ extra: String...) -> EngineCLI.Options? {
        EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
    }

    /// `--engine gigaam` runs v3. An older script's `--gigaam-version v3` still runs; the retired versions are refused,
    /// not run as v3.
    @Test func gigaamRunsV3Alone() {
        #expect(options("--engine", "gigaam")?.engine == .gigaam)
        #expect(options("--engine", "gigaam-v3")?.engine == .gigaam)
        #expect(options("--engine", "gigaam", "--gigaam-version", "v3")?.engine == .gigaam)
        #expect(options("--engine", "gigaam", "--gigaam-version", "gigaam-v3-ctc")?.engine == .gigaam)
        for retired in ["e2e", "multilingual", "gigaam-v3-e2e-ctc", "v4"] {
            #expect(options("--engine", "gigaam", "--gigaam-version", retired) == nil, "\(retired)")
        }
        #expect(options("--engine", "geminiFlash", "--gigaam-version", "v3") == nil, "GigaAM's only")
        #expect(options("--engine", "gigaam", "--download")?.download == true)
        #expect(EngineCLI.Options.usage.contains("--engine gigaam|geminiFlash|geminiHydrogen|geminiNeon|geminiCarbon "))
        #expect(!EngineCLI.Options.usage.contains("--gigaam-version") && !EngineCLI.Options.usage.contains("parakeet"))
        #expect(EngineCLI.cloudModelLines().allSatisfy { !$0.contains("gigaam") }, "not a cloud model")
    }

    /// `--model-status` lists GigaAM v3 by what `--engine` takes, and what a retired model left as no longer used.
    @Test func modelStatusListsV3AndLeftovers() {
        let line = EngineCLI.modelStatusLine(id: "gigaam", name: "GigaAM v3", status: "installed", bytes: 443_353_203,
                                             path: "/M/x")
        #expect(line.hasPrefix("gigaam ") && line.contains("GigaAM v3") && line.hasSuffix("443 MB on disk · /M/x"))
        let leftover = EngineCLI.modelStatusLine(id: "retired", name: "Parakeet v3", status: "no longer used",
                                                 bytes: 632_400_000, path: "/M/p")
        #expect(leftover.hasPrefix("retired ") && leftover.contains("Parakeet v3") && leftover.contains("no longer used"))
    }
}

// MARK: - Versions side by side

/// A history file as 0.5.2 and 0.5.3 wrote GigaAM's transcripts: one kind, "gigaam", its version in the metadata (or
/// none, from a test or a hand-made entry).
private let gigaamHistoryFile = #"""
{"version":1,"entries":[
 {"id":"6C2F3D5F-1111-4A7B-9C3D-5E6F7A8B9C01","createdAt":"2026-11-15T09:00:00.000Z","status":"success",
  "audioDuration":6,"voicedSeconds":5,"engine":"gigaam","text":"Открой hrome Deftuls MCP.","audioFileName":"one.m4a",
  "currentVersion":"gigaam",
  "versions":[{"kind":"parakeet","text":"Открой Chrome DevTools MCP.","metadata":{"createdAt":"2026-11-15T09:00:00.000Z"}},
              {"kind":"gigaam","text":"Открой hrome Deftuls MCP.","metadata":{"createdAt":"2026-11-15T09:00:01.000Z",
                "modelID":"gigaam-v3-e2e-ctc","processingTime":0.36}}]},
 {"id":"6C2F3D5F-2222-4A7B-9C3D-5E6F7A8B9C02","createdAt":"2026-11-15T08:00:00.000Z","status":"success",
  "audioDuration":4,"voicedSeconds":3,"engine":"gigaam","text":"привет","currentVersion":"gigaam",
  "versions":[{"kind":"gigaam","text":"привет","metadata":{"createdAt":"2026-11-15T08:00:00.000Z"}}]},
 {"id":"6C2F3D5F-3333-4A7B-9C3D-5E6F7A8B9C03","createdAt":"2026-11-15T07:00:00.000Z","status":"success",
  "audioDuration":4,"voicedSeconds":3,"engine":"parakeet","text":"Hello.","currentVersion":"parakeet",
  "versions":[{"kind":"parakeet","text":"Hello.","metadata":{"createdAt":"2026-11-15T07:00:00.000Z"}},
              {"kind":"gigaam","text":"hello","metadata":{"createdAt":"2026-11-15T07:00:01.000Z",
                "modelID":"gigaam-multilingual-600m-ctc"}}]}
]}
"""#

@Suite struct GigaAMVersionKindTests {
    typealias V = GigaAMEngine.Variant

    /// Each version's transcript is a kind of its own, stored as "gigaam:" and the version: no other kind starts so.
    @Test func eachVersionHasAKindOfItsOwn() {
        #expect(V.allCases.map { TranscriptVersionKind.gigaam($0).rawValue }
                == ["gigaam:gigaam-v3-ctc", "gigaam:gigaam-v3-e2e-ctc", "gigaam:gigaam-multilingual-600m-ctc"])
        for variant in V.allCases {
            let kind = TranscriptVersionKind.gigaam(variant)
            #expect(TranscriptVersionKind(rawValue: kind.rawValue) == kind)
            #expect(kind.displayName == variant.displayName && kind.shortName == variant.displayName)
            #expect(kind.progressTitle == "Transcribing with \(variant.displayName)…")
            #expect(kind.failureTitle == "Couldn’t transcribe with \(variant.displayName)")
            #expect(kind.isTranscript && !kind.isRewrite && !kind.isReadableByOlderBuilds && kind.gigaamVariant == variant)
        }
        #expect(TranscriptVersionKind(rawValue: "gigaam:gigaam-v4-ctc") == nil, "a newer build's version")
        let others: [TranscriptVersionKind] = EngineID.allCases.map(TranscriptVersionKind.transcription)
            + TranscriptVersionKind.rewrites + [.polish(), .translation(polished: true), .cleanup(of: .parakeet, by: .gpt6Luna),
                                                .selection(.gpt6Luna), .selectionTranslation(.geminiFlash)]
        #expect(others.allSatisfy { !$0.rawValue.hasPrefix("gigaam:") })
    }

    /// What can write a transcript: each engine offered, GigaAM as v3; and which kind a result is. A retired
    /// version's kind still reads, as History has it, and is never offered.
    @Test func transcriptsListV3Alone() {
        #expect(TranscriptVersionKind.transcripts == [.gigaam(.v3), .transcription(.geminiFlash),
                                                      .transcription(.geminiHydrogen), .transcription(.geminiNeon),
                                                      .transcription(.geminiCarbon)])
        #expect(TranscriptVersionKind.transcript(by: .gigaam) == .gigaam(.v3))
        #expect(TranscriptVersionKind.transcript(by: .gigaam, modelID: "gigaam-v3-e2e-ctc") == .gigaam(.v3e2e))
        #expect(TranscriptVersionKind.transcript(by: .parakeet, gigaam: .v3e2e) == .transcription(.parakeet))
        #expect(TranscriptResult(text: "x", engine: .gigaam, processingTime: 0).version().kind == .gigaam(.v3))
        #expect(TranscriptVersion(text: "x", engine: .gigaam).kind == .gigaam(.v3))
        for retired in [TranscriptVersionKind.gigaam(.v3e2e), .gigaam(.multilingual), .transcription(.parakeet)] {
            #expect(!retired.isOffered && !TranscriptVersionKind.transcripts.contains(retired), "\(retired)")
        }
    }

    /// 0.5.2 and 0.5.3 stored GigaAM's transcripts as "gigaam": each reads as the version its metadata names (v3 when
    /// it names none), still the current one where it was, nothing doubled; saved again, under its own kind.
    @Test func oldGigaAMEntriesReadAsTheirVersion() throws {
        let entries = try HistoryStore.readEntries(from: Data(gigaamHistoryFile.utf8))
        #expect(entries.count == 3)
        #expect(entries[0].versions.map(\.kind) == [.transcription(.parakeet), .gigaam(.v3e2e)])
        #expect(entries[0].currentKind == .gigaam(.v3e2e) && entries[0].text == "Открой hrome Deftuls MCP.")
        #expect(entries[0].engine == .gigaam && entries[0].version(.gigaam(.v3e2e))?.metadata.processingTime == 0.36)
        #expect(entries[1].versions.map(\.kind) == [.gigaam(.v3)] && entries[1].currentKind == .gigaam(.v3))
        #expect(entries[2].versions.map(\.kind) == [.transcription(.parakeet), .gigaam(.multilingual)])
        #expect(entries[2].currentKind == .transcription(.parakeet))

        let data = try JSONEncoder().encode(entries[0])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["currentVersion"] as? String == "gigaam:gigaam-v3-e2e-ctc")
        let kinds = (json["versions"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }
        #expect(kinds == ["parakeet", "gigaam:gigaam-v3-e2e-ctc"])
        #expect(try JSONDecoder().decode(TranscriptEntry.self, from: data) == entries[0])
    }

    /// An older build can't read a version's kind. The flat fields hold the current version's text, which it takes as
    /// its own GigaAM transcript, so the entry and that text stay. Read back with versions this build doesn't know
    /// (a newer build's), the same happens here: the entry stays, those versions go.
    @Test func olderBuildsKeepTheEntryAndTheCurrentText() throws {
        func version(_ kind: TranscriptVersionKind, _ text: String) -> TranscriptVersion {
            TranscriptVersion(kind: kind, text: text, metadata: TranscriptMetadata(modelID: kind.gigaamVariant?.rawValue))
        }
        let entry = TranscriptEntry(engine: .parakeet, audioDuration: 4, voicedSeconds: 3, audioFileName: "a.m4a",
                                    versions: [version(.transcription(.parakeet), "Open Chrome."),
                                               version(.gigaam(.v3), "открой хром"),
                                               version(.gigaam(.v3e2e), "Открой hrome.")])
        let data = try JSONEncoder().encode(entry)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["text"] as? String == "Открой hrome." && json["engine"] as? String == "gigaam")

        let newer = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "gigaam:gigaam-", with: "gigaam:gigaam-v9-")
        let read = try JSONDecoder().decode(TranscriptEntry.self, from: Data(newer.utf8))
        #expect(read.id == entry.id && read.status == .success)
        #expect(read.versions.map(\.kind) == [.transcription(.parakeet), .gigaam(.v3)])
        #expect(read.currentKind == .gigaam(.v3) && read.text == "Открой hrome.",
                "the flat text, as an older build's own GigaAM transcript")
    }
}

@MainActor
@Suite struct GigaAMTranscribeWithTests {
    private func readiness(_ store: ModelStore) -> (TranscriptVersionKind) -> EngineReadiness {
        { HubContext.readiness(of: $0, models: store, keyStatus: .valid(KeyInfo()), provider: .openRouter) }
    }

    private func store(_ state: LocalModelState) -> ModelStore {
        ModelStore.preview(states: [.gigaam: state], settings: .inMemory())
    }

    private func parakeet(status: TranscriptStatus = .success) -> TranscriptEntry {
        TranscriptEntry(text: status == .success ? "Open Chrome." : "", engine: .parakeet, status: status,
                        audioDuration: 6, voicedSeconds: 5, audioFileName: "a.m4a")
    }

    private func gigaam(_ actions: [VersionsMenu.Action]) -> [VersionsMenu.Action] {
        actions.filter { $0.kind.engine == .gigaam }
    }

    /// A Parakeet transcript's Transcribe With offers GigaAM v3, first, as the engines go; not downloaded, it's
    /// listed, disabled, saying so (no download from here).
    @Test func gigaamV3IsTheOneGigaAMItem() {
        let menu = VersionsMenu.make(for: parakeet(), running: nil, readiness: readiness(store(.installed)))
        #expect(gigaam(menu.actions).map(\.kind) == [.gigaam(.v3)])
        #expect(gigaam(menu.actions).map(\.title) == ["GigaAM v3"] && gigaam(menu.actions)[0].isEnabled)
        #expect(menu.actions.map(\.kind).prefix(2) == [.gigaam(.v3), .transcription(.geminiFlash)])

        let missing = VersionsMenu.make(for: parakeet(), running: nil, readiness: readiness(store(.notInstalled)))
        #expect(gigaam(missing.actions).map(\.title) == ["GigaAM v3 · Not downloaded"])
        #expect(gigaam(missing.actions).map(\.isEnabled) == [false])
    }

    /// The versions the retired ones wrote stay, to switch to; only v3 is offered, and not once it's there. A failed
    /// dictation retries with v3.
    @Test func retiredVersionsAreVersionsNeverItems() {
        let models = store(.ready)
        var entry = parakeet()
        entry.addVersion(TranscriptVersion(kind: .gigaam(.v3e2e), text: "Открой hrome.", metadata: TranscriptMetadata()))
        entry.addVersion(TranscriptVersion(kind: .gigaam(.multilingual), text: "open chrome", metadata: TranscriptMetadata()))
        var menu = VersionsMenu.make(for: entry, running: nil, readiness: readiness(models))
        #expect(menu.versions.map(\.title) == ["Parakeet v3", "GigaAM v3 e2e", "GigaAM Multilingual"])
        #expect(menu.versions.map(\.isCurrent) == [false, false, true])
        #expect(gigaam(menu.actions).map(\.kind) == [.gigaam(.v3)])
        entry.addVersion(TranscriptVersion(kind: .gigaam(.v3), text: "открой хром", metadata: TranscriptMetadata()))
        menu = VersionsMenu.make(for: entry, running: nil, readiness: readiness(models))
        #expect(gigaam(menu.actions).isEmpty)

        let retry = VersionsMenu.make(for: parakeet(status: .failed), running: nil, readiness: readiness(models))
        #expect(retry.isRetry && gigaam(retry.actions).map(\.kind) == [.gigaam(.v3)])
        #expect(!retry.actions.contains { $0.kind == .transcription(.parakeet) }, "Parakeet never retries")
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct GigaAMRetiredVersionControllerTests {
    private typealias H = DictationControllerTests

    /// Asked for a retired version (a menu from an older build, a stale action): nothing loads or runs, and nothing
    /// is made under its name. v3's own is made as v3's.
    @Test func aRetiredVersionIsNeverMade() async throws {
        let fake = FakeEngine(.gigaam, installed: true, transcript: "by gigaam-v3-ctc")
        let store = ModelStore(paths: .temporary(), settings: .inMemory(), engines: [.gigaam(.v3): fake],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        await store.refreshFromDisk()
        let h = H.make(store: store, keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let recording = H.recording()
        let entry = TranscriptEntry(id: recording.id, createdAt: recording.startedAt, text: "Open Chrome.",
                                    engine: .parakeet, audioDuration: recording.duration, voicedSeconds: 1,
                                    audioFileName: h.history.saveAudio(recording))
        h.history.upsert(entry)
        for retired in [TranscriptVersionKind.gigaam(.v3e2e), .gigaam(.multilingual), .transcription(.parakeet)] {
            h.controller.makeVersion(retired, of: entry)
            #expect(h.controller.homeWork.isEmpty && h.controller.runningVersions.isEmpty, "\(retired)")
        }
        h.controller.retry(entry, with: .parakeet)
        #expect(h.controller.homeWork.isEmpty)
        #expect(await fake.transcribeCount == 0)

        h.controller.makeVersion(.gigaam(.v3), of: entry)
        try await waitUntil(timeout: .seconds(10)) { h.history.entry(id: entry.id)?.hasVersion(.gigaam(.v3)) == true }
        let made = try #require(h.history.entry(id: entry.id))
        #expect(made.versions.map(\.kind) == [.transcription(.parakeet), .gigaam(.v3)])
        #expect(made.text == "by gigaam-v3-ctc" && made.version(.gigaam(.v3))?.metadata.modelID == "gigaam-v3-ctc")
    }
}

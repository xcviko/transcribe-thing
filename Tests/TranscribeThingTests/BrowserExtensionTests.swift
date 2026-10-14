import CryptoKit
import Darwin
import Foundation
import Testing
@testable import TranscribeThing

// The browser extension's side of the app: its messages (`BrowserProtocol`, `NativeFrame`), the native messaging
// host (`NativeHost`), the socket the app listens on (`BrowserBridge`), the files it puts in place
// (`BrowserExtension`), and what its word does to call detection (`BrowserPages`, `CallWatch`, `CallDetector`).
// The extension's own scripts are tested with node: `node --test BrowserExtension/tests/*.test.mjs`.

private let chromeID = "com.google.Chrome"
private let profileID = "5f0c8a52-profile-one"

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func tab(_ id: Int, host: String, title: String, inCall: Bool, mic: Bool, muted: Bool? = nil,
                 room: String? = nil, audible: Bool = false) -> [String: Any] {
    var tab: [String: Any] = ["id": id, "windowId": 1, "host": host, "title": title, "audible": audible,
                              "inCall": inCall, "micLive": mic, "muted": muted.map { $0 as Any } ?? NSNull()]
    if let room { tab["room"] = room }
    return tab
}

/// A folder under /tmp short enough for a socket's path.
private func shortFolder() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/tt-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Messages

@Suite struct BrowserProtocolTests {
    @Test func messagesAreReadForgivingly() {
        #expect(BrowserProtocol.decode(json(["v": 1, "type": "hello", "installID": "abc", "version": "1.0.0"]))
            == .hello(installID: "abc", version: "1.0.0"))
        #expect(BrowserProtocol.decode(json(["v": 1, "type": "hello"])) == nil, "a hello without its id says nothing")
        #expect(BrowserProtocol.decode(json(["type": "host", "browserID": chromeID])) == .host(browserID: chromeID))
        #expect(BrowserProtocol.decode(json(["type": "gone", "id": 4])) == .gone(tabID: 4))
        #expect(BrowserProtocol.decode(json(["type": "audible", "tabs": [1, 2]])) == .audible([1, 2]))
        let meet = BrowserProtocol.Tab(id: 3, windowID: 1, host: "meet.google.com", room: "abc-defg-hij",
                                       title: "Meet - abc-defg-hij", inCall: true, micLive: true, muted: false)
        #expect(BrowserProtocol.decode(json(["v": 1, "type": "tab", "tab": tab(3, host: "meet.google.com",
            title: "Meet - abc-defg-hij", inCall: true, mic: true, muted: false, room: "abc-defg-hij")])) == .tab(meet))
        #expect(BrowserProtocol.decode(json(["type": "state", "tabs": [["id": 9]], "future": true]))
            == .state(tabs: [BrowserProtocol.Tab(id: 9, host: "", title: "", inCall: false, micLive: false)],
                      audible: nil), "fields it doesn't know are skipped, ones missing are off")
        #expect(BrowserProtocol.decode(json(["v": 2, "type": "audio", "tab": 3])) == .other("audio"))
        #expect(BrowserProtocol.decode(Data("not json".utf8)) == nil)
    }

    @Test func framesAreSplitAndJoined() throws {
        let one = Data(#"{"type":"gone","id":1}"#.utf8)
        let two = Data(#"{"type":"gone","id":2}"#.utf8)
        let stream = NativeFrame.encode(one) + NativeFrame.encode(two)
        #expect(stream.count == one.count + two.count + 8)
        var reader = NativeFrame.Reader()
        #expect(try reader.push(stream.prefix(3)).isEmpty)
        #expect(try reader.push(stream.dropFirst(3).prefix(30)) == [one])
        #expect(try reader.push(stream.dropFirst(33)) == [two])
        var broken = NativeFrame.Reader()
        var huge = UInt32(NativeFrame.maxLength + 1)
        #expect(throws: NativeFrame.TooLong.self) { try broken.push(Data(bytes: &huge, count: 4)) }
    }

    /// The id the app lets in is the one the manifest's key makes, wherever the folder is loaded from.
    @Test func theExtensionsIDComesFromItsKey() throws {
        let source = try #require(BrowserExtension.repositorySource)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        let key = try #require((manifest as? [String: Any])?["key"] as? String)
        let digest = SHA256.hash(data: try #require(Data(base64Encoded: key)))
        let id = digest.prefix(16).flatMap { [$0 >> 4, $0 & 0xF] }
            .map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }.joined()
        #expect(id == BrowserProtocol.extensionID)
        #expect(BrowserProtocol.origin == "chrome-extension://jmbjndmjbpmemomladndhokpgbhbbnhn/")
    }

    @Test func servicesFromHosts() {
        #expect(CallService.of(host: "meet.google.com") == .meet)
        #expect(CallService.of(host: "app.slack.com") == .slack)
        #expect(CallService.of(host: "us05web.zoom.us") == .zoom)
        #expect(CallService.of(host: "app.zoom.us") == .zoom)
        #expect(CallService.of(host: "discord.com") == .discord)
        #expect(CallService.of(host: "ptb.discord.com") == .discord)
        #expect(CallService.of(host: "telemost.yandex.ru") == .telemost)
        #expect(CallService.of(host: "telemost.360.yandex.ru") == .telemost)
        #expect(CallService.of(host: "web.telegram.org") == .telegram)
        #expect(CallService.of(host: "google.com") == nil)
        #expect(CallService.of(host: "notslack.com") == nil)
        #expect(CallService.of(host: "zoom.us.evil.example") == nil)
    }
}

// MARK: - Bridge

private final class Box: @unchecked Sendable {
    var value = false
}

@MainActor
@Suite(.serialized) struct BrowserBridgeTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    @Test func aProfileConnectsAndTellsItsTabs() throws {
        let clock = Clock()
        let bridge = BrowserBridge(socketPath: nil, now: { clock.now })
        bridge.log = DiagnosticLog()
        let browser = BrowserExtension(browsers: [], places: .temporary(), bridge: bridge)
        bridge.opened(1)
        bridge.received(json(["type": "host", "browserID": chromeID]), from: 1)
        #expect(browser.connections.isEmpty, "a host is no profile until the extension says hello")
        #expect(bridge.pages(of: chromeID) == nil)
        bridge.received(json(["v": 1, "type": "hello", "installID": profileID, "version": "1.0.0"]), from: 1)
        #expect(browser.connections.map(\.id) == [profileID])
        #expect(browser.connections.first?.browserID == chromeID && browser.connections.first?.version == "1.0.0")

        bridge.received(json(["type": "tab", "tab": tab(7, host: "app.slack.com", title: "general - Slack",
                                                       inCall: true, mic: true, muted: false)]), from: 1)
        bridge.received(json(["type": "audible", "tabs": [7, 12]]), from: 1)
        let pages = try #require(bridge.pages(of: chromeID))
        #expect(pages.pages.count == 1)
        let id = bridge.tabID(profileID, 7)
        #expect(pages.pages.first?.id == id && pages.pages.first?.service == .slack)
        #expect(id.raw >= BrowserBridge.firstTabID, "never an id the tab strip gives")
        #expect(pages.audible == [id, bridge.tabID(profileID, 12)])
        #expect(bridge.pages(of: "com.brave.Browser") == nil)

        // The heartbeat lists every tab with something: one missing from it has ended.
        bridge.received(json(["type": "state", "tabs": [], "audible": []]), from: 1)
        #expect(bridge.pages(of: chromeID)?.pages.isEmpty == true)
        #expect(bridge.pages(of: chromeID)?.ended == [id])

        // Silent for too long: gone.
        clock.now += BrowserBridge.silentAfter - 1
        bridge.prune()
        #expect(browser.connections.count == 1)
        clock.now += 2
        bridge.prune()
        #expect(browser.connections.isEmpty)
        #expect(bridge.pages(of: chromeID) == nil)
    }

    @Test func profilesAreApartAndAReturningProfileIsOne() {
        let bridge = BrowserBridge(socketPath: nil)
        bridge.log = DiagnosticLog()
        for (peer, install) in [(1, "one"), (2, "two")] {
            bridge.opened(peer)
            bridge.received(json(["type": "host", "browserID": chromeID]), from: peer)
            bridge.received(json(["type": "hello", "installID": install, "version": "1"]), from: peer)
            bridge.received(json(["type": "tab", "tab": tab(5, host: "meet.google.com", title: "Meet",
                                                           inCall: true, mic: true)]), from: peer)
        }
        let ids = Set(bridge.pages(of: chromeID)?.pages.map(\.id) ?? [])
        #expect(ids.count == 2, "the same tab number in two profiles is two tabs")
        // The first profile's host starts again: its old connection is dropped.
        bridge.opened(3)
        bridge.received(json(["type": "host", "browserID": chromeID]), from: 3)
        bridge.received(json(["type": "hello", "installID": "one", "version": "2"]), from: 3)
        #expect(bridge.connections.map(\.id).sorted() == ["one", "two"])
        #expect(bridge.connections.first { $0.id == "one" }?.version == "2")
        bridge.closed(2)
        #expect(bridge.connections.map(\.id) == ["one"])
    }

    /// The real socket, the real host, and a hello that waits for the app to start.
    @Test func theHostRelaysBothWaysAndWaitsForTheApp() async throws {
        let folder = try shortFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("b.sock").path
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        #expect(pipe(&input) == 0 && pipe(&output) == 0)
        let host = NativeHost(input: input[0], output: output[1], socketPath: socket, browserID: chromeID, retry: 0.05)
        let finished = NSLock(), done = Box()
        Thread {
            host.run()
            finished.withLock { done.value = true }
        }.start()
        func send(_ object: [String: Any]) { UnixSocket.writeAll(input[1], NativeFrame.encode(json(object))) }

        // The app isn't running yet: the hello is kept, the tab dropped (stale by then).
        send(["v": 1, "type": "hello", "installID": profileID, "version": "1.0.0"])
        send(["v": 1, "type": "tab", "tab": tab(3, host: "meet.google.com", title: "Meet", inCall: true, mic: true)])
        try await Task.sleep(for: .milliseconds(150))

        let bridge = BrowserBridge(socketPath: socket)
        bridge.log = DiagnosticLog()
        bridge.start()
        defer { bridge.stop() }
        try await waitUntil { bridge.connections.count == 1 }
        #expect(bridge.connections.first?.browserID == chromeID && bridge.connections.first?.id == profileID)
        #expect(bridge.pages(of: chromeID)?.pages.isEmpty == true)
        let mode = try FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        send(["v": 1, "type": "tab", "tab": tab(3, host: "meet.google.com", title: "Meet", inCall: true, mic: true)])
        try await waitUntil { bridge.pages(of: chromeID)?.pages.count == 1 }

        // The browser lets go: the host ends, and the app hears the profile go.
        close(input[1])
        try await waitUntil { finished.withLock { done.value } }
        try await waitUntil { bridge.connections.isEmpty }
        close(output[1])
        var kinds: [String] = []
        while let frame = UnixSocket.readFrame(output[0]) {
            kinds.append((try? JSONSerialization.jsonObject(with: frame) as? [String: Any])?["type"] as? String ?? "?")
        }
        close(output[0])
        close(input[0])
        #expect(kinds.contains("app"), "the extension hears the app is there, to send everything")
        #expect(kinds.contains("welcome"))
    }

    /// Only a browser's origin makes the executable the host; the browser is the outermost app it runs in.
    @Test func theHostIsKnownByItsArgument() {
        #expect(NativeHostCLI.handles(["chrome-extension://jmbjndmjbpmemomladndhokpgbhbbnhn/"]))
        #expect(!NativeHostCLI.handles([]))
        #expect(!NativeHostCLI.handles(["--snapshots", "build"]))
        #expect(NativeHost.bundleID(ofExecutable: "/Applications/Safari.app/Contents/MacOS/Safari") == "com.apple.Safari")
        #expect(NativeHost.bundleID(ofExecutable: "/usr/bin/true") == nil)
    }

    @Test func socketPathsFitOrMove() {
        let short = AppPaths(root: URL(fileURLWithPath: "/Users/sam/Library/Application Support/transcribe-thing"))
        #expect(BrowserBridge.socketPath(for: short).hasSuffix("transcribe-thing/browser.sock"))
        let long = AppPaths(root: URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 90) + "/transcribe-thing"))
        let moved = BrowserBridge.socketPath(for: long)
        #expect(UnixSocket.fits(moved) && moved.hasSuffix("transcribe-thing-browser.sock"))
    }
}

// MARK: - Files

@MainActor
@Suite struct BrowserExtensionFilesTests {
    final class Seen {
        var opened: [(URL, URL)] = []
        var revealed: [URL] = []
    }

    private func places(_ root: URL, executable: String = "/Applications/transcribe-thing.app/Contents/MacOS/transcribe-thing",
                        seen: Seen = Seen()) -> BrowserExtension.Places {
        BrowserExtension.Places(
            folder: root.appendingPathComponent("Browser Extension"), browserSupport: root.appendingPathComponent("Support"),
            source: { BrowserExtension.repositorySource }, executable: { URL(fileURLWithPath: executable) },
            open: { seen.opened.append(($0, $1)) }, reveal: { seen.revealed.append($0) })
    }

    private static let chrome = BrowserExtension.Browser(id: chromeID, name: "Google Chrome", family: .chromium,
                                                          appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    private static let arc = BrowserExtension.Browser(id: "company.thebrowser.Browser", name: "Arc", family: .chromium,
                                                      appURL: URL(fileURLWithPath: "/Applications/Arc.app"))

    private func manifest(_ root: URL, _ data: String) throws -> [String: Any] {
        let url = root.appendingPathComponent("Support").appendingPathComponent(data)
            .appendingPathComponent("NativeMessagingHosts/dev.transcribe_thing.bridge.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func prepareCopiesTheExtensionAndTellsTheBrowser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let browser = BrowserExtension(browsers: [Self.chrome], places: places(root, seen: seen))
        let folder = try browser.prepare(Self.chrome)
        #expect(folder == root.appendingPathComponent("Browser Extension/Chromium", isDirectory: true))
        for file in ["manifest.json", "page.js", "relay.js", "background.js"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path))
        }
        let written = try manifest(root, "Google/Chrome")
        #expect(written["name"] as? String == "dev.transcribe_thing.bridge")
        #expect(written["type"] as? String == "stdio")
        #expect(written["path"] as? String == "/Applications/transcribe-thing.app/Contents/MacOS/transcribe-thing")
        #expect(written["allowed_origins"] as? [String] == ["chrome-extension://jmbjndmjbpmemomladndhokpgbhbbnhn/"])

        // Arc keeps its settings one level down.
        _ = try browser.prepare(Self.arc)
        #expect(try manifest(root, "Arc/User Data")["name"] as? String == "dev.transcribe_thing.bridge")

        browser.openInstall(Self.chrome)
        #expect(seen.opened.map(\.0.absoluteString) == ["chrome://extensions/"])
        #expect(seen.opened.map(\.1) == [Self.chrome.appURL])
        #expect(seen.revealed == [folder])
        #expect(BrowserExtension.extensionsPage("com.microsoft.edgemac")?.absoluteString == "edge://extensions/")
        #expect(BrowserExtension.extensionsPage("com.brave.Browser")?.absoluteString == "brave://extensions/")
    }

    @Test func firefoxAndSafariAreNotYet() {
        let browser = BrowserExtension(browsers: [], places: .temporary())
        let firefox = BrowserExtension.Browser(id: "org.mozilla.firefox", name: "Firefox", family: .firefox,
                                               appURL: URL(fileURLWithPath: "/Applications/Firefox.app"))
        #expect(throws: BrowserExtension.PrepareError.notYet("Firefox")) { try browser.prepare(firefox) }
        #expect(BrowserExtension.PrepareError.notYet("Firefox").errorDescription?.contains("Firefox") == true)
    }

    /// The app moved and was updated: at launch the browsers prepared before reach the new one and load the new
    /// extension; a browser never prepared is left alone.
    @Test func launchPreparesAgainWhatWasPrepared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = BrowserExtension(browsers: [Self.chrome], places: places(root, executable: "/Users/me/Downloads/old"))
        let folder = try before.prepare(Self.chrome)
        try Data("stale".utf8).write(to: folder.appendingPathComponent("page.js"))

        let after = BrowserExtension(browsers: [Self.chrome], places: places(root))
        after.reprepare()
        #expect(try manifest(root, "Google/Chrome")["path"] as? String
            == "/Applications/transcribe-thing.app/Contents/MacOS/transcribe-thing")
        let source = try #require(BrowserExtension.repositorySource)
        #expect(try Data(contentsOf: folder.appendingPathComponent("page.js"))
            == Data(contentsOf: source.appendingPathComponent("page.js")))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Support/Microsoft Edge").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Browser Extension").path)
        #expect(leftovers == ["Chromium"])
    }
}

// MARK: - Calls

/// A browser on a made-up Mac: what the HAL says Chrome does, what the extension says (through a `BrowserBridge` fed
/// directly), and what the tab strip and the Mute button would say through Accessibility.
@MainActor
final class PageRig {
    var mic = false
    var sound = false
    /// The tab strip's titles, and what the Mute button says, for Accessibility reads.
    var stripTabs: [String] = []
    var mute: MuteState = .unknown("test")
    var stripReads = 0
    let bridge = BrowserBridge(socketPath: nil)
    var watch: CallWatch!
    var steps: [(time: Double, event: CallDetector.Event)] = []

    static let chrome = CallApp(bundleID: chromeID)!

    init(extensionInstalled: Bool = true) {
        bridge.log = DiagnosticLog()
        let sensors = CallWatch.Sensors(
            processRecords: { [] }, app: { CallApp(bundleID: $0.bundleID) }, pids: { _ in [] },
            canReadWindows: { true },
            readWindow: { [unowned self] _, _, following, done in
                stripReads += 1
                let windows = [BrowserTabs.Window(title: stripTabs.first,
                                                  tabs: stripTabs.map { BrowserTabs.Tab(title: $0, selected: nil) })]
                done(CallMuteReader.Report(read: MuteRead(state: mute, inCall: nil, detail: ""), isBrowser: true,
                                           tab: BrowserTabs.callTab(in: windows, following: following), windowCount: 1))
            },
            releaseWindows: {},
            pages: { [unowned self] app in bridge.pages(of: app.id) })
        watch = CallWatch(sensors: sensors)
        guard extensionInstalled else { return }
        bridge.opened(1)
        bridge.received(json(["type": "host", "browserID": chromeID]), from: 1)
        bridge.received(json(["type": "hello", "installID": profileID, "version": "1.0.0"]), from: 1)
    }

    func tell(_ id: Int, host: String, title: String, inCall: Bool, mic: Bool, muted: Bool? = nil) {
        bridge.received(json(["type": "tab", "tab": tab(id, host: host, title: title, inCall: inCall, mic: mic,
                                                       muted: muted)]), from: 1)
    }

    func id(_ tab: Int) -> BrowserTabs.TabID { bridge.tabID(profileID, tab) }

    /// Looks every 0.5 s from `from` through `to`.
    func poll(_ from: Double, _ to: Double) {
        for tenth in stride(from: Int((from * 10).rounded()), through: Int((to * 10).rounded()), by: 5) {
            let time = Double(tenth) / 10
            let record = CoreAudioHAL.ProcessRecord(objectID: 10, pid: 100, bundleID: chromeID, isRunningInput: mic,
                                                    isRunningOutput: sound, inputDevices: [], outputDevices: [])
            steps += watch.poll(at: time, records: [record]).map { (time, $0) }
        }
    }

    var ended: [CallDetector.Call] {
        steps.compactMap { if case .ended(let call) = $0.event { call } else { nil } }
    }

    var started: [CallDetector.Call] {
        steps.compactMap { if case .started(let call) = $0.event { call } else { nil } }
    }
}

@MainActor
@Suite struct BrowserCallTests {
    private static let slack = "general (Channel) - V-Soft - Slack"

    /// The split this was made for: mid-huddle you switch Slack channels and then another tab. Slack retitles its
    /// tab and the huddle's tab is no longer the one in front; the extension's tab is the same tab all along, so the
    /// huddle stays one call, and the tab strip isn't read at all while the page says the mute.
    @Test func aSlackHuddleSurvivesSwitchingChannelsAndTabs() throws {
        let rig = PageRig()
        rig.mic = true
        rig.sound = true
        rig.stripTabs = [Self.slack + " - Microphone recording", "Inbox - Gmail"]
        rig.tell(7, host: "app.slack.com", title: Self.slack, inCall: true, mic: true, muted: false)
        rig.poll(0, 25)
        let started = try #require(rig.started.first)
        #expect(started.startedAt == 0)
        #expect(rig.watch.detector.call?.tab?.id == rig.id(7))
        #expect(rig.watch.detector.call?.tab?.service == .slack)
        #expect(rig.watch.detector.call?.toldByPage == true)
        let readsBefore = rig.stripReads
        #expect(readsBefore <= 1, "only the read before the page first told")

        // Another channel, then another tab in front: Gmail now, with the huddle's tab in the background.
        rig.tell(7, host: "app.slack.com", title: "random (Channel) - V-Soft - Slack", inCall: true, mic: true,
                 muted: false)
        rig.stripTabs = ["Inbox - Gmail", "random (Channel) - V-Soft - Slack - Microphone recording"]
        rig.poll(25.5, 40)
        rig.tell(9, host: "mail.google.com", title: "Inbox - Gmail", inCall: false, mic: false)
        rig.poll(40.5, 90)
        #expect(rig.ended.isEmpty, "one huddle, not two")
        #expect(rig.started.count == 1)
        #expect(rig.watch.detector.call?.tab?.id == rig.id(7))
        #expect(rig.watch.detector.call?.tab?.page == "random (Channel) - V-Soft - Slack")
        #expect(rig.stripReads == readsBefore)
        #expect(rig.watch.lastRead?.fromPage == true && rig.watch.lastRead?.read.state == .live)
    }

    /// The page's mute counts like the Mute button's; leaving ends the call at once, though the mic is still on.
    @Test func theMuteComesFromThePageAndLeavingEndsTheCallAtOnce() throws {
        let rig = PageRig()
        rig.mic = true
        rig.sound = true
        rig.tell(3, host: "meet.google.com", title: "Meet - abc-defg-hij", inCall: true, mic: true, muted: false)
        rig.poll(0, 29.5)
        rig.tell(3, host: "meet.google.com", title: "Meet - abc-defg-hij", inCall: true, mic: true, muted: true)
        rig.poll(30, 39.5)
        #expect(rig.watch.detector.call?.mutedSince == 30)
        #expect(rig.watch.muteEverKnown)
        rig.tell(3, host: "meet.google.com", title: "Meet - abc-defg-hij", inCall: true, mic: true, muted: false)
        rig.poll(40, 49.5)
        // Leave call: the peer connections close; the page still holds the mic for a moment.
        rig.tell(3, host: "meet.google.com", title: "Meet - abc-defg-hij", inCall: false, mic: true)
        rig.poll(50, 50)
        let call = try #require(rig.ended.first)
        #expect(call.lastAudioAt == 50, "at once, not a minute of silence later")
        #expect(call.mutes == [30...40])
        #expect(call.tab?.service == .meet)
    }

    /// A tab closed mid-call (its state said gone) ends it at once too; then the browser, still playing and with the
    /// mic, isn't the extension's to tell: the tab strip is read again.
    @Test func aClosedTabEndsItsCall() throws {
        let rig = PageRig()
        rig.mic = true
        rig.sound = true
        rig.tell(4, host: "discord.com", title: "Discord | #general", inCall: true, mic: true, muted: false)
        rig.poll(0, 30)
        #expect(rig.started.count == 1)
        rig.bridge.received(json(["type": "gone", "id": 4]), from: 1)
        let reads = rig.stripReads
        rig.poll(30.5, 30.5)
        #expect(rig.ended.first?.lastAudioAt == 30.5)
        rig.poll(31, 35)
        #expect(rig.stripReads > reads)
        #expect(rig.watch.detector.followed?.toldByPage != true)
    }

    /// Telegram on the web lets go of the mic to mute: the page says muted, and the released mic is neither a
    /// second mute nor leaving.
    @Test func aReleasedMicIsThePagesMute() throws {
        let rig = PageRig()
        rig.mic = true
        rig.sound = true
        rig.tell(2, host: "web.telegram.org", title: "Telegram Web", inCall: true, mic: true, muted: false)
        rig.poll(0, 30)
        rig.mic = false
        rig.tell(2, host: "web.telegram.org", title: "Telegram Web", inCall: true, mic: false, muted: true)
        rig.poll(30.5, 100)
        #expect(rig.ended.isEmpty, "still in the call, though the mic is off")
        rig.mic = true
        rig.tell(2, host: "web.telegram.org", title: "Telegram Web", inCall: true, mic: true, muted: false)
        rig.poll(100.5, 110)
        rig.tell(2, host: "web.telegram.org", title: "Telegram Web", inCall: false, mic: false)
        rig.poll(110.5, 110.5)
        let call = try #require(rig.ended.first)
        #expect(call.mutes == [30.5...100.5])
    }

    /// A profile without the extension: nothing from inside the page, so the tab strip and the Mute button tell, as
    /// before the extension.
    @Test func withoutTheExtensionTheTabStripTells() throws {
        for installed in [false, true] {
            let rig = PageRig(extensionInstalled: installed)
            rig.mic = true
            rig.sound = true
            rig.mute = .muted
            rig.stripTabs = ["Meet - abc-defg-hij - Camera and microphone recording"]
            // With the extension, but no tab of it in a call (its hooks missed this page's connections).
            if installed { rig.tell(3, host: "meet.google.com", title: "Meet", inCall: false, mic: true) }
            rig.poll(0, 30)
            let call = try #require(rig.watch.detector.call)
            #expect(call.toldByPage == false)
            #expect(call.tab?.service == .meet && call.tab?.recording == .cameraAndMic)
            #expect(call.mutedSince == 0, "muted from the Mute button, from the start")
            #expect(rig.stripReads > 5)
            #expect(rig.watch.lastRead?.fromPage == false)
        }
    }

    /// A page that can't tell its mute (it sends audio its hooks didn't see made) still has its Mute button read.
    @Test func aMuteThePageCantTellComesFromTheMuteButton() throws {
        let rig = PageRig()
        rig.mic = true
        rig.sound = true
        rig.mute = .muted
        rig.stripTabs = ["Zoom Meeting - Microphone recording"]
        rig.tell(6, host: "app.zoom.us", title: "Zoom Meeting", inCall: true, mic: true, muted: nil)
        rig.poll(0, 30)
        let call = try #require(rig.watch.detector.call)
        #expect(call.toldByPage)
        #expect(call.tab?.id == rig.id(6))
        #expect(call.mutedSince != nil)
        #expect(rig.watch.lastRead?.read.state == .muted && rig.watch.lastRead?.fromPage == false)
    }

    /// A call first found on the tab strip (the extension hadn't told yet) goes on when the page starts telling:
    /// their tab ids differ, so the service says it's the same call.
    @Test func fromTheTabStripToThePageIsTheSameCall() {
        var detector = CallDetector()
        let chrome = PageRig.chrome
        let both = [chrome: CallDetector.Activity(mic: true, sound: true)]
        let strip = CallDetector.Window(tab: CallDetector.Tab(service: .slack, page: Self.slack, recording: .mic,
                                                               id: BrowserTabs.TabID(3)))
        var page = CallDetector.Tab(service: .slack, page: Self.slack, recording: .mic,
                                    id: BrowserTabs.TabID(BrowserBridge.firstTabID))
        page.key = "slack"
        let told = CallDetector.Window(tab: page, muted: false, inCall: true, fromPage: true)
        var events: [CallDetector.Event] = []
        for tenth in stride(from: 0, through: 600, by: 5) {
            let time = Double(tenth) / 10
            let window = time == 5 ? strip : time >= 30 ? told : nil
            events += detector.feed(both, windows: window.map { [chrome: $0] } ?? [:], at: time)
        }
        #expect(events.filter { if case .ended = $0 { true } else { false } }.isEmpty)
        #expect(detector.call?.tab?.id == page.id && detector.call?.toldByPage == true)
    }

    /// All the way through the monitor: a huddle the tab strip can't place (it shows nothing), told by the page, is
    /// recorded as one Slack call with the page's mute, and ends when the page leaves.
    @Test func theMonitorRecordsWhatThePageTells() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings.inMemory()
        settings.callRecording = .automatic
        let store = CallStore(paths: paths, settings: settings)
        store.load()
        let transcriber = CallTranscriber(store: store) { _, _, _, _ in CloudResult(text: "[]") }
        let rig = PageRig()
        var record = CoreAudioHAL.ProcessRecord(objectID: 10, pid: 100, bundleID: chromeID, isRunningInput: true,
                                                isRunningOutput: true, inputDevices: [], outputDevices: [])
        let sensors = CallWatch.Sensors(
            processRecords: { [record] }, app: { CallApp(bundleID: $0.bundleID) }, pids: { _ in [] },
            canReadWindows: { true },
            readWindow: { _, _, _, done in
                done(CallMuteReader.Report(read: MuteRead(state: .unknown("test"), inCall: nil, detail: ""),
                                           isBrowser: true, windowCount: 1))
            },
            releaseWindows: {}, pages: { [bridge = rig.bridge] app in bridge.pages(of: app.id) })
        let monitor = CallMonitor(settings: settings, store: store, transcriber: transcriber, dependencies: .init(
            sensors: sensors, clock: { 0 }, now: { Date(timeIntervalSince1970: 1_790_000_000) },
            makeSources: { _ in [.mic: FakeSource(), .remote: FakeSource()] }, appName: { _ in "Google Chrome" }))
        func poll(_ from: Double, _ to: Double) {
            for tenth in stride(from: Int(from * 10), through: Int(to * 10), by: 5) { monitor.poll(at: Double(tenth) / 10) }
        }
        rig.tell(7, host: "app.slack.com", title: Self.slack, inCall: true, mic: true, muted: false)
        poll(0, 29.5)
        guard case .recording(let info) = monitor.state else { Issue.record("not kept"); return }
        #expect(info.service == .slack && info.pageTitle == Self.slack && info.muteKnown)
        rig.tell(7, host: "app.slack.com", title: "random (Channel) - V-Soft - Slack", inCall: true, mic: true, muted: true)
        poll(30, 39.5)
        rig.tell(7, host: "app.slack.com", title: "random (Channel) - V-Soft - Slack", inCall: true, mic: true, muted: false)
        poll(40, 59.5)
        rig.tell(7, host: "app.slack.com", title: "random (Channel) - V-Soft - Slack", inCall: false, mic: false)
        record.isRunningInput = false
        poll(60, 61)
        await monitor.waitForEndings()
        await transcriber.waitUntilIdle()
        #expect(store.calls.count == 1)
        let call = try #require(store.call(id: info.id))
        #expect(call.service == .slack && call.pageTitle == Self.slack, "named where it began")
        #expect(call.muteIntervals == [CallInterval(start: 30, end: 40)])
        #expect(call.muteKnown)
    }

    /// The mapping itself: the call's tab, the other tabs with the mic, sound elsewhere.
    @Test func pagesBecomeAWindow() throws {
        let one = BrowserTabs.TabID(BrowserBridge.firstTabID), two = BrowserTabs.TabID(BrowserBridge.firstTabID + 1)
        let pages = BrowserPages(pages: [
            .init(id: one, tab: BrowserProtocol.Tab(id: 1, host: "meet.google.com", room: "abc-defg-hij",
                                                    title: "Weekly sync", inCall: true, micLive: true, muted: true)),
            .init(id: two, tab: BrowserProtocol.Tab(id: 2, host: "example.com", title: "Recorder", inCall: false,
                                                    micLive: true)),
        ], audible: [two])
        let read = try #require(pages.read(following: nil, toldByPage: false))
        #expect(read.window.fromPage && read.window.muted == true && read.window.inCall == true)
        #expect(read.window.tab?.id == one && read.window.tab?.otherMicTabs == [two])
        #expect(read.window.tab?.key == "meet: abc-defg-hij", "Meet's meeting from its address, whatever the title")
        #expect(read.report.otherTabPlaysAudio && read.report.fromPage)
        #expect(read.report.tab?.page == "Weekly sync")
        // Nothing in a call: not the extension's to say.
        let quiet = BrowserPages(pages: [pages.pages[1]])
        #expect(quiet.read(following: nil, toldByPage: false) == nil)
    }
}

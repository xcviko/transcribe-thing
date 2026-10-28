import Darwin
import Foundation

/// The app's end of the browser extension: a Unix socket that each browser profile's native messaging host
/// (`NativeHost`) connects to, and what each profile has said. A connection is a profile once it has said hello; it
/// is dropped when its socket closes or it goes `silentAfter` without a word (the extension says everything every
/// 5 s). `BrowserExtension.connections` lists them; `pages(of:)` is what `CallWatch` reads about a browser's calls.
///
/// The diagnostic log gets profiles connecting and going, and each tab's call starting, muting and ending, with its
/// host name: never an address or a page's title.
@MainActor
final class BrowserBridge {
    /// One connected host, one browser profile.
    struct Profile: Equatable, Sendable {
        /// The browser that started the host, by bundle id; nil when the host couldn't tell.
        var browserID: String?
        /// The extension's id for its profile, from its hello; nil until then.
        var installID: String?
        var version = ""
        var lastSeen: Date
        /// Tabs with a call or the mic, by the browser's tab id.
        var tabs: [Int: BrowserProtocol.Tab] = [:]
        /// Tabs playing sound.
        var audible: Set<Int> = []
        /// Tabs whose call or mic ended (or that closed) since they were seen, latest last.
        var ended: [Int] = []
    }

    /// A profile not heard from for this long is gone: its browser hung, or slept.
    static let silentAfter: TimeInterval = 20
    /// Where the ids of the extension's tabs start (`tabID`): far above any the Accessibility tab strip gives out
    /// (`TabIDs`, from 1 up), so the two can never be the same tab.
    static let firstTabID = 1 << 40
    private static let endedKept = 64

    private(set) var profiles: [Int: Profile] = [:]
    /// The profiles changed: one connected, went, or said its version.
    var onConnectionsChanged: (([BrowserExtension.Connection]) -> Void)?
    var log: DiagnosticLog = .shared

    private let socketPath: String?
    private let now: () -> Date
    private var server: BrowserBridgeServer?
    private var timer: Timer?
    private var tabIDs: [String: Int] = [:]
    private var nextTabID = BrowserBridge.firstTabID

    /// Listens at `socketPath` once started; nil never listens (previews, tests feeding it themselves).
    init(socketPath: String?, now: @escaping () -> Date = { Date() }) {
        self.socketPath = socketPath
        self.now = now
    }

    /// The socket in the app's folder, unless its path is too long for a socket (a very long user name): then in
    /// this user's temporary folder. The host finds it the same way.
    nonisolated static func socketPath(for paths: AppPaths) -> String {
        let path = paths.browserSocket.path
        if UnixSocket.fits(path) { return path }
        return FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-thing-browser.sock").path
    }

    // MARK: Listening

    func start() {
        guard server == nil, let socketPath else { return }
        let server = BrowserBridgeServer(path: socketPath)
        // In order, on the main queue: a connection's messages never overtake its opening or its end. The browser
        // is found here from the host's own process, up its parents (`NativeHost.browserID(parentOf:)`): the host's
        // word on it is often missing (it logs why).
        server.onOpen = { [weak self] peer, pid in
            let browserID = pid.flatMap { NativeHost.browserID(parentOf: $0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.opened(peer, browserID: browserID) } }
        }
        server.onMessage = { [weak self] peer, data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, from: peer) } }
        }
        server.onClose = { [weak self] peer in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.closed(peer) } }
        }
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try server.start()
        } catch {
            log.event(.calls, "browser.listenFailed", ["error": String(describing: error)])
            return
        }
        self.server = server
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server?.stop()
        server = nil
        let had = !profiles.isEmpty
        profiles = [:]
        if had { onConnectionsChanged?(connections) }
    }

    // MARK: What the hosts say

    /// `browserID`: the browser of the process that connected, as the app found it; the host's own word wins.
    func opened(_ peer: Int, browserID: String? = nil) {
        profiles[peer] = Profile(browserID: browserID, lastSeen: now())
    }

    func closed(_ peer: Int) {
        drop(peer, reason: "closed")
    }

    func received(_ data: Data, from peer: Int) {
        guard var profile = profiles[peer] else { return }
        profile.lastSeen = now()
        let before = profile
        switch BrowserProtocol.decode(data) {
        case .host(let browserID, let why):
            if let browserID {
                profile.browserID = browserID
            } else {
                log.event(.calls, "browser.hostUnsure", ["why": why ?? "unknown",
                                                         "found": profile.browserID ?? "unknown"])
            }
        case .hello(let installID, let version):
            profile.installID = installID
            profile.version = version
            // The same profile again (its host restarted): the old connection is that one's past.
            for (other, old) in profiles where other != peer && old.installID == installID {
                profiles[other] = nil
                server?.close(other)
            }
            log.event(.calls, "browser.connected", ["browser": profile.browserID ?? "unknown", "version": version,
                                                   "profile": String(installID.prefix(8))])
            server?.send(BrowserProtocol.encode("welcome", ["app": Self.appVersion]), to: peer)
        case .tab(let tab):
            apply(tab, to: &profile)
        case .gone(let id):
            apply(BrowserProtocol.Tab(id: id, host: profile.tabs[id]?.host ?? "", title: "", inCall: false,
                                      micLive: false), to: &profile)
        case .audible(let ids):
            profile.audible = Set(ids)
        case .state(let tabs, let audible):
            let listed = Set(tabs.map(\.id))
            for (id, old) in profile.tabs where !listed.contains(id) {
                var over = old
                over.inCall = false
                over.micLive = false
                apply(over, to: &profile)
            }
            for tab in tabs { apply(tab, to: &profile) }
            if let audible { profile.audible = Set(audible) }
        case .other, nil:
            break
        }
        profiles[peer] = profile
        if before.installID != profile.installID || before.version != profile.version
            || before.browserID != profile.browserID {
            onConnectionsChanged?(connections)
        }
    }

    /// Drops the profiles that have gone `silentAfter` without a word.
    func prune() {
        let now = now()
        for (peer, profile) in profiles where now.timeIntervalSince(profile.lastSeen) >= Self.silentAfter {
            drop(peer, reason: "silent")
            server?.close(peer)
        }
    }

    private func drop(_ peer: Int, reason: String) {
        guard let profile = profiles.removeValue(forKey: peer) else { return }
        guard let installID = profile.installID else { return }
        log.event(.calls, "browser.disconnected", ["browser": profile.browserID ?? "unknown",
                                                  "profile": String(installID.prefix(8)), "reason": reason])
        onConnectionsChanged?(connections)
    }

    private func apply(_ tab: BrowserProtocol.Tab, to profile: inout Profile) {
        let old = profile.tabs[tab.id]
        if tab.isIdle {
            guard old != nil else { return }
            profile.tabs[tab.id] = nil
            profile.ended.removeAll { $0 == tab.id }
            profile.ended.append(tab.id)
            if profile.ended.count > Self.endedKept { profile.ended.removeFirst(profile.ended.count - Self.endedKept) }
        } else {
            profile.tabs[tab.id] = tab
            profile.ended.removeAll { $0 == tab.id }
        }
        guard old?.inCall != tab.inCall || old?.micLive != tab.micLive || old?.muted != tab.muted else { return }
        log.event(.calls, "browser.tab", [
            "browser": profile.browserID ?? "unknown", "tab": tab.id, "host": tab.host.isEmpty ? nil : tab.host,
            "inCall": tab.inCall, "mic": tab.micLive, "muted": tab.muted.map { $0 ? "true" : "false" } ?? "unknown",
        ])
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: What the app reads

    /// Every profile that has said hello, one per profile.
    var connections: [BrowserExtension.Connection] {
        var latest: [String: Profile] = [:]
        for profile in profiles.values {
            guard let installID = profile.installID else { continue }
            if let other = latest[installID], other.lastSeen > profile.lastSeen { continue }
            latest[installID] = profile
        }
        return latest.values.map {
            BrowserExtension.Connection(id: $0.installID ?? "", browserID: $0.browserID ?? "", version: $0.version,
                                        lastSeen: $0.lastSeen)
        }.sorted { ($0.browserID, $0.id) < ($1.browserID, $1.id) }
    }

    /// What the extension says about `browserID`'s tabs, from every profile of it that has the extension; nil when
    /// none has: then nothing is known from inside its pages.
    func pages(of browserID: String) -> BrowserPages? {
        let reporting = profiles.values.filter { $0.browserID == browserID && $0.installID != nil }
        guard !reporting.isEmpty else { return nil }
        var pages: [BrowserPages.Page] = []
        var ended: Set<BrowserTabs.TabID> = []
        var audible: Set<BrowserTabs.TabID> = []
        for profile in reporting {
            let installID = profile.installID ?? ""
            for tab in profile.tabs.values { pages.append(BrowserPages.Page(id: tabID(installID, tab.id), tab: tab)) }
            for id in profile.ended { ended.insert(tabID(installID, id)) }
            for id in profile.audible { audible.insert(tabID(installID, id)) }
        }
        return BrowserPages(pages: pages.sorted { $0.id.raw < $1.id.raw }, ended: ended, audible: audible)
    }

    /// The `BrowserTabs.TabID` of a profile's tab: the same for as long as the app runs, another profile's tab with
    /// the same number another.
    func tabID(_ installID: String, _ tab: Int) -> BrowserTabs.TabID {
        let key = "\(installID)#\(tab)"
        if let raw = tabIDs[key] { return BrowserTabs.TabID(raw) }
        let raw = nextTabID
        nextTabID += 1
        tabIDs[key] = raw
        return BrowserTabs.TabID(raw)
    }
}

/// The socket itself, on a queue of its own: connections accepted, read as they come, each message handed on with
/// the connection's number (never used twice).
final class BrowserBridgeServer: @unchecked Sendable {
    // @unchecked: everything mutable is touched on `queue` only; the callbacks are set before `start`.

    /// A connection, and the process at its other end when the system says (`LOCAL_PEERPID`).
    var onOpen: @Sendable (Int, pid_t?) -> Void = { _, _ in }
    var onMessage: @Sendable (Int, Data) -> Void = { _, _ in }
    var onClose: @Sendable (Int) -> Void = { _ in }

    private struct Peer {
        var fd: Int32
        var source: any DispatchSourceRead
        var reader = NativeFrame.Reader()
    }

    private let path: String
    private let queue = DispatchQueue(label: "dev.transcribe-thing.browser-bridge", qos: .utility)
    private var listener: (any DispatchSourceRead)?
    private var peers: [Int: Peer] = [:]
    private var next = 1

    init(path: String) {
        self.path = path
    }

    /// The socket file this run made, so `stop` removes only its own and never another copy's.
    private var made: (dev_t, ino_t)?

    func start() throws {
        let fd = try UnixSocket.listen(at: path)
        made = UnixSocket.identity(of: path)
        UnixSocket.setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for id in Array(peers.keys) { closePeer(id, notify: false) }
            if let made, let now = UnixSocket.identity(of: path), made == now { unlink(path) }
        }
    }

    func send(_ message: Data, to peer: Int) {
        queue.async { [self] in
            guard let fd = peers[peer]?.fd else { return }
            if !UnixSocket.writeAll(fd, NativeFrame.encode(message)) { closePeer(peer, notify: true) }
        }
    }

    func close(_ peer: Int) {
        queue.async { [self] in closePeer(peer, notify: false) }
    }

    private func accept(_ listening: Int32) {
        while true {
            let fd = Darwin.accept(listening, nil, nil)
            guard fd >= 0 else { return }
            UnixSocket.noSigPipe(fd)
            UnixSocket.setNonBlocking(fd)
            let id = next
            next += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(id) }
            source.setCancelHandler { Darwin.close(fd) }
            peers[id] = Peer(fd: fd, source: source)
            onOpen(id, Self.peerPID(fd))
            source.resume()
        }
    }

    /// The process at the other end of a Unix socket connection.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    private func read(_ id: Int) {
        guard var peer = peers[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(peer.fd, &buffer, buffer.count)
            if count > 0 {
                do {
                    for message in try peer.reader.push(Data(buffer[0..<count])) { onMessage(id, message) }
                } catch {
                    peers[id] = peer
                    return closePeer(id, notify: true)
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN {
                peers[id] = peer
                return
            }
            // The end of the stream, or an error.
            peers[id] = peer
            return closePeer(id, notify: true)
        }
    }

    private func closePeer(_ id: Int, notify: Bool) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.source.cancel()
        if notify { onClose(id) }
    }
}

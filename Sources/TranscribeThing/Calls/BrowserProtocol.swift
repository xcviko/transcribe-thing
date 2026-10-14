import Foundation

/// What the browser extension (BrowserExtension/chromium) and the app say to each other. The browser starts the
/// native messaging host (`NativeHost`, this app's own executable) and talks to it in native messages; the host
/// passes each one on to the running app (`BrowserBridge`) over a Unix socket, and the app's answers back. Every
/// message is one JSON object in one frame (`NativeFrame`), with `v`, the protocol's version, and `type`. Types and
/// fields a side doesn't know are skipped, so a later version can add messages (per-tab audio) without breaking an
/// older app or extension. background.js lists them.
enum BrowserProtocol {
    static let version = 1
    /// The native messaging host's name, which the extension connects to and its manifest is named after.
    static let hostName = "dev.transcribe_thing.bridge"
    /// The extension's id, the same wherever its folder is: it's made from the public key pinned in its
    /// manifest.json ("key"), the first 32 hex digits of the key's SHA-256 written with a-p for 0-f.
    /// jmbjndmjbpmemomladndhokpgbhbbnhn
    static let extensionID = "jmbjndmjbpmemomladndhokpgbhbbnhn"
    /// The origin Chromium passes the host as its argument, and the only one the host's manifest lets in.
    static let origin = "chrome-extension://\(extensionID)/"

    /// One tab with a call or the mic, as the extension sees it from inside its pages.
    struct Tab: Equatable, Sendable, Decodable {
        /// The browser's id for the tab: the same for as long as the tab is open, whatever it shows.
        var id: Int
        var windowID: Int?
        /// The page's host name, "meet.google.com".
        var host: String
        /// The call's code when its address names it: Meet's "abc-defg-hij".
        var room: String?
        /// The page's own title.
        var title: String
        /// The browser says the tab plays sound.
        var audible: Bool
        /// A peer connection in the tab is connected (or was, and hasn't failed or closed).
        var inCall: Bool
        /// The tab holds a live mic track.
        var micLive: Bool
        /// true muted, false heard, nil unknown; only while in a call.
        var muted: Bool?

        init(id: Int, windowID: Int? = nil, host: String, room: String? = nil, title: String, audible: Bool = false,
             inCall: Bool, micLive: Bool, muted: Bool? = nil) {
            self.id = id
            self.windowID = windowID
            self.host = host
            self.room = room
            self.title = title
            self.audible = audible
            self.inCall = inCall
            self.micLive = micLive
            self.muted = muted
        }

        private enum Keys: String, CodingKey {
            case id, windowId, host, room, title, audible, inCall, micLive, muted
        }

        /// Forgiving: only the id is required.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(Int.self, forKey: .id)
            windowID = try? c.decodeIfPresent(Int.self, forKey: .windowId)
            host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
            room = try? c.decodeIfPresent(String.self, forKey: .room)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            audible = (try? c.decodeIfPresent(Bool.self, forKey: .audible)) ?? false
            inCall = (try? c.decodeIfPresent(Bool.self, forKey: .inCall)) ?? false
            micLive = (try? c.decodeIfPresent(Bool.self, forKey: .micLive)) ?? false
            muted = try? c.decodeIfPresent(Bool.self, forKey: .muted)
        }

        /// Has nothing worth telling: no call, no mic.
        var isIdle: Bool { !inCall && !micLive }
    }

    enum Message: Equatable, Sendable {
        /// The extension, first on every connection: its profile's id (made once per profile) and its version.
        case hello(installID: String, version: String)
        /// The host, before anything it passes on: the browser that started it, by bundle id.
        case host(browserID: String?)
        case tab(Tab)
        case gone(tabID: Int)
        /// The tabs playing sound.
        case audible([Int])
        /// Every tab with a call or the mic, and those playing sound when it says: the heartbeat.
        case state(tabs: [Tab], audible: [Int]?)
        /// A type this version doesn't know.
        case other(String)
    }

    private struct Kind: Decodable { var type: String }
    private struct Hello: Decodable { var installID: String; var version: String? }
    private struct Host: Decodable { var browserID: String? }
    private struct OneTab: Decodable { var tab: Tab }
    private struct Gone: Decodable { var id: Int }
    private struct Audible: Decodable { var tabs: [Int] }
    private struct State: Decodable { var tabs: [Tab]?; var audible: [Int]? }

    /// The message in one frame's JSON, nil when it isn't one (or lacks what its type needs).
    static func decode(_ data: Data) -> Message? {
        let decoder = JSONDecoder()
        guard let kind = try? decoder.decode(Kind.self, from: data) else { return nil }
        switch kind.type {
        case "hello":
            guard let hello = try? decoder.decode(Hello.self, from: data), !hello.installID.isEmpty else { return nil }
            return .hello(installID: hello.installID, version: hello.version ?? "")
        case "host":
            return (try? decoder.decode(Host.self, from: data)).map { .host(browserID: $0.browserID) }
        case "tab":
            return (try? decoder.decode(OneTab.self, from: data)).map { .tab($0.tab) }
        case "gone":
            return (try? decoder.decode(Gone.self, from: data)).map { .gone(tabID: $0.id) }
        case "audible":
            return (try? decoder.decode(Audible.self, from: data)).map { .audible($0.tabs) }
        case "state":
            return (try? decoder.decode(State.self, from: data)).map { .state(tabs: $0.tabs ?? [], audible: $0.audible) }
        default:
            return .other(kind.type)
        }
    }

    /// A message as JSON, with the version.
    static func encode(_ type: String, _ fields: [String: Any] = [:]) -> Data {
        var object = fields
        object["v"] = version
        object["type"] = type
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// Native messaging's framing, which the host also uses on the socket: each message is its length as a 32-bit
/// unsigned integer in the machine's byte order, then that many bytes of UTF-8 JSON.
enum NativeFrame {
    /// Chromium sends at most 64 MiB to a host, and gets at most 1 MiB back; nothing here comes close. A longer
    /// length says the stream is broken.
    static let maxLength = 8 << 20

    struct TooLong: Error {}

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    /// Takes bytes as they come and gives back whole messages.
    struct Reader {
        private var buffer = Data()

        init() {}

        mutating func push(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var messages: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
                guard length <= NativeFrame.maxLength else { throw TooLong() }
                guard buffer.count >= 4 + length else { break }
                messages.append(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return messages
        }
    }
}

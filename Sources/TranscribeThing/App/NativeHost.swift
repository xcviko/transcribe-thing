import Darwin
import Foundation

/// The native messaging host: what this app's executable is when a Chromium browser starts it for the browser
/// extension (its argument is the caller's origin, "chrome-extension://<id>/"; `BrowserExtension` writes the
/// manifest that points the browser here). It runs before anything of the app, and does nothing but relay: native
/// messages from the extension on stdin go to the running app over its Unix socket (`BrowserBridge`), the app's to
/// stdout. No settings, no windows, no hotkeys; nothing is written anywhere.
///
/// The browser keeps it running while the extension is connected, which is as long as the browser runs. When the app
/// isn't running (or quits) it tries again every couple of seconds; meanwhile the extension's messages are dropped
/// (they'd be stale by then), except its hello, which goes first on every new connection, followed by a word to the
/// extension to send everything again. It exits when stdin closes: the browser quit or the extension let go.
enum NativeHostCLI {
    /// Whether this process was started as the host: an argument is an extension's origin.
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix("chrome-extension://") }
    }

    static func run(_ arguments: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let host = NativeHost(input: STDIN_FILENO, output: STDOUT_FILENO,
                              socketPath: BrowserBridge.socketPath(for: AppPaths.live()),
                              browserID: NativeHost.browserID(parentOf: getpid()))
        host.run()
        exit(0)
    }
}

/// The relay itself, with its descriptors and the socket's path given, so tests drive it with pipes.
final class NativeHost: @unchecked Sendable {
    // @unchecked: `app` and `hello` are behind `lock`; the descriptors are written under their own locks.

    private let input: Int32
    private let output: Int32
    private let socketPath: String
    private let browserID: String?
    private let retry: TimeInterval
    private let lock = NSLock()
    private let outputLock = NSLock()
    private let appLock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    /// The connection to the app, -1 while there's none.
    private var app: Int32 = -1
    /// The extension's last hello, sent first on every connection.
    private var hello: Data?
    private var done = false

    init(input: Int32, output: Int32, socketPath: String, browserID: String?, retry: TimeInterval = 2) {
        self.input = input
        self.output = output
        self.socketPath = socketPath
        self.browserID = browserID
        self.retry = retry
    }

    /// Relays until stdin closes, then returns.
    func run() {
        let connector = Thread { [self] in connectLoop() }
        connector.name = "transcribe-thing.host.app"
        connector.start()
        while let message = UnixSocket.readFrame(input) {
            if case .hello = BrowserProtocol.decode(message) {
                lock.withLock { hello = message }
            }
            // Under `appLock`, so the connection can't be closed (and its number used again) mid-write.
            appLock.withLock {
                let fd = lock.withLock { app }
                guard fd >= 0 else { return }
                if !UnixSocket.writeAll(fd, NativeFrame.encode(message)) { shutdown(fd, SHUT_RDWR) }
            }
        }
        lock.withLock {
            done = true
            if app >= 0 { shutdown(app, SHUT_RDWR) }
        }
        wake.signal()
        while !connectorFinished { usleep(1000) }
    }

    private var finished = false
    private var connectorFinished: Bool { lock.withLock { finished } }

    private func connectLoop() {
        defer { lock.withLock { finished = true } }
        while !lock.withLock({ done }) {
            guard let fd = UnixSocket.connect(to: socketPath) else {
                _ = wake.wait(timeout: .now() + retry)
                continue
            }
            // Who's calling and the hello go before anything stdin brings: it waits for `appLock`.
            let opened: Bool = appLock.withLock {
                let greeting: Data?? = lock.withLock {
                    guard !done else { return .none }
                    app = fd
                    return .some(hello)
                }
                guard case .some(let hello) = greeting else { return false }
                let host = BrowserProtocol.encode("host", browserID.map { ["browserID": $0] } ?? [:])
                UnixSocket.writeAll(fd, NativeFrame.encode(host))
                if let hello { UnixSocket.writeAll(fd, NativeFrame.encode(hello)) }
                return true
            }
            guard opened else {
                close(fd)
                break
            }
            toExtension(BrowserProtocol.encode("app", ["connected": true]))
            while let message = UnixSocket.readFrame(fd) {
                toExtension(message)
            }
            appLock.withLock {
                lock.withLock { app = -1 }
                close(fd)
            }
            if lock.withLock({ done }) { break }
            toExtension(BrowserProtocol.encode("app", ["connected": false]))
            _ = wake.wait(timeout: .now() + retry)
        }
    }

    private func toExtension(_ message: Data) {
        outputLock.withLock { _ = UnixSocket.writeAll(output, NativeFrame.encode(message)) }
    }

    /// The browser that started `pid`: the first app up its parents, by its main bundle id ("com.google.Chrome" for a
    /// helper of Chrome's too). Read from the parent's executable path and its bundle's Info.plist, never through
    /// AppKit or LaunchServices: a host that checked in with LaunchServices would count as a running transcribe-thing.
    static func browserID(parentOf pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<4 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let parent = pid_t(info.pbi_ppid)
            guard parent > 1 else { return nil }
            if let path = executablePath(parent), let id = bundleID(ofExecutable: path) {
                return CallApp.mainBundleID(of: id)
            }
            current = parent
        }
        return nil
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The bundle id of the outermost .app an executable is in: "/Applications/Google Chrome.app/Contents/MacOS/Google
    /// Chrome" is Chrome's. The outermost, so a helper app inside another (Chrome's "Google Chrome Helper.app") is its
    /// browser's.
    static func bundleID(ofExecutable path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        let app = NSString.path(withComponents: Array(parts[...index]))
        return Bundle(path: app)?.bundleIdentifier
    }
}

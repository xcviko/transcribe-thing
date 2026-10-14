import Darwin
import Foundation

/// The few POSIX calls the browser bridge needs: a listening Unix domain socket for the app, a connection to it for
/// the native messaging host, and whole reads and writes. Every socket is SO_NOSIGPIPE, so a peer that went away is
/// an error to the writer, never a signal that kills it.
enum UnixSocket {
    struct Failure: Error, CustomStringConvertible {
        var call: String
        var code: Int32

        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    /// sun_path's size, its closing NUL included: a longer path can't be a socket's.
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    static func fits(_ path: String) -> Bool { path.utf8.count < maxPathBytes }

    /// Listens at `path`, readable and writable by this user only (0600). A file left there by an earlier run is
    /// replaced.
    static func listen(at path: String) throws -> Int32 {
        guard fits(path) else { throw Failure(call: "path", code: ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", code: errno) }
        noSigPipe(fd)
        unlink(path)
        var address = self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure(call: "bind", code: code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw Failure(call: "listen", code: code)
        }
        return fd
    }

    /// A connection to the socket at `path`, or nil when nobody listens there.
    static func connect(to path: String) -> Int32? {
        guard fits(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        var address = self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Writes all of `data` (a blocking descriptor); false when the other end is gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let written = Darwin.write(fd, pointer, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        usleep(1000)
                        continue
                    }
                    return false
                }
                left -= written
                pointer += written
            }
            return true
        }
    }

    /// Exactly `count` bytes, or nil at the end of the stream or on an error.
    static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let read = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { return nil }
            got += read
        }
        return data
    }

    /// One frame's message (`NativeFrame`), or nil at the end of the stream, on an error, or for a broken length.
    static func readFrame(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
        guard length <= NativeFrame.maxLength else { return nil }
        if length == 0 { return Data() }
        return readExactly(fd, length)
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}

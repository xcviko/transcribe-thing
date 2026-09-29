import Foundation

enum KeyFileError: Error, Equatable, Sendable {
    /// Removing the key deletes the file; an empty one is never written.
    case emptyKey
    /// The file isn't UTF-8 text.
    case notText
    /// A system call failed with this errno.
    case posix(Int32)
}

/// The OpenRouter key, in one file only the user can read (`AppPaths.keyFile`: the file 0600, its folder 0700).
/// Not the login keychain: signed with a certificate that has no Team ID, each build is a new app to the Keychain, so
/// every rebuild asked for the keychain password to read the key. `inMemory()` never touches the disk (previews, tests).
struct KeyFileStore: Sendable {
    private enum Backing: Sendable {
        case file(URL)
        case memory(MemoryBox)
    }

    private let backing: Backing

    init(url: URL) {
        backing = .file(url)
    }

    private init(memory: MemoryBox) {
        backing = .memory(memory)
    }

    static func inMemory(_ key: String? = nil) -> KeyFileStore {
        KeyFileStore(memory: MemoryBox(key))
    }

    var isInMemory: Bool {
        if case .memory = backing { true } else { false }
    }

    /// A key file is there, whether or not it can be read (in memory: a key is stored).
    var hasFile: Bool {
        switch backing {
        case .file(let url): FileManager.default.fileExists(atPath: url.path)
        case .memory(let box): box.key != nil
        }
    }

    /// The key without the whitespace around it (the newline an editor adds). nil only when there is no file or
    /// nothing but whitespace in it; a file that can't be read throws.
    func lookup() throws -> String? {
        let text: String?
        switch backing {
        case .memory(let box):
            if box.readFails { throw KeyFileError.posix(EACCES) }
            text = box.key
        case .file(let url):
            do {
                guard let string = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                    throw KeyFileError.notText
                }
                text = string
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            } catch {
                Log.app.error("Couldn't read the key file: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        let key = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    /// In-memory stores only (tests): make reads fail until set back to false.
    func simulateReadFailure(_ fails: Bool) {
        if case .memory(let box) = backing { box.readFails = fails }
    }

    /// Replaces the key in one step: the bytes go into a new 0600 file beside it, which is then renamed over the
    /// key file, so a reader finds the old key or the new one, never part of one, and nobody else can read either.
    /// The folder is made 0700 first (older builds created it 0755).
    func write(_ key: String) throws {
        guard !key.isEmpty else { throw KeyFileError.emptyKey }
        let url: URL
        switch backing {
        case .memory(let box):
            box.key = key
            return
        case .file(let file):
            url = file
        }
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mode = try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int ?? 0
        if mode & 0o077 != 0 {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }

        let partial = folder.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).partial")
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw KeyFileError.posix(errno) }
        var placed = false
        defer { if !placed { unlink(partial.path) } }
        do {
            // Created 0600 minus the umask, which only takes bits away: exactly 0600 all the same.
            guard fchmod(fd, 0o600) == 0 else { throw KeyFileError.posix(errno) }
            try Self.writeAll(Array(key.utf8), to: fd)
            guard fsync(fd) == 0 else { throw KeyFileError.posix(errno) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw KeyFileError.posix(errno) }
        guard rename(partial.path, url.path) == 0 else { throw KeyFileError.posix(errno) }
        placed = true
    }

    /// Removing the key deletes the file.
    func delete() {
        switch backing {
        case .memory(let box):
            box.key = nil
        case .file(let url):
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Already gone.
            } catch {
                Log.app.error("Couldn't delete the key file: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                throw KeyFileError.posix(errno)
            }
            offset += written
        }
    }

    private final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        private var failure = false

        init(_ value: String?) { self.value = value }

        var key: String? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        var readFails: Bool {
            get { lock.withLock { failure } }
            set { lock.withLock { failure = newValue } }
        }
    }
}

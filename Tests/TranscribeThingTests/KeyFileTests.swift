import Foundation
import Testing
@testable import TranscribeThing

/// Permission bits of the file or folder at `url`.
private func mode(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

private func removeFolder(_ paths: AppPaths) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path)
    try? FileManager.default.removeItem(at: paths.root)
}

@Suite struct KeyFileStoreTests {
    @Test func writesReadsTrimsAndRemoves() throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        #expect(try store.lookup() == nil, "no folder yet")
        #expect(!store.hasFile)

        try store.write("sk-or-v1-abcdef")
        #expect(try store.lookup() == "sk-or-v1-abcdef")
        #expect(try Data(contentsOf: paths.keyFile) == Data("sk-or-v1-abcdef".utf8), "exactly the key")

        // Edited by hand: the newline an editor adds, stray spaces.
        try Data("  sk-or-v1-abcdef \n\n".utf8).write(to: paths.keyFile)
        #expect(try store.lookup() == "sk-or-v1-abcdef")
        try Data(" \n".utf8).write(to: paths.keyFile)
        #expect(try store.lookup() == nil, "only whitespace is no key")
        #expect(store.hasFile)

        try store.write("sk-or-v1-abcdef")
        store.delete()
        #expect(!FileManager.default.fileExists(atPath: paths.keyFile.path))
        #expect(try store.lookup() == nil)
        store.delete()
    }

    @Test func onlyTheUserCanReadIt() throws {
        let fresh = AppPaths.temporary()
        defer { removeFolder(fresh) }
        try KeyFileStore(url: fresh.keyFile).write("sk-or-v1-abcdef")
        #expect(try mode(fresh.keyFile) == 0o600)
        #expect(try mode(fresh.root) == 0o700)

        // The folder as older builds created it.
        let older = AppPaths.temporary()
        defer { removeFolder(older) }
        try FileManager.default.createDirectory(at: older.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try KeyFileStore(url: older.keyFile).write("sk-or-v1-abcdef")
        #expect(try mode(older.root) == 0o700)
        #expect(try mode(older.keyFile) == 0o600)
    }

    @Test func replacingIsOneStep() throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        let inode = { try FileManager.default.attributesOfItem(atPath: paths.keyFile.path)[.systemFileNumber] as? Int }
        try store.write("sk-or-v1-old")
        let oldInode = try inode()
        let reader = try FileHandle(forReadingFrom: paths.keyFile)
        defer { try? reader.close() }

        try store.write("sk-or-v1-new")
        #expect(try store.lookup() == "sk-or-v1-new")
        #expect(try mode(paths.keyFile) == 0o600)
        // A new file took the name: one opened before still reads the whole old key, never a mix.
        #expect(try inode() != oldInode)
        #expect(try reader.readToEnd() == Data("sk-or-v1-old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.root.path) == ["openrouter-key"],
                "no partial file left")
    }

    @Test func aFailedWriteKeepsTheOldKey() throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        try store.write("sk-or-v1-old")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.root.path)
        #expect(throws: KeyFileError.posix(EACCES)) { try store.write("sk-or-v1-new") }
        #expect(try store.lookup() == "sk-or-v1-old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.root.path) == ["openrouter-key"])
    }

    @Test func anEmptyKeyIsNeverWritten() {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        #expect(throws: KeyFileError.emptyKey) { try store.write("") }
        #expect(!store.hasFile)
        #expect(throws: KeyFileError.emptyKey) { try KeyFileStore.inMemory().write("") }
    }

    @Test func aFileThatCantBeReadIsNotAMissingKey() throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        try store.write("sk-or-v1-abcdef")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.keyFile.path)
        #expect(throws: (any Error).self) { try store.lookup() }
        #expect(store.hasFile)

        try FileManager.default.removeItem(at: paths.keyFile)
        try Data([0xFF, 0xFE, 0x00]).write(to: paths.keyFile)
        #expect(throws: KeyFileError.notText) { try store.lookup() }
    }
}

/// The login keychain as `KeychainMigration` sees it, counting what it's asked.
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var refuses: Bool
    private var readCount = 0
    private var deleteCount = 0

    init(key: String?, refuses: Bool = false) {
        self.key = key
        self.refuses = refuses
    }

    var storedKey: String? { lock.withLock { key } }
    var reads: Int { lock.withLock { readCount } }
    var deletes: Int { lock.withLock { deleteCount } }
    func allow() { lock.withLock { refuses = false } }

    var legacy: LegacyKeychainKey {
        LegacyKeychainKey(
            read: {
                try self.lock.withLock {
                    self.readCount += 1
                    if self.refuses { throw KeychainError.unexpectedStatus(-128) } // errSecUserCanceled
                    return self.key
                }
            },
            delete: {
                self.lock.withLock {
                    self.deleteCount += 1
                    self.key = nil
                }
            })
    }
}

@MainActor
@Suite struct KeychainMigrationTests {
    @Test func movesTheKeyThenDeletesTheItem() throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        let keychain = FakeKeychain(key: "sk-or-v1-abcdef")
        #expect(KeychainMigration.run(into: store, from: keychain.legacy) == .moved)
        #expect(try store.lookup() == "sk-or-v1-abcdef")
        #expect(try mode(paths.keyFile) == 0o600)
        #expect(keychain.reads == 1 && keychain.deletes == 1)
        #expect(keychain.storedKey == nil)

        // The next launch finds the file and leaves the Keychain alone.
        #expect(KeychainMigration.run(into: store, from: keychain.legacy) == .keyFileExists)
        #expect(keychain.reads == 1)
    }

    @Test func aRefusedReadMeansNoKeyUntilTheNextLaunch() async throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        let keychain = FakeKeychain(key: "sk-or-v1-abcdef", refuses: true)
        #expect(KeychainMigration.run(into: store, from: keychain.legacy) == .keychainRefused)
        #expect(!store.hasFile)
        #expect(keychain.deletes == 0 && keychain.storedKey == "sk-or-v1-abcdef")

        // The rest of the launch goes by the key file alone: "no key", and the Keychain isn't asked again.
        let account = OpenRouterAccount(keyStore: store, client: StubURLProtocol.client([]).0, debounce: .zero)
        await account.validate()
        #expect(account.status == .missing)
        #expect(account.apiKey() == nil)
        #expect(!account.isKeyUnreadable)
        #expect(keychain.reads == 1)

        // The next launch asks again, while there's still no key file.
        keychain.allow()
        #expect(KeychainMigration.run(into: store, from: keychain.legacy) == .moved)
        #expect(try store.lookup() == "sk-or-v1-abcdef")
    }

    @Test func aKeyFileLeavesTheKeychainUntouched() throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        try store.write("sk-or-v1-pasted")
        let keychain = FakeKeychain(key: "sk-or-v1-old")
        #expect(KeychainMigration.run(into: store, from: keychain.legacy) == .keyFileExists)
        #expect(keychain.reads == 0 && keychain.deletes == 0)
        #expect(try store.lookup() == "sk-or-v1-pasted")

        // Even one with no key in it.
        try Data("\n".utf8).write(to: paths.keyFile)
        #expect(KeychainMigration.run(into: store, from: keychain.legacy) == .keyFileExists)
        #expect(keychain.reads == 0)
    }

    @Test func noKeyInTheKeychainWritesNothing() {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        let store = KeyFileStore(url: paths.keyFile)
        for stored in [nil, "", " \n"] as [String?] {
            let keychain = FakeKeychain(key: stored)
            #expect(KeychainMigration.run(into: store, from: keychain.legacy) == .nothingToMove)
            #expect(!store.hasFile)
            #expect(keychain.deletes == 0)
        }
    }

    @Test func aFailedWriteKeepsTheItem() throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o500])
        let store = KeyFileStore(url: paths.keyFile)
        let keychain = FakeKeychain(key: "sk-or-v1-abcdef")
        #expect(KeychainMigration.run(into: store, from: keychain.legacy) == .notWritten)
        #expect(!store.hasFile)
        #expect(keychain.deletes == 0 && keychain.storedKey == "sk-or-v1-abcdef")
    }
}

@Suite struct CLIKeyTests {
    @Test func theEnvironmentWinsOverTheKeyFile() throws {
        let paths = AppPaths.temporary()
        defer { removeFolder(paths) }
        try KeyFileStore(url: paths.keyFile).write("sk-or-v1-file")

        let fromEnvironment = EngineCLI.keyStore(environment: ["OPENROUTER_API_KEY": " sk-or-v1-env\n"], paths: paths)
        #expect(fromEnvironment.isInMemory)
        #expect(try fromEnvironment.lookup() == "sk-or-v1-env")

        for environment in [[:], ["OPENROUTER_API_KEY": ""], ["OPENROUTER_API_KEY": " \n"]] as [[String: String]] {
            let fromFile = EngineCLI.keyStore(environment: environment, paths: paths)
            #expect(!fromFile.isInMemory)
            #expect(try fromFile.lookup() == "sk-or-v1-file")
        }
    }
}

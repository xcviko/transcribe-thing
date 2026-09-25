import Foundation
import Security

enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case encoding
}

/// Generic-password items in the login keychain, one per account name.
/// `inMemory()` never touches the keychain (previews, tests).
struct KeychainStore: Sendable {
    let service: String
    private let memory: MemoryBox?

    init(service: String = "dev.murmur.app") {
        self.service = service
        self.memory = nil
    }

    private init(service: String, memory: MemoryBox) {
        self.service = service
        self.memory = memory
    }

    static func inMemory(_ initial: [String: String] = [:]) -> KeychainStore {
        KeychainStore(service: "dev.murmur.preview", memory: MemoryBox(initial))
    }

    var isInMemory: Bool { memory != nil }

    func read(_ account: String) -> String? {
        if let memory { return memory.get(account) }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.app.error("Keychain read failed: \(status, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) throws {
        if let memory { memory.set(value, for: account); return }
        guard let data = value.data(using: .utf8) else { throw KeychainError.encoding }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Murmur (\(account))"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func delete(_ account: String) {
        if let memory { memory.set(nil, for: account); return }
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.app.error("Keychain delete failed: \(status, privacy: .public)")
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String]

        init(_ values: [String: String]) { self.values = values }

        func get(_ key: String) -> String? { lock.withLock { values[key] } }
        func set(_ value: String?, for key: String) { lock.withLock { values[key] = value } }
    }
}

extension KeychainStore {
    /// Account name of the OpenRouter API key.
    static let openRouterAccount = "openrouter-api-key"
}

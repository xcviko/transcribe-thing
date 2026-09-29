import Foundation
import Security

enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
}

/// Where builds before the key file kept the OpenRouter key: a generic-password item in the login keychain. Only
/// `KeychainMigration` touches it.
struct LegacyKeychainKey: Sendable {
    /// nil only when there is no item. Anything else the Keychain says (a denied or cancelled access prompt, a
    /// locked keychain) throws.
    var read: @Sendable () throws -> String?
    var delete: @Sendable () -> Void

    static let live = LegacyKeychainKey(
        read: {
            var query = itemQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainError.unexpectedStatus(status)
            }
            return String(data: data, encoding: .utf8)
        },
        delete: {
            let status = SecItemDelete(itemQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                Log.app.error("Keychain delete failed: \(status, privacy: .public)")
            }
        })

    private static var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.transcribe-thing.app",
            kSecAttrAccount as String: "openrouter-api-key",
        ]
    }
}

/// Moves the OpenRouter key from the login keychain into its key file (`KeyFileStore`), at launch, before anything
/// reads the key. Reading the item is the last Keychain prompt a rebuild shows; once the key file is there, the
/// Keychain is never asked again.
enum KeychainMigration {
    enum Outcome: Equatable, Sendable {
        /// A key file is there, readable or not: the Keychain isn't asked.
        case keyFileExists
        /// No item, or an empty one.
        case nothingToMove
        /// The Keychain didn't hand the key over (a denied or cancelled prompt, a locked keychain). There's no key
        /// until the next launch asks again, unless one is pasted in Models first.
        case keychainRefused
        /// The key file couldn't be written, or didn't read back the same key: the item stays for the next launch.
        case notWritten
        /// The key file holds the key and the item is deleted.
        case moved
    }

    @discardableResult
    static func run(into store: KeyFileStore, from keychain: LegacyKeychainKey) -> Outcome {
        guard !store.hasFile else { return .keyFileExists }
        let key: String
        do {
            key = try keychain.read()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            Log.app.error("Couldn't read the OpenRouter key from the Keychain: \(String(describing: error), privacy: .public)")
            return .keychainRefused
        }
        guard !key.isEmpty else { return .nothingToMove }
        do {
            try store.write(key)
            guard try store.lookup() == key else {
                Log.app.error("The key file didn't read back the key from the Keychain")
                return .notWritten
            }
        } catch {
            Log.app.error("Couldn't write the key file: \(String(describing: error), privacy: .public)")
            return .notWritten
        }
        keychain.delete()
        Log.app.info("Moved the OpenRouter key from the Keychain to its key file")
        return .moved
    }
}

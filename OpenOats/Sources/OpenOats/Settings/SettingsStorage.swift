import Foundation
import Security

/// Outcome of a secret lookup. `missing` means the store answered and there is
/// no such secret; `failure` means the store itself couldn't answer (for the
/// Keychain: an ACL denial after an unsigned rebuild, a locked keychain), so
/// the caller should retry later instead of concluding the secret is gone.
enum SecretLoadResult: Sendable, Equatable {
    case found(String)
    case missing
    case failure(OSStatus)
}

struct AppSecretStore: Sendable {
    let loadResult: @Sendable (String) -> SecretLoadResult
    let saveValue: @Sendable (String, String) -> Void

    init(
        loadResult: @escaping @Sendable (String) -> SecretLoadResult,
        saveValue: @escaping @Sendable (String, String) -> Void
    ) {
        self.loadResult = loadResult
        self.saveValue = saveValue
    }

    init(
        loadValue: @escaping @Sendable (String) -> String?,
        saveValue: @escaping @Sendable (String, String) -> Void
    ) {
        self.loadResult = { key in loadValue(key).map(SecretLoadResult.found) ?? .missing }
        self.saveValue = saveValue
    }

    func load(key: String) -> SecretLoadResult {
        loadResult(key)
    }

    func save(key: String, value: String) {
        saveValue(key, value)
    }

    static let keychain = AppSecretStore(
        loadResult: { KeychainHelper.loadResult(key: $0) },
        saveValue: { key, value in
            KeychainHelper.save(key: key, value: value)
        }
    )

    static let ephemeral = AppSecretStore(
        loadValue: { _ in nil },
        saveValue: { _, _ in }
    )
}

struct SettingsStorage {
    let defaults: UserDefaults
    let secretStore: AppSecretStore
    let defaultNotesDirectory: URL
    let runMigrations: Bool

    static func live(defaults: UserDefaults = .standard) -> SettingsStorage {
        SettingsStorage(
            defaults: defaults,
            secretStore: .keychain,
            defaultNotesDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/OpenOats"),
            runMigrations: true
        )
    }
}

/// Backward-compatible alias for existing test code.
typealias AppSettingsStorage = SettingsStorage

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.openoats.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func saveIfMissing(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        if case .found(let value) = loadResult(key: key) { return value }
        return nil
    }

    static func loadResult(key: String) -> SecretLoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                Log.keychain.error("Keychain item \(key, privacy: .public) returned undecodable data")
                return .failure(errSecDecode)
            }
            return .found(value)
        case errSecItemNotFound:
            return .missing
        default:
            // Typical cause: the item's ACL is bound to a previous build's code
            // signature (ad-hoc rebuilds get a new identity every time), so the
            // read is denied even though the item exists.
            Log.keychain.error("Keychain read for \(key, privacy: .public) failed: OSStatus \(status)")
            return .failure(status)
        }
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

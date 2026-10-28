import Foundation
import Security

enum MigrationResult: Equatable {
    case skipped
    case migrated
    case failed(String)
}

/// Injected so migration is testable without touching the real keychain.
protocol KeychainMigrating {
    func copyItems(fromService: String, toService: String) throws
}

/// One-time QuickCaptureMac → Captur migration (design spec §2).
///
/// Three steps behind one guard: move the Application Support directory, **copy**
/// (never move) the keychain items, and re-prefix the UserDefaults keys. A failure
/// leaves the old data untouched, does not set the guard — so it retries on the next
/// launch — and never blocks startup.
enum Migration {
    static let guardKey = "captur.didMigrateFromQuickCapture"
    static let defaultsPrefix = "captur."

    /// The unprefixed keys written by the pre-rename build.
    static let legacyDefaultsKeys = [
        "micPolicy",
        "hotkeyBindings",
        "dictationSensitivity",
        "thoughtSensitivity",
        "thoughtStyle",
        "openBrainEndpoint"
    ]

    @discardableResult
    static func runIfNeeded(fileManager: FileManager = .default,
                            defaults: UserDefaults = .standard,
                            oldSupportDir: URL = AppPaths.legacySupportDirectory(),
                            newSupportDir: URL = AppPaths.supportDirectory(),
                            keychain: KeychainMigrating = KeychainMigrator()) -> MigrationResult {
        guard !defaults.bool(forKey: guardKey) else { return .skipped }

        // Keychain first: it is additive and idempotent, and a failure here should
        // retry next launch rather than be silently swallowed behind a set guard.
        do {
            try keychain.copyItems(fromService: Keychain.legacyService,
                                   toService: Keychain.service)
        } catch {
            return .failed("keychain: \(error.localizedDescription)")
        }

        let oldExists = fileManager.fileExists(atPath: oldSupportDir.path)
        let newExists = fileManager.fileExists(atPath: newSupportDir.path)

        var didMove = false
        if oldExists && !newExists {
            do {
                try fileManager.moveItem(at: oldSupportDir, to: newSupportDir)
                didMove = true
            } catch {
                return .failed("support directory: \(error.localizedDescription)")
            }
        }

        migrateDefaults(defaults)
        defaults.set(true, forKey: guardKey)
        return didMove ? .migrated : .skipped
    }

    private static func migrateDefaults(_ defaults: UserDefaults) {
        for legacyKey in legacyDefaultsKeys {
            let newKey = defaultsPrefix + legacyKey
            guard defaults.object(forKey: newKey) == nil,
                  let value = defaults.object(forKey: legacyKey) else { continue }
            defaults.set(value, forKey: newKey)
        }
    }
}

/// Copies generic-password items from one keychain service to another, leaving the
/// originals in place. Never destroys the only copy of a key.
struct KeychainMigrator: KeychainMigrating {
    func copyItems(fromService: String, toService: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fromService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: toService,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            // Already present is success for our purposes — this is idempotent.
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        }
    }
}

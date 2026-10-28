import Foundation
import Security

enum Keychain {
    static let service = "com.awah.captur"
    /// The pre-rename service. Migration copies from here, never moves — it must not
    /// destroy the only copy of a key. See Migration.swift.
    static let legacyService = "com.awah.quickcapture.mac"
    private static let groqAccount = "groq_api_key"
    private static let openRouterAccount = "openrouter_api_key"
    private static let brainAccount = "brain_key"

    static func setAPIKey(_ key: String?) {
        set(key, account: groqAccount)
    }

    static func apiKey() -> String? {
        value(account: groqAccount)
    }

    static func setOpenRouterAPIKey(_ key: String?) {
        set(key, account: openRouterAccount)
    }

    static func openRouterAPIKey() -> String? {
        value(account: openRouterAccount)
    }

    static func setBrainKey(_ key: String?) {
        set(key, account: brainAccount)
    }

    static func brainKey() -> String? {
        value(account: brainAccount)
    }

    private static func set(_ value: String?, account: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func value(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }
}

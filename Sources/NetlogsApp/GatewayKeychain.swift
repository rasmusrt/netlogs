import Foundation
import Security

/// The gateway's API key, in the login Keychain and nowhere else.
///
/// Not `UserDefaults`, not the settings blob, not an export (plan, "Security
/// and privacy"). The Settings screen can save, replace and remove it, and can
/// ask whether one exists, but has no way to read it back — the only reader is
/// the session that sends it to a pinned gateway.
///
/// Service and account match the item the Phase 14.0 spike asked the owner to
/// create with `security add-generic-password`, so a key saved that way is the
/// one the app uses. Reading an item another program created asks the user
/// once; with ad-hoc signing, again after each rebuild.
enum GatewayKeychain {
    static let service = "netlogs-unifi"
    static let account = "local-api"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Whether a key is stored, without reading it — so asking never prompts.
    static var hasKey: Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// The key, or `nil`. May show the Keychain's own permission prompt, so
    /// call it off the main actor.
    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { return false }
        let update = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Netlogs gateway API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

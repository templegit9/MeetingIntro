import Foundation
import Security

/// Minimal wrapper around the macOS Keychain for storing short strings
/// (OAuth tokens, expiration timestamps as strings).
///
/// All items are stored as Generic Passwords under a single service identifier
/// (`com.oluyinka.MeetingIntro`) and keyed by `account`. Items use
/// `kSecAttrAccessibleAfterFirstUnlock` so the background calendar poller can
/// read them while the screen is locked but the user is logged in.
///
/// Keychain items created by a Developer-ID-signed app are ACL'd to that app's
/// code signing identity, so other apps running as the same user cannot read
/// them without an explicit prompt.
enum KeychainStore {

    static let service = "com.oluyinka.MeetingIntro"

    /// Set the value for `account`. Replaces any existing item.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Fetch the value for `account`, or nil if not present.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the value for `account`. No-op if not present.
    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

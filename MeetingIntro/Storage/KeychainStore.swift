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

    // Every SecItemCopyMatching on the file based keychain leaves a page securityd sent
    // mapped in this process (Apple's leak, measured: 6 pages per 20 reads). The poll
    // re-read the Graph token several times every 30 s, which grew the footprint to
    // 1.4 GB after 73 h. This app is the only writer of its items, so values are read
    // once and kept here; set and delete write through.
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    private static func cached(_ account: String) -> String?? {
        lock.lock(); defer { lock.unlock() }
        return cache[account]
    }

    private static func remember(_ value: String?, for account: String) {
        lock.lock(); cache[account] = .some(value); lock.unlock()
    }

    private static func forget(_ account: String) {
        lock.lock(); cache[account] = nil; lock.unlock()
    }

    /// Set the value for `account`. Replaces any existing item.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        debugMirrorSet(value, account)
        if case .some(.some(let current)) = cached(account), current == value { return true }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { remember(value, for: account); return true }
        guard updateStatus == errSecItemNotFound else { forget(account); return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        if added { remember(value, for: account) } else { forget(account) }
        return added
    }

    /// Fetch the value for `account`, or nil if not present.
    static func get(_ account: String) -> String? {
        if let hit = cached(account) { return hit ?? debugMirrorGet(account) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let s = String(data: data, encoding: .utf8) {
            remember(s, for: account)
            return s
        }
        // Only a definite "not there" is cached. A locked keychain or a denied read can
        // succeed later, so those are asked again next time.
        if status == errSecItemNotFound { remember(nil, for: account) }
        return debugMirrorGet(account)
    }

    /// Remove the value for `account`. No-op if not present.
    @discardableResult
    static func delete(_ account: String) -> Bool {
        debugMirrorSet(nil, account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        let deleted = status == errSecSuccess || status == errSecItemNotFound
        if deleted { remember(nil, for: account) } else { forget(account) }
        return deleted
    }

    // MARK: - Debug persistence fallback
    //
    // Debug builds are **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`), so every rebuild has
    // a different code identity and macOS ACLs the previous build's Keychain items away —
    // making API keys appear to "not persist" across relaunches while developing. Release
    // builds are Developer-ID signed with a stable identity, so the Keychain persists
    // normally there. To keep local testing from losing keys on every rebuild, DEBUG mirrors
    // values in UserDefaults. This is compiled out of Release (never store secrets in prefs).

    private static func debugMirrorSet(_ value: String?, _ account: String) {
        #if DEBUG
        let key = "kc_debug_\(account)"
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        #endif
    }

    private static func debugMirrorGet(_ account: String) -> String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "kc_debug_\(account)")
        #else
        return nil
        #endif
    }
}

import Foundation
import Security

/// The upload token, in the Keychain.
///
/// Not UserDefaults, ever. A token in a plist is readable by anything running as
/// the user, is swept into every backup, and shows up in a screenshot of the
/// settings window.
///
/// ## iCloud Keychain is asked for and usually not available
///
/// `synchronizable: true` would carry the token to the user's other machines, so
/// a service configured once is configured everywhere. It is requested by
/// default, and it **fails for most Mac apps** -- measured on macOS 26 with a
/// Developer ID signature, all four combinations:
///
/// | keychain | synchronizable | result |
/// |---|---|---|
/// | legacy (file) | false | `errSecSuccess` |
/// | legacy (file) | true | **-34018** `errSecMissingEntitlement` |
/// | data protection | false | **-34018** |
/// | data protection | true | **-34018** |
///
/// Synchronizable items live only in the data-protection keychain, and reaching
/// it needs `com.apple.application-identifier` or the App Sandbox — restricted
/// entitlements that require a provisioning profile. A plain Developer ID app
/// signed without one gets -34018 on every attempt.
///
/// So this falls back to the local keychain rather than failing. The failure it
/// replaces was silent and awful: `save` returned false, nothing was stored, and
/// the app went on believing it was unconfigured while its "Test connection"
/// button — which used the token still in the text field — said Connected.
///
/// `isSynchronized` reports which one was used, so a UI can tell the truth about
/// whether the other Mac will need this typed in again.
public struct LinkdropCredentials: Sendable {
    private let service: String
    private let account: String
    private let synchronizable: Bool

    public init(service: String, account: String = "upload-token", synchronizable: Bool = true) {
        self.service = service
        self.account = account
        self.synchronizable = synchronizable
    }

    /// Whether the stored token is the iCloud-synced kind. False also when there
    /// is no token at all.
    public var isSynchronized: Bool {
        synchronizable && load(synchronizable: true) != nil
    }

    /// A synchronizable query must say so on *every* call -- read, write and
    /// delete alike. Omitting the attribute does not mean "either kind"; it means
    /// "only the non-synchronizable ones", so a write with it and a read without
    /// it look exactly like a Keychain that lost the item.
    private func query(synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
                ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
    }

    public func load() -> String? {
        // iCloud first so that on a machine where it does work, a synced token
        // wins over a stale local one.
        if synchronizable, let token = load(synchronizable: true) { return token }
        return load(synchronizable: false)
    }

    private func load(synchronizable: Bool) -> String? {
        var request = query(synchronizable: synchronizable)
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                LinkdropLog.keychain.error("read failed: \(status, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete() }

        if synchronizable {
            let status = write(trimmed, synchronizable: true)
            if status == errSecSuccess { return true }
            guard status == errSecMissingEntitlement else {
                LinkdropLog.keychain.error("write failed: \(status, privacy: .public)")
                return false
            }
            // Expected on any Developer ID app without the entitlement. Said once,
            // at notice level, because it is a fact about the build rather than a
            // fault the user can act on.
            LinkdropLog.keychain.notice(
                "iCloud Keychain unavailable (-34018); storing the token on this Mac only")
        }

        let status = write(trimmed, synchronizable: false)
        if status != errSecSuccess {
            LinkdropLog.keychain.error("write failed: \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    private func write(_ token: String, synchronizable: Bool) -> OSStatus {
        let data = Data(token.utf8)
        let base = query(synchronizable: synchronizable)

        // Update first. `SecItemAdd` on an existing item returns
        // errSecDuplicateItem rather than replacing, and the obvious
        // delete-then-add loses the token outright if the process dies between
        // the two calls.
        let updated = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return errSecSuccess }

        var request = base
        request[kSecValueData as String] = data
        // `WhenUnlocked`, not `...ThisDeviceOnly`: the ThisDeviceOnly variants
        // cannot sync, which would defeat the synchronizable request outright.
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(request as CFDictionary, nil)
    }

    /// Removes both kinds, so "delete" never leaves a copy that `load` would
    /// find a moment later.
    @discardableResult
    public func delete() -> Bool {
        var ok = false
        for synchronizable in [true, false] {
            let status = SecItemDelete(query(synchronizable: synchronizable) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { ok = true }
        }
        return ok
    }
}

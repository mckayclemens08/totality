import Foundation
import Security
import TotalityCore

/// Where outside accounts' app passwords are kept on this device: the keychain, out of iCloud Keychain
/// and device backups, readable only while the device is unlocked. Mail's vault is the only writer.
public enum OutsideSecrets {
    public static let service = "app.totality.mail.outside"

    public static func keychain() -> any KeyStore {
        KeychainKeyStore(service: service)
    }

    /// Every outside sign-in on this device, for every account, for when the device's key goes or is
    /// handed back. The sealed records still restore them for their owner.
    public static func forgetAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

import CryptoKit
import Foundation
import TotalityCore

/// A key that identifies this device to the server. It stays in the Keychain, and only the public
/// half is uploaded. It opens nothing: content keys are separate.
enum DeviceKey {
    private static let name = "device-signing-key"

    static func publicKey(in store: any KeyStore) throws -> Data {
        if let stored = try store.load(name) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: stored).publicKey.rawRepresentation
        }
        let key = Curve25519.Signing.PrivateKey()
        try store.save(key.rawRepresentation, as: name)
        return key.publicKey.rawRepresentation
    }
}

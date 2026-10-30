import Auth
import Foundation
import TotalityCore

/// Keeps the login session in the Keychain, so tokens never sit in plain files.
struct SessionStorage: AuthLocalStorage {
    let store: any KeyStore

    func store(key: String, value: Data) throws {
        try store.save(value, as: key)
    }

    func retrieve(key: String) throws -> Data? {
        try store.load(key)
    }

    func remove(key: String) throws {
        try store.delete(key)
    }
}

import Foundation
import TotalityCore
import TotalityReader

/// Connects the Reader to this device's key and storage.
@MainActor
enum ReaderSetup {
    static func makeModel() throws -> ReaderModel {
        let rootKey = try ContentRootKey.loadOrCreate(in: KeychainKeyStore())
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Totality/Reader", isDirectory: true)
        let vault = ReaderVault(store: try FileBlobStore(directory: directory), rootKey: rootKey)
        return ReaderModel(vault: vault, listen: ListenController(engine: SystemSpeechEngine()))
    }
}

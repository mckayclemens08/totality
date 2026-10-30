import Foundation
import TotalityCore
import TotalityReader

/// Connects the Reader to this device's key and storage.
@MainActor
enum ReaderSetup {
    /// Storage opens first, so the key step knows whether sealed data is already here.
    static func makeModel() throws -> ReaderModel {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Totality/Reader", isDirectory: true)
        let store = try FileBlobStore(directory: directory)
        let rootKey = try ContentRootKey.loadOrCreate(in: KeychainKeyStore(), hasSealedData: !store.names().isEmpty)
        let vault = ReaderVault(store: store, rootKey: rootKey)
        return ReaderModel(vault: vault, listen: ListenController(engine: SystemSpeechEngine()))
    }
}

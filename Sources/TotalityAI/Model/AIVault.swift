import Foundation
import TotalityCore

public enum AIVaultError: Error, Equatable {
    case closed
}

/// Seals Ask Totality's grants, activity log, and recent on-device turns under the account's content root key.
public actor AIVault {
    public static let grantsSuffix = ".aigrants"
    public static let activitySuffix = ".aiactivity"
    public static let memorySuffix = ".aimemory"
    public static let sealedPurposes: [String: KeyPurpose] = [
        grantsSuffix: .aiGrants,
        activitySuffix: .aiActivity,
        memorySuffix: .aiMemory,
    ]

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var isClosed = false

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    public func close() {
        isClosed = true
    }

    public func grants() -> [AIAccessGrant]? {
        open(name(grantsID, Self.grantsSuffix), id: grantsID, purpose: .aiGrants)
    }

    public func saveGrants(_ grants: [AIAccessGrant]) throws {
        try write(grants, id: grantsID, purpose: .aiGrants, suffix: Self.grantsSuffix)
    }

    public func activity() -> [AIActivityEntry]? {
        open(name(activityID, Self.activitySuffix), id: activityID, purpose: .aiActivity)
    }

    public func saveActivity(_ entries: [AIActivityEntry]) throws {
        try write(entries, id: activityID, purpose: .aiActivity, suffix: Self.activitySuffix)
    }

    public func messages() -> [AIMessage]? {
        open(name(memoryID, Self.memorySuffix), id: memoryID, purpose: .aiMemory)
    }

    public func saveMessages(_ messages: [AIMessage]) throws {
        try write(messages, id: memoryID, purpose: .aiMemory, suffix: Self.memorySuffix)
    }

    private var grantsID: UUID { rootKey.derivedID(from: "ai-grants:all") }
    private var activityID: UUID { rootKey.derivedID(from: "ai-activity:all") }
    private var memoryID: UUID { rootKey.derivedID(from: "ai-memory:recent") }
    private func name(_ id: UUID, _ suffix: String) -> String { id.uuidString.lowercased() + suffix }

    private func open<T: Decodable>(_ name: String, id: UUID, purpose: KeyPurpose) -> T? {
        guard let sealed = try? store.read(name) else { return nil }
        let key = rootKey.objectKey(for: id, purpose: purpose)
        return (try? ContentCipher.open(sealed, key: key, objectID: id)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func write<T: Encodable>(_ value: T, id: UUID, purpose: KeyPurpose, suffix: String) throws {
        guard !isClosed else { throw AIVaultError.closed }
        let key = rootKey.objectKey(for: id, purpose: purpose)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(value), key: key, objectID: id), as: name(id, suffix))
    }
}

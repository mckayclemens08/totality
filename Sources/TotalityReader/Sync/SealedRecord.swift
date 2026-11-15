import Foundation
import TotalityCore

/// A value kept as one sealed record per person and synced, like the Reader's linked Drive folders. Two
/// devices' copies have to come together without losing either side, so the value says how.
public protocol MergedRecord: Codable, Equatable, Sendable {
    /// Both copies as one. It must give the same answer whichever way round, and again on its own result.
    static func merged(_ one: Self, _ other: Self) -> Self
}

/// Where one `MergedRecord` lives and how it syncs. It's sealed whole with the content key and travels in
/// a row's sealed details, with no body, as its own kind, so the server holds one opaque row per person.
///
/// The record's ID comes from the key and a label, so it's the same on every device of one person and no
/// one else can work it out: two people's records never meet on the server. A key move can leave a second
/// copy under the new key's ID on a device that hadn't synced yet. Every copy is read and merged, so
/// nothing is lost, and writes go to the first.
///
/// The owner passes each `SyncArea` step through to this, keeping `Pending` between `conflict` and `take`.
struct SealedRecordStore<Value: MergedRecord>: Sendable {
    let store: any BlobStore
    let rootKey: ContentRootKey
    let kind: ContentKind
    /// Gives the ID, with the key. Never change it, or devices stop finding each other's record.
    let label: String
    let suffix: String
    let purpose: KeyPurpose

    /// A conflict's merge, written when sync stores the other side's copy.
    struct Pending: Sendable {
        let id: UUID
        let remoteHash: String
        let merged: Value
    }

    func name(_ id: UUID) -> String { id.uuidString.lowercased() + suffix }

    func ids() throws -> [UUID] {
        try store.names().filter { $0.hasSuffix(suffix) }.compactMap {
            UUID(uuidString: String($0.dropLast(suffix.count)))
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func id() throws -> UUID {
        try ids().first ?? rootKey.derivedID(from: label)
    }

    /// Nil when there's none yet. A copy this key can't open belongs to someone else, and is left out.
    func load() throws -> Value? {
        let copies = try ids().compactMap { id in try store.read(name(id)).flatMap { try? open($0, id: id) } }
        guard let first = copies.first else { return nil }
        return copies.dropFirst().reduce(first, Value.merged)
    }

    func write(_ value: Value) throws {
        let id = try id()
        try store.write(try seal(value, id: id), as: name(id))
    }

    func seal(_ value: Value, id: UUID) throws -> Data {
        try ContentCipher.seal(JSONEncoder().encode(value), key: rootKey.objectKey(for: id, purpose: purpose), objectID: id)
    }

    func open(_ sealed: Data, id: UUID) throws -> Value {
        try JSONDecoder().decode(Value.self, from: ContentCipher.open(sealed, key: rootKey.objectKey(for: id, purpose: purpose), objectID: id))
    }

    // MARK: Sync's steps

    func object(_ id: UUID) throws -> SealedObject? {
        try store.read(name(id)).map { SealedObject(id: id, kind: kind, meta: $0, body: nil) }
    }

    func verified(_ id: UUID) throws -> SealedObject? {
        guard let object = try object(id) else { return nil }
        _ = try open(object.meta, id: id)
        return object
    }

    /// Takes a copy from the server. Only one that opens under this key is taken, because a server can
    /// send anything; one that settled a conflict is written as the merge of both sides, which the next
    /// sync sends back up.
    func take(_ object: SealedObject, ifLocalHash expected: String?, pending: inout Pending?) throws {
        guard object.kind == kind else { throw CryptoError.authenticationFailed }
        guard try self.object(object.id)?.hash == expected else { throw SyncError.changedLocally }
        let incoming = try open(object.meta, id: object.id)
        if let settled = pending, settled.id == object.id, settled.remoteHash == object.hash {
            pending = nil
            try store.write(try seal(Value.merged(settled.merged, incoming), id: object.id), as: name(object.id))
        } else {
            try store.write(object.meta, as: name(object.id))
        }
    }

    /// Both sides are kept. Sync takes the other side's copy (`.keepRemote`), and `take` writes the merge
    /// in its place.
    func conflict(local: SealedObject, remote: SealedObject) throws -> Pending {
        let merged = Value.merged(try open(local.meta, id: local.id), try open(remote.meta, id: remote.id))
        return Pending(id: remote.id, remoteHash: remote.hash, merged: merged)
    }
}

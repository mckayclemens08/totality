import Foundation
import TotalityCore

public enum HikingError: Error, Equatable {
    case closed, offline, failed, badAnswer
}

/// Everything Hiking keeps, sealed with the content key on this iPhone (issue 240, section 3): each hike,
/// each trail saved for offline use, and the last list of trails nearby. None of it syncs in v1, so none of
/// it is uploaded. Each blob is named by an ID: a hike's own random one, or one derived from the key for a
/// trail or the cache, so the folder says nothing about which trails they are.
public actor HikeLog {
    public static let hikeSuffix = ".hike"
    public static let trailSuffix = ".hiketrail"
    public static let cacheSuffix = ".hikecache"
    /// How a key move finds each blob to seal again.
    public static let sealedPurposes: [String: KeyPurpose] = [hikeSuffix: .hike, trailSuffix: .hikeTrail, cacheSuffix: .hikeCache]

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var isClosed = false

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    // MARK: Hikes

    public func hikes() -> [Hike] {
        let names = (try? store.names()) ?? []
        return names.compactMap { name -> Hike? in
            guard name.hasSuffix(Self.hikeSuffix), let id = UUID(uuidString: String(name.dropLast(Self.hikeSuffix.count))) else { return nil }
            return open(name, id: id, purpose: .hike)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    public func save(_ hike: Hike) throws {
        try write(hike, id: hike.id, purpose: .hike, suffix: Self.hikeSuffix)
    }

    public func delete(hike id: UUID) throws {
        guard !isClosed else { throw HikingError.closed }
        try store.delete(name(id, Self.hikeSuffix))
    }

    // MARK: Saved trails

    public func savedTrails() -> [Trail] {
        let names = (try? store.names()) ?? []
        return names.compactMap { name -> Trail? in
            guard name.hasSuffix(Self.trailSuffix), let id = UUID(uuidString: String(name.dropLast(Self.trailSuffix.count))) else { return nil }
            return open(name, id: id, purpose: .hikeTrail)
        }
        .sorted { ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
    }

    public func save(_ trail: Trail) throws {
        try write(trail, id: trailID(trail.id), purpose: .hikeTrail, suffix: Self.trailSuffix)
    }

    public func forget(trail id: String) throws {
        guard !isClosed else { throw HikingError.closed }
        try store.delete(name(trailID(id), Self.trailSuffix))
    }

    // MARK: Nearby

    public func nearby() -> NearbyTrails? {
        let id = cacheID
        return open(name(id, Self.cacheSuffix), id: id, purpose: .hikeCache)
    }

    public func keep(_ nearby: NearbyTrails) throws {
        try write(nearby, id: cacheID, purpose: .hikeCache, suffix: Self.cacheSuffix)
    }

    /// Refuses all further writes, for a key move.
    public func close() {
        isClosed = true
    }

    // MARK: Sealing

    private var cacheID: UUID { rootKey.derivedID(from: "hike-cache:nearby") }
    private func trailID(_ osmID: String) -> UUID { rootKey.derivedID(from: "hike-trail:\(osmID)") }
    private func name(_ id: UUID, _ suffix: String) -> String { id.uuidString.lowercased() + suffix }

    private func open<T: Decodable>(_ name: String, id: UUID, purpose: KeyPurpose) -> T? {
        guard let sealed = try? store.read(name) else { return nil }
        let key = rootKey.objectKey(for: id, purpose: purpose)
        return (try? ContentCipher.open(sealed, key: key, objectID: id)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func write<T: Encodable>(_ value: T, id: UUID, purpose: KeyPurpose, suffix: String) throws {
        guard !isClosed else { throw HikingError.closed }
        let key = rootKey.objectKey(for: id, purpose: purpose)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(value), key: key, objectID: id), as: name(id, suffix))
    }
}

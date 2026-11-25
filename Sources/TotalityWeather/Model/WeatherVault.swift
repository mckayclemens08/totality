import Foundation
import TotalityCore

/// The person's `WeatherPlaces`, sealed with the content key as one record and synced with their other
/// devices. The server holds one opaque row that changes now and then (issue 203, section 4).
public actor WeatherPlaceBook {
    public static let suffix = ".weatherplaces"
    /// How a key move finds the record to seal again.
    public static let sealedPurposes: [String: KeyPurpose] = [suffix: .weatherPlaces]

    private let record: SealedRecordStore<WeatherPlaces>
    private var pending: SealedRecordStore<WeatherPlaces>.Pending?
    private var isClosed = false

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        // The label gives the record's ID with the key. Never change it.
        record = SealedRecordStore(store: store, rootKey: rootKey, kind: .weatherPlaces, label: "weather-places", suffix: Self.suffix, purpose: .weatherPlaces)
    }

    public func load() -> WeatherPlaces {
        (try? record.load()) ?? WeatherPlaces()
    }

    /// Adds `places` to what's kept and returns the result.
    @discardableResult
    public func add(_ places: WeatherPlaces) throws -> WeatherPlaces {
        guard !isClosed else { throw WeatherError.closed }
        let merged = WeatherPlaces.merged(load(), places)
        if merged != (try? record.load()) { try record.write(merged) }
        return merged
    }

    /// Refuses all further writes, for a key move.
    public func close() {
        isClosed = true
    }
}

extension WeatherPlaceBook: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.weatherPlaces] }

    public func sealedObjectIDs() throws -> [UUID] { try record.ids() }

    public func sealedHash(of id: UUID) throws -> String? { try record.object(id)?.hash }

    public func sealedObject(_ id: UUID) throws -> SealedObject? { try record.object(id) }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? { try record.verified(id) }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        try record.take(object, ifLocalHash: expected, pending: &pending)
    }

    /// A server's word that the record was deleted can't be proved, and nothing here deletes it, so it stays.
    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {}

    public func deletedObjectIDs() throws -> Set<UUID> { [] }

    public func clearDeletion(_ id: UUID) throws {}

    /// Both sides' places, the later change of each.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        pending = try record.conflict(local: local, remote: remote)
        return .keepRemote
    }

    public func emptyOldTrash() throws {}
}

public enum WeatherError: Error, Equatable {
    case closed, offline, failed, badAnswer
}

/// One place's last forecast with the name to show for it, as kept on the device.
public struct CachedForecast: Codable, Equatable, Sendable {
    public var name: String
    public var forecast: Forecast

    public init(name: String, forecast: Forecast) {
        self.name = name
        self.forecast = forecast
    }
}

/// The last forecast for each place, sealed on the device so Weather opens at once. It never syncs: it lives
/// in its own folder that sync doesn't reach. Each blob's name is an ID derived from the key and the place,
/// so the folder says nothing about which places they are.
public actor ForecastCache {
    public static let suffix = ".forecast"
    public static let sealedPurposes: [String: KeyPurpose] = [suffix: .weatherCache]
    /// The key for the forecast where the person is.
    public static let here = "here"

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var isClosed = false

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    private func id(for key: String) -> UUID { rootKey.derivedID(from: "weather-cache:\(key)") }
    private func name(_ id: UUID) -> String { id.uuidString.lowercased() + Self.suffix }

    public func read(_ key: String) -> CachedForecast? {
        let id = id(for: key)
        guard let sealed = try? store.read(name(id)) else { return nil }
        let objectKey = rootKey.objectKey(for: id, purpose: .weatherCache)
        return (try? ContentCipher.open(sealed, key: objectKey, objectID: id)).flatMap { try? JSONDecoder().decode(CachedForecast.self, from: $0) }
    }

    public func write(_ cached: CachedForecast, for key: String) throws {
        guard !isClosed else { throw WeatherError.closed }
        let id = id(for: key)
        let objectKey = rootKey.objectKey(for: id, purpose: .weatherCache)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(cached), key: objectKey, objectID: id), as: name(id))
    }

    /// Forgets the forecasts of places no longer saved.
    public func keepOnly(_ keys: Set<String>) {
        let kept = Set(keys.map { name(id(for: $0)) })
        for blob in (try? store.names()) ?? [] where blob.hasSuffix(Self.suffix) && !kept.contains(blob) {
            try? store.delete(blob)
        }
    }

    public func close() {
        isClosed = true
    }
}

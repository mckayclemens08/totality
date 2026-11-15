import Foundation
import TotalityCore

extension ReadingPlaces: MergedRecord {}

/// Where the person stopped in each Reader file, kept on this device and synced as one sealed record.
///
/// A new place is held here first and sent into the synced record only once the oldest held one has waited
/// `hold`, or as the app goes to the background. So the server sees the record change now and then while
/// the app is in use, which it already sees from background refresh, and never when any one file was
/// opened. The held places are sealed too, and this device reads them straight away.
public actor ReadingPlaceBook {
    static let syncedSuffix = ".places"
    static let heldSuffix = ".places.held"
    /// How long a new place waits before it goes into the synced record.
    static let hold: TimeInterval = 5 * 60

    private let synced: SealedRecordStore<ReadingPlaces>
    private let held: SealedRecordStore<ReadingPlaces>
    private let now: @Sendable () -> Date
    private var heldSince: Date?
    private var pending: SealedRecordStore<ReadingPlaces>.Pending?

    public init(store: any BlobStore, rootKey: ContentRootKey, now: @escaping @Sendable () -> Date = Date.init) {
        // The labels give the records' IDs with the key. Never change them.
        synced = SealedRecordStore(store: store, rootKey: rootKey, kind: .readerPlaces, label: "reader-places", suffix: Self.syncedSuffix, purpose: .readerPlaces)
        held = SealedRecordStore(store: store, rootKey: rootKey, kind: .readerPlaces, label: "reader-places-held", suffix: Self.heldSuffix, purpose: .readerPlaces)
        self.now = now
    }

    /// Both records together: everything this device knows.
    func all() -> ReadingPlaces {
        let one = (try? synced.load()) ?? ReadingPlaces()
        let other = (try? held.load()) ?? ReadingPlaces()
        return ReadingPlaces.merged(one, other)
    }

    func place(of id: UUID) -> ReadingPlace? {
        all().places[id]
    }

    func remember(_ spot: ReadingPlace.Spot, listen: Int?, for id: UUID) throws {
        var places = (try? held.load()) ?? ReadingPlaces()
        if let kept = places.places[id], kept.spot == spot, kept.listen == listen { return }
        places.set(ReadingPlace(spot: spot, listen: listen, at: now()), for: id)
        try held.write(places)
        if heldSince == nil { heldSince = now() }
        try publish(force: false)
    }

    /// Sends held places into the synced record: as the app goes to the background, or once they've waited.
    public func publish(force: Bool = true) throws {
        guard let waiting = try held.load(), !waiting.places.isEmpty || !waiting.removed.isEmpty else {
            heldSince = nil
            return
        }
        // A held place left from before the app last quit counts as having waited.
        let since = heldSince ?? .distantPast
        guard force || now().timeIntervalSince(since) >= Self.hold else { return }
        let merged = ReadingPlaces.merged((try synced.load()) ?? ReadingPlaces(), waiting)
        try synced.write(merged)
        try held.write(ReadingPlaces())
        heldSince = nil
    }

    /// Drops the places of items deleted for good, here and, at the next send, everywhere.
    func forget(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        var waiting = (try? held.load()) ?? ReadingPlaces()
        let date = now()
        for id in ids { waiting.removed[id] = max(waiting.removed[id] ?? date, date) }
        try held.write(waiting.normalized())
        if heldSince == nil { heldSince = date }
    }
}

/// The synced record, as sync reaches it. The held places never leave the device.
extension ReadingPlaceBook: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.readerPlaces] }

    public func sealedObjectIDs() throws -> [UUID] { try synced.ids() }

    public func sealedHash(of id: UUID) throws -> String? { try synced.object(id)?.hash }

    public func sealedObject(_ id: UUID) throws -> SealedObject? { try synced.object(id) }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? { try synced.verified(id) }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        try synced.take(object, ifLocalHash: expected, pending: &pending)
    }

    /// A server's word that the record was deleted can't be proved, and nothing here deletes it, so it stays.
    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {}

    public func deletedObjectIDs() throws -> Set<UUID> { [] }

    public func clearDeletion(_ id: UUID) throws {}

    /// The newest place for each item from either side.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        pending = try synced.conflict(local: local, remote: remote)
        return .keepRemote
    }

    public func emptyOldTrash() throws {}
}

import Foundation
import TotalityCore

/// The Clock's two sealed records (issue 204, section 4). `clock_items` holds world cities, timer presets
/// and the stopwatch, and syncs as one opaque row per person. The device record holds alarms, bedtime,
/// running timers and added sounds, and never leaves this device. Both are sealed with the content key
/// before they're written.
public actor ClockBook {
    public static let itemsSuffix = ".clock"
    public static let deviceSuffix = ".clock-device"
    /// How a key move finds the records to seal again.
    public static let sealedPurposes: [String: KeyPurpose] = [itemsSuffix: .clockItems, deviceSuffix: .clockDevice]

    private let items: SealedRecordStore<ClockItems>
    private let device: SealedRecordStore<ClockDevice>
    private var pending: SealedRecordStore<ClockItems>.Pending?

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        // The labels give the records' IDs with the key. Never change them.
        items = SealedRecordStore(store: store, rootKey: rootKey, kind: .clockItems, label: "clock-items", suffix: Self.itemsSuffix, purpose: .clockItems)
        device = SealedRecordStore(store: store, rootKey: rootKey, kind: .clockItems, label: "clock-device", suffix: Self.deviceSuffix, purpose: .clockDevice)
    }

    /// The synced record, or nil when nothing's been kept yet.
    public func loadItems() throws -> ClockItems? {
        try items.load()
    }

    public func loadDevice() throws -> ClockDevice? {
        try device.load()
    }

    /// Adds `value` to what's kept and returns the result, so another device's changes are never lost.
    @discardableResult
    public func save(_ value: ClockItems) throws -> ClockItems {
        let stored = try items.load()
        let merged = stored.map { ClockItems.merged($0, value) } ?? value
        if merged != stored { try items.write(merged) }
        return merged
    }

    public func save(_ value: ClockDevice) throws {
        try device.write(value)
    }
}

/// Only the synced record takes part. The device record's suffix is apart, so sync never sees it.
extension ClockBook: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.clockItems] }

    public func sealedObjectIDs() throws -> [UUID] { try items.ids() }

    public func sealedHash(of id: UUID) throws -> String? { try items.object(id)?.hash }

    public func sealedObject(_ id: UUID) throws -> SealedObject? { try items.object(id) }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? { try items.verified(id) }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        try items.take(object, ifLocalHash: expected, pending: &pending)
    }

    /// A server's word that the record was deleted can't be proved, and nothing here deletes it, so it stays.
    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {}

    public func deletedObjectIDs() throws -> Set<UUID> { [] }

    public func clearDeletion(_ id: UUID) throws {}

    /// Both sides' changes, the later of each.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        pending = try items.conflict(local: local, remote: remote)
        return .keepRemote
    }

    public func emptyOldTrash() throws {}
}

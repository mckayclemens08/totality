import Foundation
import TotalityCore

public struct CalendarListing: Sendable, Equatable {
    public let events: [CalendarEvent]
    /// Events that would not decrypt. The UI says so instead of hiding them.
    public let unreadable: Int
}

public enum CalendarError: Error, Equatable {
    case notFound
    case mismatched
    case closed
    case changed
}

/// A person's own events. Each one is a single blob, and its name holds only the object ID.
public actor CalendarVault {
    /// How each kind of blob is sealed, so a key change can reach them without knowing what they are.
    public static let sealedPurposes: [String: KeyPurpose] = [".event": .event, ".event.trash": .event]
    /// How long something removed by another device stays recoverable here.
    public static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var isClosed = false
    private var hashes: [UUID: String] = [:]

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    private func name(_ id: UUID) -> String { "\(id.uuidString.lowercased()).event" }
    private func deletionName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).deleted" }

    /// Refuses all further writes, so nothing lands under the old key during a key move.
    public func close() {
        isClosed = true
    }

    public func save(_ event: CalendarEvent) throws {
        guard !isClosed else { throw CalendarError.closed }
        hashes[event.id] = nil
        let key = rootKey.objectKey(for: event.id, purpose: .event)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(event), key: key, objectID: event.id), as: name(event.id))
    }

    /// Saves only if `original` is still the version here, so a screen that fell behind a sync can't
    /// undo what the sync brought in. Checked in one step, so nothing can land in between.
    public func save(_ events: [CalendarEvent], ifStillAt original: CalendarEvent) throws {
        guard try event(original.id).updatedAt == original.updatedAt else { throw CalendarError.changed }
        for event in events { try save(event) }
    }

    public func delete(_ id: UUID, ifStillAt original: CalendarEvent) throws {
        guard try event(original.id).updatedAt == original.updatedAt else { throw CalendarError.changed }
        try delete(id)
    }

    public func event(_ id: UUID) throws -> CalendarEvent {
        guard let sealed = try store.read(name(id)) else { throw CalendarError.notFound }
        let key = rootKey.objectKey(for: id, purpose: .event)
        let event = try JSONDecoder().decode(CalendarEvent.self, from: ContentCipher.open(sealed, key: key, objectID: id))
        guard event.id == id else { throw CalendarError.mismatched }
        return event
    }

    public func list() throws -> CalendarListing {
        var events: [CalendarEvent] = []
        var unreadable = 0
        for file in try store.names() where file.hasSuffix(".event") {
            guard let id = UUID(uuidString: String(file.dropLast(".event".count))) else { continue }
            do {
                events.append(try event(id))
            } catch is CryptoError, is DecodingError, is CalendarError {
                unreadable += 1
            }
        }
        return CalendarListing(events: events.sorted { $0.start < $1.start }, unreadable: unreadable)
    }

    public func delete(_ id: UUID) throws {
        guard !isClosed else { throw CalendarError.closed }
        // The record goes first, so a crash can't lose the fact that this was deleted on purpose.
        try store.write(Data(), as: deletionName(id))
        try store.delete(name(id))
        hashes[id] = nil
    }
}

extension CalendarVault: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.event] }

    public func sealedObjectIDs() throws -> [UUID] {
        // A crash can stop a delete halfway. The record says what was meant, so finish it.
        if !isClosed {
            for id in try deletedObjectIDs() where try store.read(name(id)) != nil {
                try store.delete(name(id))
                hashes[id] = nil
            }
        }
        return try store.names().compactMap { file in
            file.hasSuffix(".event") ? UUID(uuidString: String(file.dropLast(".event".count))) : nil
        }
    }

    public func sealedHash(of id: UUID) throws -> String? {
        if let known = hashes[id] { return known }
        let hash = try sealedObject(id)?.hash
        hashes[id] = hash
        return hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        try store.read(name(id)).map { SealedObject(id: id, kind: .event, meta: $0, body: nil) }
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        _ = try opened(object)
        return object
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw CalendarError.closed }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        if expected == nil, try store.read(deletionName(object.id)) != nil { throw SyncError.changedLocally }
        _ = try opened(object)
        try store.write(object.meta, as: name(object.id))
        hashes[object.id] = nil
    }

    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {
        guard !isClosed else { throw CalendarError.closed }
        guard try sealedHash(of: id) == expected else { throw SyncError.changedLocally }
        guard let sealed = try store.read(name(id)) else { return }
        // The stamp goes first, so a crash can't leave trash that's never cleaned up.
        try store.write(Data(ISO8601DateFormatter().string(from: Date()).utf8), as: trashStampName(id))
        try store.write(sealed, as: name(id) + ".trash")
        try store.delete(name(id))
        hashes[id] = nil
    }

    public func emptyOldTrash() throws {
        guard !isClosed else { return }
        let formatter = ISO8601DateFormatter()
        for file in try store.names() where file.hasSuffix(".trashed") {
            guard let id = UUID(uuidString: String(file.dropLast(".trashed".count))),
                  let stamp = try store.read(file), let date = formatter.date(from: String(decoding: stamp, as: UTF8.self)),
                  Date().timeIntervalSince(date) > Self.trashLifetime
            else { continue }
            try store.delete(name(id) + ".trash")
            try store.delete(file)
        }
    }

    private func trashStampName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).trashed" }

    public func deletedObjectIDs() throws -> Set<UUID> {
        Set(try store.names().compactMap { file in
            file.hasSuffix(".deleted") ? UUID(uuidString: String(file.dropLast(".deleted".count))) : nil
        })
    }

    public func clearDeletion(_ id: UUID) throws {
        try store.delete(deletionName(id))
    }

    /// The newest version stays, and an older one that really differs is kept as a copy.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        let mine = try opened(local)
        let theirs = try opened(remote)
        let keepMine = mine.updatedAt >= theirs.updatedAt
        var older = keepMine ? theirs : mine
        let newer = keepMine ? mine : theirs
        older.updatedAt = newer.updatedAt
        if older != newer {
            let copy = CalendarEvent(
                // Named for the version it preserves, so retries can't double it.
                id: UUID(derivedFrom: (keepMine ? remote : local).hash),
                title: "\(older.displayTitle) (conflict copy)", location: older.location, notes: older.notes,
                start: older.start, end: older.end, isAllDay: older.isAllDay, timeZoneID: older.timeZoneID,
                repeatRule: older.repeatRule, skipped: older.skipped, reminderMinutes: older.reminderMinutes,
                attachments: older.attachments
            )
            if try store.read(name(copy.id)) == nil { try save(copy) }
        }
        return keepMine ? .keepLocal : .keepRemote
    }

    private func opened(_ object: SealedObject) throws -> CalendarEvent {
        let key = rootKey.objectKey(for: object.id, purpose: .event)
        let event = try JSONDecoder().decode(CalendarEvent.self, from: ContentCipher.open(object.meta, key: key, objectID: object.id))
        guard event.id == object.id else { throw CryptoError.authenticationFailed }
        return event
    }
}

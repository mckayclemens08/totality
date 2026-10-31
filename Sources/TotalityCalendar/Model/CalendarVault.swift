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
}

/// A person's own events. Each one is a single blob, and its name holds only the object ID.
public actor CalendarVault {
    /// How each kind of blob is sealed, so a key change can reach them without knowing what they are.
    public static let sealedPurposes: [String: KeyPurpose] = [".event": .event]

    private let store: any BlobStore
    private let rootKey: ContentRootKey

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    private func name(_ id: UUID) -> String { "\(id.uuidString.lowercased()).event" }

    public func save(_ event: CalendarEvent) throws {
        let key = rootKey.objectKey(for: event.id, purpose: .event)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(event), key: key, objectID: event.id), as: name(event.id))
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
        try store.delete(name(id))
    }
}

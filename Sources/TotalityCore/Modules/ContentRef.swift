import Foundation

public enum Visibility: String, Codable, Sendable, CaseIterable {
    case `private`, contacts, `public`
}

public enum ContentKind: String, Codable, Sendable, CaseIterable {
    case file, note, doc, photo, video, audio, post, event, transaction
    case aiMemory = "ai_memory"
}

public enum ModuleID: String, Codable, Sendable, CaseIterable {
    case reader, calendar, mail, player, photos, money, ai, messages, calls, social, web
}

/// Where an object's key lives, matching `content_objects.key_ref`.
public enum KeyRef: Hashable, Sendable {
    case crk(objectID: UUID)
    case room(roomID: String, eventID: String)
    case plain
}

extension KeyRef: RawRepresentable, Codable {
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "plain" where parts.count == 2 && parts[1].isEmpty:
            self = .plain
        case "crk":
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            self = .crk(objectID: id)
        case "mxroom":
            // Matrix room and event IDs can contain colons, but event IDs always start with $.
            guard parts.count == 2, let split = parts[1].range(of: ":$") else { return nil }
            let room = String(parts[1][..<split.lowerBound])
            let event = String(parts[1][parts[1].index(after: split.lowerBound)...])
            guard !room.isEmpty else { return nil }
            self = .room(roomID: room, eventID: event)
        default:
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .crk(let id): "crk:\(id.uuidString.lowercased())"
        case .room(let room, let event): "mxroom:\(room):\(event)"
        case .plain: "plain:"
        }
    }
}

/// The only type modules use to refer to each other's content. The preview is enough to draw a
/// chip for content the rendering module does not understand.
public struct ContentRef: Codable, Hashable, Sendable {
    public struct Preview: Codable, Hashable, Sendable {
        public let title: String
        public let thumbnailKey: String?

        public init(title: String, thumbnailKey: String? = nil) {
            self.title = title
            self.thumbnailKey = thumbnailKey
        }
    }

    public let module: ModuleID
    public let kind: ContentKind
    public let id: UUID
    public let keyRef: KeyRef
    public let preview: Preview

    public init(module: ModuleID, kind: ContentKind, id: UUID, keyRef: KeyRef, preview: Preview) {
        self.module = module
        self.kind = kind
        self.id = id
        self.keyRef = keyRef
        self.preview = preview
    }
}

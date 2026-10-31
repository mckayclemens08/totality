import Foundation

/// One note or file. All of this is encrypted at rest, because titles and filenames are content.
public struct ReaderItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case note, file
    }

    public static let speechifyCollection = "Speechify Library"

    public let id: UUID
    public let kind: Kind
    public var title: String
    public var collection: String?
    public var mime: String?
    public var byteCount: Int
    public let createdAt: Date
    public var updatedAt: Date
    /// Where Listen stopped, as a UTF-16 offset into the item's readable text.
    public var listenPosition: Int

    public var displayTitle: String {
        title.isEmpty ? "Untitled" : title
    }
}

public enum ReaderError: Error, Equatable {
    case notFound
    case notANote
    case tooLarge
    case passwordProtected
    case notReadable
    case closed
}

extension ReaderError {
    /// Written for the person using the app.
    public var message: String {
        switch self {
        case .notFound: "This item is no longer here."
        case .notANote: "Only notes can be edited."
        case .tooLarge: "Files can be up to 49 MB for now."
        case .passwordProtected: "This PDF is password protected, so it can be stored but not read."
        case .notReadable: "Totality can keep this file, but it can't read this format yet."
        case .closed: "This wasn't saved because your encryption key was changing. Try again."
        }
    }
}

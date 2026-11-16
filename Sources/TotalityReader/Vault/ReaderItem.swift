import Foundation

/// One doc, file, or folder. All of this is encrypted at rest, because titles and filenames are content.
public struct ReaderItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case note, file, folder
    }

    public let id: UUID
    public let kind: Kind
    public var title: String
    /// The old flat label. `adoptCollections` turns it into a folder.
    public var collection: String?
    public var mime: String?
    public var byteCount: Int
    public let createdAt: Date
    public var updatedAt: Date
    /// Where Listen stopped, as a UTF-16 offset into the item's readable text.
    public var listenPosition: Int
    public var folderID: UUID? = nil
    /// A doc converted for the writing editor keeps its old self here until the person says the new
    /// version looks right.
    public var keptOriginalID: UUID? = nil
    /// The length a doc is meant to reach, in words. It's sealed with the doc, so it follows it to every
    /// device, and only its owner can read it.
    public var wordTarget: Int? = nil

    public var displayTitle: String {
        title.isEmpty ? "Untitled" : title
    }

    /// What sorting by type groups on, and what the library shows.
    public var typeName: String {
        switch (kind, mime) {
        case (.folder, _): "Folder"
        case (.note, _): "Doc"
        case (_, "application/pdf"): "PDF"
        case (_, ReadableText.epubMime): "EPUB"
        case (_, ReadableText.wordMime): "Word"
        case (_, References.mime): "References"
        default: "File"
        }
    }
}

public enum ReaderError: Error, Equatable {
    case notFound
    case notANote
    /// Over the sealed store's 5 GB for one file.
    case tooLarge
    /// Kept, but too big for a viewer that needs the whole file in memory, like a huge image.
    case tooLargeToShow
    /// The account's storage on the Totality server hasn't room for it.
    case storageFull
    /// This device hasn't room for its sealed copy.
    case noRoomHere
    case passwordProtected
    case folderInsideItself
    case notReadable
    case closed
}

extension ReaderError {
    /// Written for the person using the app.
    public var message: String {
        switch self {
        case .notFound: "This item is no longer here."
        case .folderInsideItself: "A folder can't go inside itself."
        case .notANote: "Only notes can be edited."
        case .tooLarge: "Files can be up to 5 GB."
        case .tooLargeToShow: "This file is too big to show here. It's kept safely, and Listen and search still read it."
        case .storageFull: "Your Totality storage is full. Delete something from Recently Deleted or the Reader, then try again."
        case .noRoomHere: "There isn't room on this device for this file. Free up some space, then try again."
        case .passwordProtected: "This PDF is password protected, so it can be stored but not read."
        case .notReadable: "Totality can keep this file, but it can't read this format yet."
        case .closed: "This wasn't saved because your encryption key was changing. Try again."
        }
    }
}

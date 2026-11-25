import Foundation
import TotalityCore

extension ReaderModel {
    /// Shares a doc (issue 228): its text goes into a new end-to-end encrypted room, then the private copy
    /// moves to Recently Deleted, so there's one copy everyone edits. Returns the room.
    public func share(_ item: ReaderItem, with people: [String: SharedRole]) async -> String? {
        guard let shared, item.kind == .note else { return nil }
        let opened: (item: ReaderItem, text: String)
        do {
            opened = try await loadMarkdown(item.id)
        } catch {
            notice = "\(item.displayTitle) couldn't be opened to share."
            return nil
        }
        guard let room = await shared.share(title: opened.item.title, text: opened.text, with: people) else { return nil }
        await delete(opened.item)
        return room
    }

    /// Saves a shared doc's text as a private doc at the top of the Reader.
    @discardableResult
    public func keepPrivateCopy(title: String, text: String) async -> ReaderItem? {
        guard let item = await newNote() else { return nil }
        guard await saveNote(item.id, title: title, body: text) else { return nil }
        return item
    }
}

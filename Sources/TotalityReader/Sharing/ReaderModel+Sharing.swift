import Foundation
import TotalityCore

extension ReaderModel {
    /// Shares a doc (issue 228): its text goes into a new end-to-end encrypted room, then the private copy
    /// moves to Recently Deleted, so there's one copy everyone edits. Returns the room.
    ///
    /// The private copy moves only once this device can open the shared one. Until then it stays, so a
    /// doc that didn't come back from the room is never lost.
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
        guard shared.doc(room)?.isComplete == true else { return room }
        SharedFrom.remember(opened.item.id, for: room, in: sharedFrom)
        await delete(opened.item)
        return room
    }

    /// The private copy a shared doc was made from, while it's still in Recently Deleted. Found by what this
    /// device noted when it shared, or else the doc moved there closest to when the room's first post went,
    /// within ten minutes after it.
    public func privateCopy(of doc: SharedDocState) -> TrashedItem? {
        let notes = trash.filter { $0.item.kind == .note }
        if let id = SharedFrom.item(for: doc.room, in: sharedFrom), let found = notes.first(where: { $0.item.id == id }) {
            return found
        }
        guard let started = doc.started else { return nil }
        return notes
            .filter { $0.deletedAt >= started.addingTimeInterval(-60) && $0.deletedAt <= started.addingTimeInterval(600) }
            .min { abs($0.deletedAt.timeIntervalSince(started)) < abs($1.deletedAt.timeIntervalSince(started)) }
    }

    /// Saves a shared doc's text as a private doc at the top of the Reader.
    @discardableResult
    public func keepPrivateCopy(title: String, text: String) async -> ReaderItem? {
        guard let item = await newNote() else { return nil }
        guard await saveNote(item.id, title: title, body: text) else { return nil }
        return item
    }
}

/// Which private doc each shared room was made from, so a copy that went to Recently Deleted can be found
/// again. Only IDs are kept: a room's ID and a doc's random UUID, never a title or any text.
enum SharedFrom {
    static let key = "reader.sharedFrom"

    static func remember(_ item: UUID, for room: String, in defaults: UserDefaults) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[room] = item.uuidString
        defaults.set(all, forKey: key)
    }

    static func item(for room: String, in defaults: UserDefaults) -> UUID? {
        (defaults.dictionary(forKey: key) as? [String: String])?[room].flatMap(UUID.init(uuidString:))
    }
}

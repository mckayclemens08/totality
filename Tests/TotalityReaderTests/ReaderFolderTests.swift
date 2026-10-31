import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

@Suite struct ReaderFolderTests {
    private func entry(_ title: String, kind: ReaderItem.Kind = .folder, in parent: UUID? = nil, id: UUID = UUID(), age: TimeInterval = 0) -> ReaderItem {
        let date = Date(timeIntervalSince1970: 1_793_000_000 - age)
        return ReaderItem(id: id, kind: kind, title: title, collection: nil, mime: nil, byteCount: 0,
                          createdAt: date, updatedAt: date, listenPosition: 0, folderID: parent)
    }

    private func writeOldItem(_ item: ReaderItem, key: ContentRootKey, store: MemoryBlobStore) throws {
        let name = item.id.uuidString.lowercased()
        let meta = try ContentCipher.seal(JSONEncoder().encode(item), key: key.objectKey(for: item.id, purpose: .metadata), objectID: item.id)
        try store.write(meta, as: "\(name).meta")
        try store.write(try ContentCipher.seal(Data(), key: key.objectKey(for: item.id, purpose: .content), objectID: item.id), as: "\(name).body")
    }

    @Test("Folders nest, and the path runs from the top down")
    func nesting() async throws {
        let vault = try newVault()
        let climbing = try await vault.createFolder(title: "Climbing")
        let trips = try await vault.createFolder(title: "Trips", in: climbing.id)
        let note = try await vault.createNote(title: "Red Rock beta", folder: trips.id)
        let listing = try await vault.list()
        let library = ReaderLibrary(items: listing.items, folders: listing.folders)
        #expect(library.contents(of: nil).folders.map(\.title) == ["Climbing"])
        #expect(library.contents(of: nil).items.isEmpty)
        #expect(library.contents(of: climbing.id).folders.map(\.title) == ["Trips"])
        #expect(library.contents(of: trips.id).items.map(\.id) == [note.id])
        #expect(library.path(to: trips.id).map(\.title) == ["Climbing", "Trips"])
        #expect(library.descendants(of: climbing.id).count == 2)
    }

    @Test("Folders aren't files to the rest of the app, and the server sees them as notes")
    func foldersStayOutOfItems() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let folder = try await vault.createFolder(title: "Tax papers")
        #expect(try await vault.list().items.isEmpty)
        let sealed = try #require(try await vault.sealedObject(folder.id))
        #expect(sealed.kind == .note)
        #expect(sealed.body != nil)
        for name in try store.names() {
            let blob = try #require(try store.read(name))
            #expect(blob.range(of: Data("Tax papers".utf8)) == nil)
        }
    }

    @Test("A folder deleted on another device can't take its contents with it")
    func missingParentsShowAtTheTop() {
        let note = entry("Kept", kind: .note, in: UUID())
        let library = ReaderLibrary(items: [note])
        #expect(library.contents(of: nil).items == [note])
        #expect(library.parent(of: note) == nil)
    }

    @Test("Two folders moved inside each other on different devices both stay reachable")
    func loopsShowAtTheTop() {
        let (first, second) = (UUID(), UUID())
        let one = entry("One", in: second, id: first)
        let two = entry("Two", in: first, id: second)
        let inner = entry("Inner", in: first)
        let note = entry("Note", kind: .note, in: first)
        let library = ReaderLibrary(items: [note], folders: [one, two, inner])
        #expect(Set(library.contents(of: nil).folders.map(\.title)) == ["One", "Two"])
        #expect(library.contents(of: first).folders == [inner])
        #expect(library.contents(of: first).items == [note])
        #expect(library.path(to: inner.id).map(\.title) == ["One", "Inner"])
    }

    @Test("Folders inside a loop stay where they are, and only the loop itself moves to the top")
    func leadInsAreNotLoops() {
        let (first, second) = (UUID(), UUID())
        let loop = [entry("One", in: second, id: first), entry("Two", in: first, id: second)]
        let inside = (0..<200).map { entry("Inside \($0)", in: first) }
        let library = ReaderLibrary(folders: loop + inside)
        #expect(library.contents(of: first).folders.count == 200)
        #expect(library.contents(of: nil).folders.count == 2)
    }

    @Test("A very deep tree stays quick and can't overflow anything")
    func deepTree() {
        var parent: UUID?
        var folders: [ReaderItem] = []
        for index in 0..<20_000 {
            let folder = entry("\(index)", in: parent)
            folders.append(folder)
            parent = folder.id
        }
        let start = Date()
        let library = ReaderLibrary(folders: folders)
        #expect(library.descendants(of: folders[0].id).count == 19_999)
        #expect(library.path(to: parent).count == 20_000)
        #expect(!library.canMove(folders[0], to: parent))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("Moving changes where something lives, and doesn't count as an edit")
    func movingKeepsTheTime() async throws {
        let vault = try newVault()
        let folder = try await vault.createFolder(title: "Climbing")
        let note = try await vault.createNote(title: "Beta")
        try await vault.move(note.id, to: folder.id)
        let moved = try await vault.item(note.id)
        #expect(moved.folderID == folder.id)
        #expect(moved.updatedAt == note.updatedAt)
        try await vault.move(note.id, to: nil)
        #expect(try await vault.item(note.id).folderID == nil)
    }

    @Test("A folder can't go inside itself or anything inside it")
    func noLoopsByMoving() async throws {
        let vault = try newVault()
        let top = try await vault.createFolder(title: "Top")
        let inner = try await vault.createFolder(title: "Inner", in: top.id)
        await #expect(throws: ReaderError.folderInsideItself) { try await vault.move(top.id, to: top.id) }
        await #expect(throws: ReaderError.folderInsideItself) { try await vault.move(top.id, to: inner.id) }
        #expect(try await vault.item(top.id).folderID == nil)
    }

    @Test("Renaming is an edit")
    func renaming() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Old")
        try await Task.sleep(for: .milliseconds(5))
        try await vault.rename(note.id, to: "New")
        let renamed = try await vault.item(note.id)
        #expect(renamed.title == "New")
        #expect(renamed.updatedAt > note.updatedAt)
    }

    @Test("Sorting keeps names in the order a person expects")
    func sorting() {
        let old = entry("Item 10", kind: .note, age: 100)
        let new = entry("Item 9", kind: .note)
        var pdf = entry("A book", kind: .file, age: 50)
        pdf.mime = "application/pdf"
        let library = ReaderLibrary(items: [old, new, pdf])
        #expect(library.contents(of: nil, sortedBy: .recent).items == [new, pdf, old])
        #expect(library.contents(of: nil, sortedBy: .name).items == [pdf, new, old])
        #expect(library.contents(of: nil, sortedBy: .type).items == [new, old, pdf])
    }

    @Test("A named folder's ID depends on the key, so the server can't recognise the name")
    func keyedFolderIDs() async throws {
        let mine = try await newVault().namedFolder("Reading list")
        let theirs = try await newVault().namedFolder("Reading list")
        #expect(mine.id != theirs.id)
    }

    @Test("Old collections become folders, and two devices land on the same one")
    func collectionsBecomeFolders() async throws {
        let key = try ContentRootKey.generate()
        let (firstStore, secondStore) = (MemoryBlobStore(), MemoryBlobStore())
        let (one, two) = (UUID(), UUID())
        var note = entry("Dune", kind: .note, id: one)
        note.collection = "Reading list"
        var other = entry("Foundation", kind: .note, id: two)
        other.collection = "Reading list"
        try writeOldItem(note, key: key, store: firstStore)
        try writeOldItem(other, key: key, store: secondStore)
        let (first, second) = (ReaderVault(store: firstStore, rootKey: key), ReaderVault(store: secondStore, rootKey: key))
        try await first.adoptCollections()
        try await second.adoptCollections()
        let folders = try await first.list().folders
        #expect(folders.map(\.title) == ["Reading list"])
        #expect(try await second.list().folders.map(\.id) == folders.map(\.id))
        let adopted = try await first.item(one)
        #expect(adopted.folderID == folders[0].id)
        #expect(adopted.collection == nil)
        #expect(adopted.updatedAt == note.updatedAt)
        try await first.adoptCollections()
        #expect(try await first.list().folders.count == 1)
    }

    @Test("An older app's metadata, with no folder field, still opens")
    func oldMetadataOpens() throws {
        let json = #"{"id":"3B241101-E2BB-4255-8CAF-4136C566A962","kind":"note","title":"Old","byteCount":0,"createdAt":0,"updatedAt":0,"listenPosition":0}"#
        let item = try JSONDecoder().decode(ReaderItem.self, from: Data(json.utf8))
        #expect(item.folderID == nil)
    }
}

@Suite struct RecentlyDeletedTests {
    @MainActor
    @Test("Days left start at the full 30, reach 1, and never go negative")
    func daysLeft() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func left(deletedDaysAgo days: Double) -> String {
            let item = ReaderItem(id: UUID(), kind: .note, title: "Trip", collection: nil, mime: nil, byteCount: 0,
                                  createdAt: now, updatedAt: now, listenPosition: 0)
            return ReaderTrashView.left(TrashedItem(item: item, deletedAt: now.addingTimeInterval(-days * 86_400)), now: now)
        }
        #expect(left(deletedDaysAgo: 0.001) == "30 days left")
        #expect(left(deletedDaysAgo: 29.5) == "1 day left")
        #expect(left(deletedDaysAgo: 31) == "0 days left")
    }

    @Test("Deleting keeps a sealed copy and tells sync")
    func deletingKeepsACopy() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let note = try await vault.createNote(title: "Secret plan")
        try await vault.saveNote(note.id, title: "Secret plan", body: "Secret words")
        try await vault.delete(note.id)
        #expect(try await vault.list().items.isEmpty)
        #expect(try await vault.deletedObjectIDs() == [note.id])
        #expect(try await vault.trashed().map(\.item.title) == ["Secret plan"])
        for name in try store.names() {
            let blob = try #require(try store.read(name))
            #expect(blob.range(of: Data("Secret".utf8)) == nil, "\(name)")
        }
    }

    @Test("Restore brings back the exact item, with its words")
    func restoring() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Plan")
        try await vault.saveNote(note.id, title: "Plan", body: "Words")
        let hash = try await vault.sealedHash(of: note.id)
        try await vault.delete(note.id)
        #expect(try await vault.sealedHash(of: note.id) == nil)
        try await vault.restore(note.id)
        #expect(try await vault.sealedHash(of: note.id) == hash)
        #expect(String(decoding: try await vault.body(of: note.id), as: UTF8.self) == "Words")
        #expect(try await vault.deletedObjectIDs().isEmpty)
        #expect(try await vault.trashed().isEmpty)
    }

    @Test("A deleted folder shows once, and Restore brings back what was inside")
    func foldersComeBackWhole() async throws {
        let vault = try newVault()
        let top = try await vault.createFolder(title: "Top")
        let inner = try await vault.createFolder(title: "Inner", in: top.id)
        let note = try await vault.createNote(title: "Deep", folder: inner.id)
        let gone = try await vault.delete(top.id)
        #expect(Set(gone) == [top.id, inner.id, note.id])
        #expect(try await vault.trashed().map(\.item.title) == ["Top"])
        #expect(try await vault.list().folders.isEmpty)
        try await vault.restore(top.id)
        let listing = try await vault.list()
        let library = ReaderLibrary(items: listing.items, folders: listing.folders)
        #expect(library.contents(of: inner.id).items.map(\.title) == ["Deep"])
        #expect(try await vault.trashed().isEmpty)
    }

    @Test("Something restored into a folder that's gone shows at the top")
    func restoringWithoutTheFolder() async throws {
        let vault = try newVault()
        let folder = try await vault.createFolder(title: "Gone")
        let note = try await vault.createNote(title: "Kept", folder: folder.id)
        try await vault.delete(note.id)
        try await vault.delete(folder.id)
        try await vault.restore(note.id)
        let listing = try await vault.list()
        #expect(ReaderLibrary(items: listing.items, folders: listing.folders).contents(of: nil).items.map(\.title) == ["Kept"])
    }

    @Test("If it came back another way, Restore keeps both")
    func restoringBesideALiveCopy() async throws {
        let key = try ContentRootKey.generate()
        let here = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        let there = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        let note = try await here.createNote(title: "Plan")
        try await here.saveNote(note.id, title: "Plan", body: "older")
        try await there.store(try #require(try await here.sealedObject(note.id)), ifLocalHash: nil)
        try await there.saveNote(note.id, title: "Plan", body: "newer")
        try await here.delete(note.id)
        // Sync finds it was edited elsewhere after the delete, drops the record, and pulls it.
        try await here.clearDeletion(note.id)
        try await here.store(try #require(try await there.sealedObject(note.id)), ifLocalHash: nil)
        try await here.restore(note.id)
        #expect(try await here.trashed().isEmpty)
        #expect(String(decoding: try await here.body(of: note.id), as: UTF8.self) == "newer")
        let copy = try #require(try await here.list().items.first { $0.id != note.id })
        #expect(copy.title == "Plan (conflict copy)")
        #expect(String(decoding: try await here.body(of: copy.id), as: UTF8.self) == "older")
    }

    @Test("Delete forever really removes it, and leaves the record sync needs")
    func deletingForever() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let note = try await vault.createNote(title: "Gone")
        try await vault.delete(note.id)
        try await vault.deleteForever(note.id)
        #expect(try await vault.trashed().isEmpty)
        let names = try store.names()
        #expect(names == ["\(note.id.uuidString.lowercased()).deleted"])
    }

    @Test("A looped folder in the trash still shows, with its contents, rather than vanishing")
    func loopedTrash() async throws {
        let key = try ContentRootKey.generate()
        let vault = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        let there = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        let first = try await vault.createFolder(title: "First")
        let second = try await vault.createFolder(title: "Second", in: first.id)
        let note = try await vault.createNote(title: "Inside", folder: second.id)
        // Two devices can each move one folder inside the other, so the loop arrives by sync.
        for id in [first.id, second.id] {
            try await there.store(try #require(try await vault.sealedObject(id)), ifLocalHash: nil)
        }
        try await there.move(second.id, to: nil)
        try await there.move(first.id, to: second.id)
        let moved = try #require(try await there.sealedObject(first.id))
        try await vault.store(moved, ifLocalHash: try await vault.sealedHash(of: first.id))
        try await vault.delete(first.id)
        try await vault.delete(second.id)
        #expect(Set(try await vault.trashed().map(\.item.title)) == ["First", "Second"])
        try await vault.restore(first.id)
        #expect(try await vault.item(note.id).title == "Inside")
    }

    @Test("Deleting a folder for good takes what's inside it")
    func foreverTakesContents() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let folder = try await vault.createFolder(title: "Top")
        let inner = try await vault.createFolder(title: "Inner", in: folder.id)
        _ = try await vault.createNote(title: "Inside", folder: inner.id)
        try await vault.delete(folder.id)
        try await vault.deleteForever(folder.id)
        #expect(try await vault.trashed().isEmpty)
        #expect(try store.names().allSatisfy { $0.hasSuffix(".deleted") })
    }

    @Test("Emptying takes everything, and what's inside folders")
    func emptying() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let folder = try await vault.createFolder(title: "Top")
        _ = try await vault.createNote(title: "Inside", folder: folder.id)
        let loose = try await vault.createNote(title: "Loose")
        try await vault.delete(folder.id)
        try await vault.delete(loose.id)
        try await vault.emptyTrash()
        #expect(try store.names().allSatisfy { $0.hasSuffix(".deleted") })
    }

    @Test("A crash partway through a delete still lands in Recently Deleted")
    func interruptedDeletesAreKept() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let note = try await vault.createNote(title: "Half gone")
        try store.write(Data(), as: "\(note.id.uuidString.lowercased()).deleted")
        #expect(try await vault.sealedObjectIDs().isEmpty)
        #expect(try await vault.trashed().map(\.item.title) == ["Half gone"])
    }

    @Test("Trash from another device's delete shows here too")
    func syncRemovalsShow() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Removed elsewhere")
        try await vault.removeObject(note.id, ifLocalHash: try #require(try await vault.sealedHash(of: note.id)))
        #expect(try await vault.trashed().map(\.item.title) == ["Removed elsewhere"])
    }

    @Test("A closed vault changes nothing")
    func closedVaults() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Plan")
        try await vault.delete(note.id)
        await vault.close()
        await #expect(throws: ReaderError.closed) { try await vault.restore(note.id) }
        await #expect(throws: ReaderError.closed) { try await vault.deleteForever(note.id) }
        await #expect(throws: ReaderError.closed) { try await vault.emptyTrash() }
        #expect(try await vault.trashed().count == 1)
    }

    @Test("A note deleted while open keeps what was typed in the same folder")
    func keptCopiesStayPut() async throws {
        let vault = try newVault()
        let folder = try await vault.createFolder(title: "Plans")
        let note = try await vault.createNote(title: "Plan", folder: folder.id)
        try await vault.saveNote(note.id, title: "Plan", body: "edited")
        let opened = try await vault.item(note.id)
        try await Task.sleep(for: .milliseconds(5))
        try await vault.saveNote(note.id, title: "Plan", body: "newer")
        guard case .keptAsCopy(let copy) = try await vault.saveNote(note.id, title: "Plan", body: "stale", basedOn: opened.updatedAt) else {
            Issue.record("Expected a copy")
            return
        }
        #expect(copy.folderID == folder.id)
    }

    @Test("Two renames of a folder don't make a copy, and neither does a move")
    func foldersAndMovesMakeNoCopies() async throws {
        let key = try ContentRootKey.generate()
        let first = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        let second = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        let folder = try await first.createFolder(title: "Plans")
        let note = try await first.createNote(title: "Plan")
        for id in [folder.id, note.id] {
            try await second.store(try #require(try await first.sealedObject(id)), ifLocalHash: nil)
        }
        try await first.rename(folder.id, to: "Older")
        try await Task.sleep(for: .milliseconds(5))
        try await second.rename(folder.id, to: "Newer")
        try await second.move(note.id, to: folder.id)
        for id in [folder.id, note.id] {
            _ = try await first.resolveConflict(
                local: try #require(try await first.sealedObject(id)), remote: try #require(try await second.sealedObject(id))
            )
        }
        let listing = try await first.list()
        #expect(listing.items.count == 1)
        #expect(listing.folders.count == 1)
    }
}

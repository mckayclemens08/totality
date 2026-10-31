import CoreGraphics
import CoreText
import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

/// A one-page PDF holding `text`, optionally locked with a password.
func makePDF(_ text: String, password: String? = nil) throws -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    var info: [CFString: Any] = [:]
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password
    }
    let consumer = try #require(CGDataConsumer(data: data))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary))
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
    )
    context.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

@Suite struct ReaderVaultTests {
    @Test func noteRoundTrips() async throws {
        let vault = try newVault()
        let note = try await vault.createNote()
        try await vault.saveNote(note.id, title: "Climbing plan", body: "Hangboard on Tuesday.")
        let listing = try await vault.list()
        #expect(listing.items.map(\.title) == ["Climbing plan"])
        #expect(try await vault.text(of: note.id) == "Hangboard on Tuesday.")
    }

    @Test("Nothing reaches storage in plaintext, including titles and filenames")
    func nothingInPlaintext() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let folder = try await vault.createFolder(title: "Secret folder")
        let note = try await vault.createNote(folder: folder.id)
        try await vault.saveNote(note.id, title: "Secret title", body: "Secret body")
        _ = try await vault.importFile(Data("Secret file".utf8), filename: "secret-name.txt")
        for name in try store.names() {
            #expect(!name.lowercased().contains("secret"))
            let blob = try #require(try store.read(name))
            for needle in ["Secret", "secret-name", "text/plain", "listenPosition"] {
                #expect(blob.range(of: Data(needle.utf8)) == nil, "\(needle) in \(name)")
            }
        }
    }

    @Test func listenPositionSurvivesSavingAndLeavesEditDateAlone() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "A")
        let saved = try await vault.saveNote(note.id, title: "A", body: "One. Two.")
        try await vault.setListenPosition(5, of: note.id)
        #expect(try await vault.item(note.id).updatedAt == saved.updatedAt)
        let edited = try await vault.saveNote(note.id, title: "B", body: "One. Two. Three.")
        #expect(edited.listenPosition == 5)
    }

    @Test func filesCannotBeEditedAsNotes() async throws {
        let vault = try newVault()
        let file = try await vault.importFile(Data("x".utf8), filename: "a.txt")
        await #expect(throws: ReaderError.notANote) {
            try await vault.saveNote(file.id, title: "b", body: "c")
        }
    }

    @Test func oversizedImportIsRefused() async throws {
        let vault = try newVault()
        await #expect(throws: ReaderError.tooLarge) {
            try await vault.importFile(Data(count: ReaderVault.maxImportBytes + 1), filename: "a.pdf")
        }
    }

    @Test func deleteRemovesBothBlobs() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let note = try await vault.createNote(title: "Gone")
        try await vault.delete(note.id)
        #expect(try !store.names().contains { $0.hasSuffix(".meta") || $0.hasSuffix(".body") })
        await #expect(throws: ReaderError.notFound) { try await vault.body(of: note.id) }
    }

    @Test func tamperedBodyDoesNotOpen() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let note = try await vault.createNote(title: "A")
        try await vault.saveNote(note.id, title: "A", body: "Hello")
        let name = "\(note.id.uuidString.lowercased()).body"
        var blob = try #require(try store.read(name))
        blob[blob.count - 1] ^= 1
        try store.write(blob, as: name)
        await #expect(throws: CryptoError.authenticationFailed) { try await vault.body(of: note.id) }
    }

    @Test("Blobs swapped between items are reported, not shown under the wrong title")
    func swappedBlobsAreUnreadable() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let first = try await vault.createNote(title: "First")
        let second = try await vault.createNote(title: "Second")
        let firstName = "\(first.id.uuidString.lowercased()).meta"
        let secondName = "\(second.id.uuidString.lowercased()).meta"
        let firstBlob = try #require(try store.read(firstName))
        try store.write(try #require(try store.read(secondName)), as: firstName)
        try store.write(firstBlob, as: secondName)
        let listing = try await vault.list()
        #expect(listing.items.isEmpty)
        #expect(listing.unreadable == 2)
    }

    @Test func strayFilesAreIgnored() async throws {
        let store = MemoryBlobStore()
        try store.write(Data("junk".utf8), as: "not-a-uuid.meta")
        let listing = try await newVault(store: store).list()
        #expect(listing.items.isEmpty && listing.unreadable == 0)
    }

    @Test func fileStoreRefusesNamesThatLeaveItsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileBlobStore(directory: directory)
        for name in ["../escape", "a/b", "", "..", ".hidden", "/etc/hosts", "a\\b"] {
            #expect(throws: BlobStoreError.invalidName(name)) { try store.write(Data(), as: name) }
        }
        try store.write(Data("x".utf8), as: "ok.meta")
        #expect(try store.read("ok.meta") == Data("x".utf8))
        #expect(try store.names() == ["ok.meta"])
    }

    @Test func pdfTextIsReadable() async throws {
        let vault = try newVault()
        let pdf = try await vault.importFile(try makePDF("Grading the V5 boulder problem"), filename: "Guide.pdf")
        #expect(pdf.title == "Guide")
        #expect(pdf.mime == "application/pdf")
        #expect(try await vault.text(of: pdf.id).contains("V5 boulder"))
    }

    @Test func lockedPDFSaysSo() async throws {
        let vault = try newVault()
        let pdf = try await vault.importFile(try makePDF("Hidden", password: "not-a-real-secret"), filename: "Locked.pdf")
        await #expect(throws: ReaderError.passwordProtected) { try await vault.text(of: pdf.id) }
    }

    @Test func unknownFormatsAreKeptButNotRead() async throws {
        let vault = try newVault()
        let file = try await vault.importFile(Data([0, 1, 2]), filename: "archive.zip")
        await #expect(throws: ReaderError.notReadable) { try await vault.text(of: file.id) }
        #expect(try await vault.body(of: file.id) == Data([0, 1, 2]))
    }
}

@Suite struct ReaderSyncTests {
    private func pair() throws -> (first: ReaderVault, second: ReaderVault, key: ContentRootKey) {
        let key = try ContentRootKey.generate()
        func vault() throws -> ReaderVault {
            ReaderVault(store: try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), rootKey: key)
        }
        return (try vault(), try vault(), key)
    }

    @Test("A sealed item moves between devices and opens on the other side")
    func movesBetweenVaults() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Lease")
        try await first.saveNote(note.id, title: "Lease", body: "Twelve months")
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        #expect(try await second.item(note.id).title == "Lease")
        #expect(String(decoding: try await second.body(of: note.id), as: UTF8.self) == "Twelve months")
    }

    @Test("Content sealed under another key is refused, and what's here stays")
    func refusesOtherKeys() async throws {
        let (first, _, _) = try pair()
        let stranger = ReaderVault(store: try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), rootKey: try ContentRootKey.generate())
        let note = try await stranger.createNote(title: "Forged")
        await #expect(throws: (any Error).self) { try await first.store(try #require(try await stranger.sealedObject(note.id)), ifLocalHash: nil) }
        #expect(try await first.list().items.isEmpty)
    }

    @Test("A body swapped in from another item is refused")
    func refusesSwappedBodies() async throws {
        let (first, second, _) = try pair()
        let one = try await first.createNote(title: "One")
        let two = try await first.createNote(title: "Two")
        let meta = try #require(try await first.sealedObject(one.id))
        let body = try #require(try await first.sealedObject(two.id))
        await #expect(throws: (any Error).self) {
            try await second.store(SealedObject(id: one.id, kind: .note, meta: meta.meta, body: body.body), ifLocalHash: nil)
        }
    }

    @Test("Forged details on a real body are refused")
    func refusesForgedDetails() async throws {
        let (first, second, _) = try pair()
        let stranger = ReaderVault(store: try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), rootKey: try ContentRootKey.generate())
        let note = try await first.createNote(title: "Real")
        let forged = try await stranger.createNote(title: "Forged")
        let real = try #require(try await first.sealedObject(note.id))
        let fake = try #require(try await stranger.sealedObject(forged.id))
        await #expect(throws: (any Error).self) {
            try await second.store(SealedObject(id: note.id, kind: .note, meta: fake.meta, body: real.body), ifLocalHash: nil)
        }
    }

    @Test("An open editor's save can't overwrite a newer version, and what was typed is kept")
    func staleEditorSaveKeepsBoth() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await first.saveNote(note.id, title: "Plan", body: "base")
        let opened = try await first.item(note.id).updatedAt
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        try await Task.sleep(for: .milliseconds(5))
        try await second.saveNote(note.id, title: "Plan", body: "from the mac")
        let newer = try #require(try await second.sealedObject(note.id))
        try await first.store(newer, ifLocalHash: try await first.sealedHash(of: note.id))

        let result = try await first.saveNote(note.id, title: "Plan", body: "typed on the phone", basedOn: opened)
        guard case .keptAsCopy(let copy) = result else {
            Issue.record("Expected a copy")
            return
        }
        #expect(String(decoding: try await first.body(of: note.id), as: UTF8.self) == "from the mac")
        #expect(String(decoding: try await first.body(of: copy.id), as: UTF8.self) == "typed on the phone")
    }

    @Test("Saving from the version on disk just saves")
    func currentEditorSaveSaves() async throws {
        let (first, _, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        let result = try await first.saveNote(note.id, title: "Plan", body: "text", basedOn: note.updatedAt)
        guard case .saved = result else {
            Issue.record("Expected a save")
            return
        }
        #expect(try await first.list().items.count == 1)
    }

    @Test("A note deleted elsewhere while open keeps what was typed")
    func editorSaveAfterDeleteKeepsText() async throws {
        let (first, _, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await first.delete(note.id)
        let result = try await first.saveNote(note.id, title: "Plan", body: "still typing", basedOn: note.updatedAt)
        guard case .keptAsCopy(let copy) = result else {
            Issue.record("Expected a copy")
            return
        }
        #expect(String(decoding: try await first.body(of: copy.id), as: UTF8.self) == "still typing")
    }

    @Test("A store only lands if nothing changed since sync looked")
    func storeChecksTheVersion() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        let looked = try await second.sealedHash(of: note.id)
        try await second.saveNote(note.id, title: "Typed", body: "just now")
        await #expect(throws: SyncError.changedLocally) {
            try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: looked)
        }
        #expect(try await second.item(note.id).title == "Typed")
    }

    @Test("Something removed by sync can still be found in the trash")
    func removalsAreKept() async throws {
        let store = MemoryBlobStore()
        let vault = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        let note = try await vault.createNote(title: "Keep me")
        try await vault.removeObject(note.id, ifLocalHash: try #require(try await vault.sealedHash(of: note.id)))
        #expect(try await vault.list().items.isEmpty)
        let name = note.id.uuidString.lowercased()
        #expect(try store.read("\(name).meta.trash") != nil)
        #expect(try store.read("\(name).body.trash") != nil)
        try await vault.emptyOldTrash()
        #expect(try store.read("\(name).meta.trash") != nil)
    }

    @Test("Old trash goes after its time is up")
    func oldTrashGoes() async throws {
        let store = MemoryBlobStore()
        let vault = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        let note = try await vault.createNote(title: "Old")
        try await vault.removeObject(note.id, ifLocalHash: try #require(try await vault.sealedHash(of: note.id)))
        let name = note.id.uuidString.lowercased()
        let old = Date().addingTimeInterval(-ReaderVault.trashLifetime - 60)
        try store.write(Data(ISO8601DateFormatter().string(from: old).utf8), as: "\(name).trashed")
        try await vault.emptyOldTrash()
        #expect(try store.read("\(name).meta.trash") == nil)
        #expect(try store.read("\(name).trashed") == nil)
    }

    @Test("A note missing its body counts as missing here, so it's pulled, not pushed")
    func missingBodyIsNotAnEdit() async throws {
        let store = MemoryBlobStore()
        let vault = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        let note = try await vault.createNote(title: "Plan")
        let directory = store
        try directory.delete("\(note.id.uuidString.lowercased()).body")
        let fresh = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        #expect(try await fresh.sealedHash(of: note.id) == nil)
    }

    @Test("Damage is caught before anything leaves")
    func damagedItemsDoNotVerify() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let vault = ReaderVault(store: store, rootKey: key)
        let note = try await vault.createNote(title: "Plan")
        try store.write(Data(repeating: 7, count: 80), as: "\(note.id.uuidString.lowercased()).body")
        let reopened = ReaderVault(store: store, rootKey: key)
        await #expect(throws: (any Error).self) { _ = try await reopened.verifiedObject(note.id) }
    }

    @Test("A different title counts as different, so the older one is kept")
    func differentTitlesMakeACopy() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        try await first.saveNote(note.id, title: "Older title", body: "")
        try await Task.sleep(for: .milliseconds(5))
        try await second.saveNote(note.id, title: "Newer title", body: "")
        let local = try #require(try await first.sealedObject(note.id))
        let remote = try #require(try await second.sealedObject(note.id))
        _ = try await first.resolveConflict(local: local, remote: remote)
        #expect(try await first.list().items.contains { $0.title == "Older title (conflict copy)" })
    }

    @Test("A crash partway through a delete is finished, not undone")
    func interruptedDeletesFinish() async throws {
        let store = MemoryBlobStore()
        let vault = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        let note = try await vault.createNote(title: "Delete me")
        try store.write(Data(), as: "\(note.id.uuidString.lowercased()).deleted")
        #expect(try await vault.sealedObjectIDs().isEmpty)
        #expect(try await vault.list().items.isEmpty)
        #expect(try await vault.deletedObjectIDs() == [note.id])
    }

    @Test("A closed vault changes nothing, even to finish a delete")
    func closedVaultsStayPut() async throws {
        let store = MemoryBlobStore()
        let vault = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        let note = try await vault.createNote(title: "Keep me")
        try store.write(Data(), as: "\(note.id.uuidString.lowercased()).deleted")
        await vault.close()
        #expect(try await vault.sealedObjectIDs() == [note.id])
    }

    @Test("A conflict that keeps retrying as this device changes still makes one copy")
    func conflictCopiesSurviveLocalChanges() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        try await second.saveNote(note.id, title: "Plan", body: "from the mac")
        let remote = try #require(try await second.sealedObject(note.id))
        try await Task.sleep(for: .milliseconds(5))
        try await first.saveNote(note.id, title: "Plan", body: "one")
        _ = try await first.resolveConflict(local: try #require(try await first.sealedObject(note.id)), remote: remote)
        try await Task.sleep(for: .milliseconds(5))
        try await first.saveNote(note.id, title: "Plan", body: "two")
        _ = try await first.resolveConflict(local: try #require(try await first.sealedObject(note.id)), remote: remote)
        #expect(try await first.list().items.count == 2)
    }

    @Test("A retry leaves a conflict copy alone once someone has edited it")
    func conflictRetriesKeepEdits() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        try await first.saveNote(note.id, title: "Plan", body: "older")
        try await Task.sleep(for: .milliseconds(5))
        try await second.saveNote(note.id, title: "Plan", body: "newer")
        let local = try #require(try await first.sealedObject(note.id))
        let remote = try #require(try await second.sealedObject(note.id))
        _ = try await first.resolveConflict(local: local, remote: remote)
        let copy = try #require(try await first.list().items.first { $0.id != note.id })
        try await first.saveNote(copy.id, title: copy.title, body: "edited the copy")
        _ = try await first.resolveConflict(local: local, remote: remote)
        #expect(String(decoding: try await first.body(of: copy.id), as: UTF8.self) == "edited the copy")
    }

    @Test("A retried conflict doesn't make a second copy")
    func conflictCopiesDoNotDouble() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        try await first.saveNote(note.id, title: "Plan", body: "one")
        try await Task.sleep(for: .milliseconds(5))
        try await second.saveNote(note.id, title: "Plan", body: "two")
        let local = try #require(try await first.sealedObject(note.id))
        let remote = try #require(try await second.sealedObject(note.id))
        for _ in 0..<3 { _ = try await first.resolveConflict(local: local, remote: remote) }
        #expect(try await first.list().items.count == 2)
    }

    @Test("Both changed: the newest stays, and the older text is kept as a copy")
    func conflictKeepsBoth() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        try await first.saveNote(note.id, title: "Plan", body: "older")
        try await Task.sleep(for: .milliseconds(5))
        try await second.saveNote(note.id, title: "Plan", body: "newer")
        let local = try #require(try await first.sealedObject(note.id))
        let remote = try #require(try await second.sealedObject(note.id))
        #expect(try await first.resolveConflict(local: local, remote: remote) == .keepRemote)
        let copy = try #require(try await first.list().items.first { $0.title == "Plan (conflict copy)" })
        #expect(String(decoding: try await first.body(of: copy.id), as: UTF8.self) == "older")
    }

    @Test("Only the details differ, like a Listen position: no copy is made")
    func noCopyForSameText() async throws {
        let (first, second, _) = try pair()
        let note = try await first.createNote(title: "Plan")
        try await second.store(try #require(try await first.sealedObject(note.id)), ifLocalHash: nil)
        try await first.setListenPosition(4, of: note.id)
        try await second.setListenPosition(9, of: note.id)
        let local = try #require(try await first.sealedObject(note.id))
        let remote = try #require(try await second.sealedObject(note.id))
        _ = try await first.resolveConflict(local: local, remote: remote)
        #expect(try await first.list().items.count == 1)
    }

    @Test("Deleting leaves a record for sync, and a stored copy changes the hash")
    func deletionsAreRecorded() async throws {
        let (first, _, _) = try pair()
        let note = try await first.createNote(title: "Gone")
        let before = try await first.sealedHash(of: note.id)
        try await first.saveNote(note.id, title: "Changed", body: "new")
        #expect(try await first.sealedHash(of: note.id) != before)
        try await first.delete(note.id)
        #expect(try await first.deletedObjectIDs() == [note.id])
        #expect(try await first.sealedObjectIDs().isEmpty)
        try await first.clearDeletion(note.id)
        #expect(try await first.deletedObjectIDs().isEmpty)
    }
}

@Suite struct ReaderVaultClosingTests {
    @Test("A closed vault refuses writes, so a running import can't land under an old key")
    func closedVaultRefusesWrites() async throws {
        let vault = ReaderVault(store: try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), rootKey: try ContentRootKey.generate())
        let note = try await vault.createNote(title: "Before")
        try await vault.saveNote(note.id, title: "Before", body: "original text")
        await vault.close()
        await #expect(throws: ReaderError.closed) { try await vault.importFile(Data("late".utf8), filename: "late.txt") }
        await #expect(throws: ReaderError.closed) { try await vault.createNote(title: "Late") }
        await #expect(throws: ReaderError.closed) { try await vault.saveNote(note.id, title: "Changed", body: "changed text") }
        await #expect(throws: ReaderError.closed) { try await vault.setListenPosition(4, of: note.id) }
        await #expect(throws: ReaderError.closed) { try await vault.delete(note.id) }
        #expect(try await vault.item(note.id).title == "Before")
        // The body is written first, so a refusal that only stopped the title would still damage it.
        #expect(String(decoding: try await vault.body(of: note.id), as: UTF8.self) == "original text")
    }
}

@Suite struct ReaderSearchTests {
    @Test func findsTitlesTextAndPDFs() async throws {
        let vault = try newVault()
        let note = try await vault.createNote()
        try await vault.saveNote(note.id, title: "Trip", body: "Bring chalk and rope.")
        _ = try await vault.importFile(try makePDF("Chalk technique"), filename: "Manual.pdf")
        let hits = try await vault.search("CHALK")
        #expect(hits.count == 2)
        #expect(try await vault.search("trip").map(\.item.id) == [note.id])
        #expect(try await vault.search("nothing-here").isEmpty)
    }

    @Test func everyWordMustMatchAndAccentsDoNotMatter() async throws {
        let vault = try newVault()
        let note = try await vault.createNote()
        try await vault.saveNote(note.id, title: "Café list", body: "Open on Sunday")
        #expect(try await vault.search("cafe sunday").count == 1)
        #expect(try await vault.search("cafe monday").isEmpty)
    }

    @Test func snippetShowsTheMatchInContext() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Long")
        let padding = String(repeating: "word ", count: 80)
        try await vault.saveNote(note.id, title: "Long", body: padding + "needle " + padding)
        let snippet = try #require(try await vault.search("needle").first?.snippet)
        #expect(snippet.contains("needle"))
        #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…"))
        #expect(snippet.count < 150)
    }

    @Test func blankQueryFindsNothing() async throws {
        let vault = try newVault()
        _ = try await vault.createNote(title: "A")
        #expect(try await vault.search("   ").isEmpty)
    }

    @Test func editedAndDeletedTextDoesNotLinger() async throws {
        let vault = try newVault()
        let note = try await vault.createNote()
        try await vault.saveNote(note.id, title: "", body: "old words")
        _ = try await vault.text(of: note.id)
        try await vault.saveNote(note.id, title: "", body: "new words")
        #expect(try await vault.search("old").isEmpty)
        try await vault.delete(note.id)
        #expect(try await vault.search("new").isEmpty)
    }
}

/// The Reader's cases for the brief §6 two-user test, at the encryption layer. The database cases
/// are in backend-tests/reader.test.js.
@Suite struct ReaderTwoUserTests {
    private func sharedNote() async throws -> (owner: ReaderVault, store: MemoryBlobStore, note: ReaderItem) {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let folder = try await vault.createFolder(title: "Private folder")
        let note = try await vault.createNote(folder: folder.id)
        try await vault.saveNote(note.id, title: "Reading list", body: "Book one")
        try await vault.setListenPosition(4, of: note.id)
        return (vault, store, note)
    }

    @Test("User 2 cannot read user 1's content from the same storage")
    func user2CannotRead() async throws {
        let (_, store, note) = try await sharedNote()
        let user2 = ReaderVault(store: store, rootKey: try .generate())
        let listing = try await user2.list()
        #expect(listing.items.isEmpty)
        #expect(listing.folders.isEmpty)
        #expect(listing.unreadable == 2)
        await #expect(throws: CryptoError.authenticationFailed) { try await user2.body(of: note.id) }
    }

    @Test("A shared note opens for user 2 and not for user 3")
    func shareOpensForGranteeOnly() async throws {
        let (owner, _, note) = try await sharedNote()
        let user2 = try IdentityKeys.generate()
        let user3 = try IdentityKeys.generate()
        let share = try await owner.share(note.id, with: user2.bundle())
        let opened = try share.open(with: user2)
        #expect(opened.header.title == "Reading list")
        #expect(String(decoding: opened.body, as: UTF8.self) == "Book one")
        #expect(throws: CryptoError.authenticationFailed) { try share.open(with: user3) }
    }

    @Test("A share reveals no folder or Listen position, and its key opens nothing else")
    func shareRevealsOnlyTheItem() async throws {
        let (owner, store, note) = try await sharedNote()
        let other = try await owner.createNote(title: "Other")
        let user2 = try IdentityKeys.generate()
        let share = try await owner.share(note.id, with: user2.bundle())
        let key = try user2.open(share.wrappedKey)

        let header = try ContentCipher.open(share.sealedHeader, key: key, objectID: note.id)
        #expect(String(decoding: header, as: UTF8.self).contains("folderID") == false)
        #expect(String(decoding: header, as: UTF8.self).contains("listenPosition") == false)

        let meta = try #require(try store.read("\(note.id.uuidString.lowercased()).meta"))
        #expect(throws: CryptoError.authenticationFailed) { try ContentCipher.open(meta, key: key, objectID: note.id) }
        let otherBody = try #require(try store.read("\(other.id.uuidString.lowercased()).body"))
        #expect(throws: CryptoError.authenticationFailed) { try ContentCipher.open(otherBody, key: key, objectID: other.id) }
    }

    @Test("A share key opens the snapshot only, so ending a share protects later edits")
    func shareKeyOpensNoLiveRevision() async throws {
        let (owner, store, note) = try await sharedNote()
        let user2 = try IdentityKeys.generate()
        let share = try await owner.share(note.id, with: user2.bundle())
        let key = try user2.open(share.wrappedKey)
        let bodyName = "\(note.id.uuidString.lowercased()).body"

        let current = try #require(try store.read(bodyName))
        #expect(throws: CryptoError.authenticationFailed) { try ContentCipher.open(current, key: key, objectID: note.id) }

        try await owner.saveNote(note.id, title: "Reading list", body: "Written after the share ended")
        let later = try #require(try store.read(bodyName))
        #expect(throws: CryptoError.authenticationFailed) { try ContentCipher.open(later, key: key, objectID: note.id) }
    }

    @Test("A former grantee cannot forge a body the owner would accept")
    func shareKeyCannotForgeTheOwnersBody() async throws {
        let (owner, store, note) = try await sharedNote()
        let user2 = try IdentityKeys.generate()
        let share = try await owner.share(note.id, with: user2.bundle())
        let forged = try ContentCipher.seal(Data("Forged".utf8), key: user2.open(share.wrappedKey), objectID: note.id)
        try store.write(forged, as: "\(note.id.uuidString.lowercased()).body")
        await #expect(throws: CryptoError.authenticationFailed) { try await owner.body(of: note.id) }
    }

    @Test func eachShareHasItsOwnKey() async throws {
        let (owner, _, note) = try await sharedNote()
        let user2 = try IdentityKeys.generate()
        let first = try await owner.share(note.id, with: user2.bundle())
        let second = try await owner.share(note.id, with: user2.bundle())
        #expect(try user2.open(first.wrappedKey) != user2.open(second.wrappedKey))
    }

    @Test func sharingRefusesAForgedBundle() async throws {
        let (owner, _, note) = try await sharedNote()
        let genuine = try IdentityKeys.generate().bundle()
        let attacker = try IdentityKeys.generate().bundle()
        let forged = IdentityBundle(
            signingPublicKey: genuine.signingPublicKey,
            exchangePublicKey: attacker.exchangePublicKey,
            selfSignature: genuine.selfSignature
        )
        await #expect(throws: CryptoError.invalidSignature) { try await owner.share(note.id, with: forged) }
    }
}

@Suite struct ReaderModuleTests {
    @Test func registersForNotesAndFilesOnly() throws {
        let registry = try ModuleRegistry(handlers: [ReaderModule()])
        let ref = { (kind: ContentKind) in
            ContentRef(module: .reader, kind: kind, id: UUID(), keyRef: .plain, preview: .init(title: "x"))
        }
        #expect(registry.handler(for: ref(.note))?.module == .reader)
        #expect(registry.handler(for: ref(.file))?.module == .reader)
        #expect(registry.handler(for: ref(.doc)) == nil)
    }
}

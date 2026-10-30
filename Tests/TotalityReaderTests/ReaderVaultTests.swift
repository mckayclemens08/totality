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
        let note = try await vault.createNote(collection: "Secret collection")
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
        #expect(try store.names().isEmpty)
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
        let note = try await vault.createNote(collection: "Private collection")
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
        #expect(listing.unreadable == 1)
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

    @Test("A share reveals no collection or Listen position, and its key opens nothing else")
    func shareRevealsOnlyTheItem() async throws {
        let (owner, store, note) = try await sharedNote()
        let other = try await owner.createNote(title: "Other")
        let user2 = try IdentityKeys.generate()
        let share = try await owner.share(note.id, with: user2.bundle())
        let key = try user2.open(share.wrappedKey)

        let header = try ContentCipher.open(share.sealedHeader, key: key, objectID: note.id)
        #expect(String(decoding: header, as: UTF8.self).contains("Private collection") == false)
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

import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

private let essay = Data("# Why I read\n\nBecause the library was warm in January.".utf8)
private let lecture = Data("# Lecture 4\n\nPhotosynthesis happens in the chloroplast.".utf8)

/// A linked folder with a Markdown essay, a Google Doc, a PDF and a spreadsheet in it, already listed.
private func openedFolder(_ fake: FakeDrive, cache: MemoryBlobStore = MemoryBlobStore(), rootKey: ContentRootKey? = nil) async throws -> DriveSetup {
    fake.children["1notes"] = [
        driveFile("1essay", "Essay.md", mime: "text/markdown", size: essay.count),
        driveFile("1doc", "Lecture notes", mime: DriveEntry.googleDocMime),
        driveFile("1big", "Scans.pdf", mime: "application/pdf", size: 300_000_000),
        driveFile("1form", "Sign-up form", mime: "application/vnd.google-apps.form"),
    ]
    fake.contents["1essay"] = essay
    fake.exports["1doc"] = lecture
    let setup = try makeDrive(fake, cache: cache, rootKey: rootKey)
    try await setup.drive.link(DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime), account: driveOwner)
    try await setup.drive.refresh("1notes", account: driveOwner)
    return setup
}

@Suite struct DriveFileTests {
    @Test func opensAFileAndKeepsItSealed() async throws {
        let fake = FakeDrive()
        let setup = try await openedFolder(fake)
        let opened = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(opened.data == essay)
        #expect(opened.mime == MarkdownText.mime)
        #expect(opened.version == "7")
        // Kept sealed: nothing of the words or the name in the cache.
        let names = try setup.cache.names()
        #expect(names.count == 1)
        for name in names {
            #expect(!name.contains("1essay") && !name.contains("Essay"))
            let blob = try #require(try setup.cache.read(name))
            #expect(blob.range(of: Data("library was warm".utf8)) == nil)
        }
        // The second time it comes from the device, without asking Google.
        _ = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(fake.downloaded.count == 1)
        #expect(try await setup.drive.cachedBytes() == essay.count)
    }

    @Test func aChangeInDriveMeansDownloadingAgain() async throws {
        let fake = FakeDrive()
        let setup = try await openedFolder(fake)
        _ = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        let newer = Data("# Why I read\n\nRevised.".utf8)
        fake.contents["1essay"] = newer
        fake.children["1notes"]?[0] = driveFile("1essay", "Essay.md", mime: "text/markdown", size: newer.count, version: "8")
        try await setup.drive.refresh("1notes", account: driveOwner)
        let opened = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(opened.data == newer)
        #expect(fake.downloaded.count == 2)
        // The old copy went with it.
        #expect(try setup.cache.names().count == 1)
    }

    @Test func aGoogleDocComesAsMarkdown() async throws {
        let fake = FakeDrive()
        let setup = try await openedFolder(fake)
        let opened = try await setup.drive.file("1doc", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(opened.data == lecture)
        #expect(opened.mime == MarkdownText.mime)
        let asked = try #require(fake.downloaded.first)
        #expect(asked.path == "/drive/v3/files/1doc/export")
        #expect(asked.queryItems?.first { $0.name == "mimeType" }?.value == "text/markdown")
    }

    @Test func refusesWhatItCantOrShouldntOpen() async throws {
        let fake = FakeDrive()
        let setup = try await openedFolder(fake)
        await #expect(throws: DriveProblem.tooLarge) {
            try await setup.drive.file("1big", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        }
        await #expect(throws: ReaderError.notReadable) {
            try await setup.drive.file("1form", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        }
        // A file that isn't in a readable folder's listing is never asked for, whatever its ID.
        fake.contents["1secret"] = Data("tax return".utf8)
        await #expect(throws: DriveProblem.notFound) {
            try await setup.drive.file("1secret", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        }
        await #expect(throws: DriveProblem.notFound) {
            try await setup.drive.file("1secret", in: "1elsewhere", account: driveOwner, limit: DriveCacheLimit.standard)
        }
        #expect(fake.downloaded.isEmpty)
    }

    @Test func theOldestOpenedGoFirstPastTheLimit() async throws {
        let fake = FakeDrive()
        let a = Data(repeating: 1, count: 400), b = Data(repeating: 2, count: 400), c = Data(repeating: 3, count: 400)
        fake.children["1notes"] = [
            driveFile("1a", "a.txt", mime: "text/plain", size: 400),
            driveFile("1b", "b.txt", mime: "text/plain", size: 400),
            driveFile("1c", "c.txt", mime: "text/plain", size: 400),
        ]
        fake.contents = ["1a": a, "1b": b, "1c": c]
        let setup = try makeDrive(fake)
        try await setup.drive.link(DriveEntry(id: "1notes", name: "Notes", mime: DriveEntry.folderMime), account: driveOwner)
        try await setup.drive.refresh("1notes", account: driveOwner)
        _ = try await setup.drive.file("1a", in: "1notes", account: driveOwner, limit: 1_000)
        _ = try await setup.drive.file("1b", in: "1notes", account: driveOwner, limit: 1_000)
        // Opening a again makes b the oldest.
        _ = try await setup.drive.file("1a", in: "1notes", account: driveOwner, limit: 1_000)
        _ = try await setup.drive.file("1c", in: "1notes", account: driveOwner, limit: 1_000)
        #expect(try await setup.drive.cachedBytes() == 800)
        #expect(fake.downloaded.count == 3)
        _ = try await setup.drive.file("1a", in: "1notes", account: driveOwner, limit: 1_000)
        #expect(fake.downloaded.count == 3)
        _ = try await setup.drive.file("1b", in: "1notes", account: driveOwner, limit: 1_000)
        #expect(fake.downloaded.count == 4)
        // A smaller allowance chosen in settings trims at once.
        try await setup.drive.trimCache(to: 400)
        #expect(try await setup.drive.cachedBytes() == 400)
        #expect(try setup.cache.names().count == 1)
    }

    @Test func unlinkingClearsWhatWasOpenedFromIt() async throws {
        let fake = FakeDrive()
        let setup = try await openedFolder(fake)
        _ = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        let link = try #require(try await setup.drive.links().first)
        try await setup.drive.unlink(link)
        #expect(try setup.cache.names().isEmpty)
        #expect(try await setup.drive.cachedBytes() == 0)
    }

    @Test func clearingKeepsTheLinks() async throws {
        let fake = FakeDrive()
        let setup = try await openedFolder(fake)
        _ = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        try await setup.drive.clearCache()
        #expect(try setup.cache.names().isEmpty)
        #expect(try await setup.drive.links().count == 1)
    }

    @Test func aCopyThatWontOpenIsFetchedAgain() async throws {
        let fake = FakeDrive()
        let setup = try await openedFolder(fake)
        _ = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        let name = try #require(try setup.cache.names().first)
        try setup.cache.write(Data("damaged".utf8), as: name)
        let opened = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(opened.data == essay)
        #expect(fake.downloaded.count == 2)
    }

    @MainActor @Test func theReaderOpensItAndListenCanReadIt() async throws {
        let fake = FakeDrive()
        let setup = try await openedFolder(fake)
        let vault = try newVault()
        let model = DriveModel(drive: setup.drive, vault: vault, settings: UserDefaults(suiteName: "drive-\(UUID())")!)
        let entry = DriveEntry(id: "1essay", name: "Essay.md", mime: "text/markdown")
        let opened = try await model.openFile(entry, in: "1notes", account: driveOwner)
        #expect(opened.item.title == "Essay.md")
        // Read like any item, which is what the viewers and Listen do.
        #expect(try await vault.text(of: opened.item.id).contains("library was warm in January"))
        #expect(try await vault.item(opened.item.id).mime == MarkdownText.mime)
        try await vault.setListenPosition(12, of: opened.item.id)
        #expect(try await vault.item(opened.item.id).listenPosition == 12)
        // But it's never one of the Reader's own: not listed, not searched, nothing written.
        #expect(try await vault.list().items.isEmpty)
        #expect(try await vault.search("library").isEmpty)
        await #expect(throws: ReaderError.notFound) { try await vault.markOpened(opened.item.id, at: Date()) }
        await #expect(throws: ReaderError.self) { try await vault.saveNote(opened.item.id, title: "x", body: "y") }
        await #expect(throws: ReaderError.notFound) { try await vault.delete(opened.item.id) }
        #expect(model.cachedBytes == essay.count)
    }

    @Test func theVaultHoldsOnlyAFew() async throws {
        let vault = try newVault()
        var ids: [UUID] = []
        for index in 0..<(ReaderVault.mostHeld + 1) {
            let item = ReaderItem(
                id: UUID(), kind: .file, title: "File \(index)", collection: nil, mime: "text/plain",
                byteCount: 1, createdAt: Date(), updatedAt: Date(), listenPosition: 0
            )
            try await vault.hold(item, body: Data("words \(index)".utf8))
            ids.append(item.id)
        }
        await #expect(throws: ReaderError.notFound) { try await vault.body(of: ids[0]) }
        #expect(try await vault.text(of: ids.last!) == "words \(ReaderVault.mostHeld)")
        await vault.releaseHeld()
        await #expect(throws: ReaderError.notFound) { try await vault.body(of: ids.last!) }
    }

    @Test func aHeldFileCantStandInForOneOfTheReadersOwn() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Mine")
        let impostor = ReaderItem(
            id: note.id, kind: .file, title: "Drive file", collection: nil, mime: "text/plain",
            byteCount: 1, createdAt: Date(), updatedAt: Date(), listenPosition: 0
        )
        await #expect(throws: ReaderError.notFound) { try await vault.hold(impostor, body: Data("x".utf8)) }
        #expect(try await vault.item(note.id).title == "Mine")
    }
}

@Suite struct DriveFileTwoUserTests {
    @Test("User 2 never sees user 1's downloaded Drive files")
    func user2SeesNoCache() async throws {
        let fake = FakeDrive()
        let cache = MemoryBlobStore()
        let user1 = try await openedFolder(fake, cache: cache)
        _ = try await user1.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(try cache.names().count == 1)

        // Same device, same cache folder, user 2's own key.
        let user2 = GoogleDrive(accounts: user1.accounts, store: user1.store, cache: cache, rootKey: try .generate())
        #expect(try await user2.cachedBytes() == 0)
        await #expect(throws: DriveProblem.notFound) {
            try await user2.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        }
        // And what user 1 left behind is cleared away, since nothing there opens with user 2's key.
        try await user2.sweepCache()
        #expect(try cache.names().isEmpty)
    }
}

@Suite struct DriveHeldFileTwoUserTests {
    @MainActor @Test("Files user 1 opened from Drive go when user 1 signs out")
    func heldFilesGoWithTheOwner() async throws {
        let fake = FakeDrive()
        fake.children["1notes"] = [driveFile("1essay", "Essay.md", mime: "text/markdown", size: 9)]
        fake.contents["1essay"] = Data("Private.".utf8)
        let setup = try makeDrive(fake)
        try await setup.drive.link(DriveEntry(id: "1notes", name: "Notes", mime: DriveEntry.folderMime), account: driveOwner)
        try await setup.drive.refresh("1notes", account: driveOwner)
        let vault = try newVault()
        let model = DriveModel(drive: setup.drive, vault: vault, settings: UserDefaults(suiteName: "drive-\(UUID())")!)
        await model.use(owner: "user1")
        let opened = try await model.openFile(DriveEntry(id: "1essay", name: "Essay.md", mime: "text/markdown"), in: "1notes", account: driveOwner)
        #expect(try await vault.body(of: opened.item.id) == Data("Private.".utf8))
        // The same person again keeps it open.
        await model.use(owner: "user1")
        #expect(try await vault.body(of: opened.item.id) == Data("Private.".utf8))
        // Signing out, or anyone else, drops it.
        await model.use(owner: nil)
        await #expect(throws: ReaderError.notFound) { try await vault.body(of: opened.item.id) }
        #expect(model.listing("1notes", account: driveOwner) == nil)
    }

    @Test("A key change drops every held Drive file")
    func keyChangeDropsHeldFiles() async throws {
        let vault = try newVault()
        let item = ReaderItem(
            id: UUID(), kind: .file, title: "Essay.md", collection: nil, mime: "text/plain",
            byteCount: 8, createdAt: Date(), updatedAt: Date(), listenPosition: 0
        )
        try await vault.hold(item, body: Data("Private.".utf8))
        await vault.close()
        await #expect(throws: ReaderError.notFound) { try await vault.body(of: item.id) }
    }
}

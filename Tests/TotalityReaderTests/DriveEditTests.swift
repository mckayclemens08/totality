import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

private let essay = Data("# Why I read\n\nBecause the library was warm in January.".utf8)

/// A linked folder with an essay, a plain text list, a Word file, a Google Doc and a PDF, already listed.
private func folder(_ fake: FakeDrive, cache: MemoryBlobStore = MemoryBlobStore()) async throws -> DriveSetup {
    var readOnly = driveFile("1shared", "Syllabus.md", mime: "text/markdown", size: 10)
    readOnly["capabilities"] = ["canEdit": false]
    fake.children["1notes"] = [
        driveFile("1essay", "Essay.md", mime: "text/markdown", size: essay.count),
        driveFile("1list", "Reading list.txt", mime: "text/plain", size: 5),
        driveFile("1word", "Lab report.docx", mime: ReadableText.wordMime, size: 10),
        driveFile("1doc", "Lecture notes", mime: DriveEntry.googleDocMime),
        driveFile("1sheet", "Budget", mime: "application/vnd.google-apps.spreadsheet"),
        readOnly,
    ]
    fake.contents["1essay"] = essay
    fake.contents["1list"] = Data("Dune\n".utf8)
    fake.contents["1word"] = Data("PK".utf8)
    fake.contents["1shared"] = Data("# Week 1\n".utf8)
    fake.exports["1doc"] = Data("# Lecture 4\n\nPhotosynthesis happens in the **chloroplast**.".utf8)
    fake.exports["1sheet"] = Data("%PDF-1.4 budget".utf8)
    let setup = try makeDrive(fake, cache: cache)
    try await setup.drive.link(DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime), account: driveOwner)
    try await setup.drive.refresh("1notes", account: driveOwner)
    return setup
}

private func open(_ id: String, _ setup: DriveSetup) async throws -> DriveOpenedFile {
    try await setup.drive.file(id, in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
}

@Suite struct DriveEditTests {
    @Test func savesBackAsANewRevision() async throws {
        let fake = FakeDrive()
        let setup = try await folder(fake)
        let file = try await open("1essay", setup)
        let result = try await setup.drive.save("# Why I read\n\nRevised in November.", over: file)
        guard case .saved(let saved) = result else { Issue.record("not saved: \(result)"); return }
        #expect(fake.savedFiles["1essay"] == Data("# Why I read\n\nRevised in November.".utf8))
        #expect(saved.version == "8")
        // The kept listing and copy now are that version, so the next open doesn't download again.
        #expect(try await setup.drive.kept("1notes", account: driveOwner)?.entries.first { $0.id == "1essay" }?.version == "8")
        let reopened = try await open("1essay", setup)
        #expect(reopened.data == Data("# Why I read\n\nRevised in November.".utf8))
        #expect(fake.downloaded.count == 1)
    }

    @Test func stopsWhenDrivesCopyChangedMeanwhile() async throws {
        let fake = FakeDrive()
        let setup = try await folder(fake)
        let file = try await open("1essay", setup)
        fake.changeElsewhere("1essay")
        #expect(try await setup.drive.save("Mine", over: file) == .changedInDrive)
        // Nothing was sent over the other change.
        #expect(fake.savedFiles.isEmpty)
        // "Use mine" replaces it, because the person said so.
        guard case .saved = try await setup.drive.save("Mine", over: file, overwrite: true) else { Issue.record("not saved"); return }
        #expect(fake.savedFiles["1essay"] == Data("Mine".utf8))
    }

    @Test func keepBothMakesANewFileBesideTheOriginal() async throws {
        let fake = FakeDrive()
        let setup = try await folder(fake)
        let file = try await open("1essay", setup)
        fake.changeElsewhere("1essay")
        let copy = try await setup.drive.saveCopy("Mine", of: file)
        #expect(copy.name == "Essay (from Totality).md")
        let made = try #require(fake.createdFiles.first)
        #expect(made.parent == "1notes")
        #expect(String(decoding: made.body, as: UTF8.self).contains("Mine"))
        #expect(fake.savedFiles.isEmpty)
        #expect(try await setup.drive.kept("1notes", account: driveOwner)?.entries.contains { $0.name == "Essay (from Totality).md" } == true)
    }

    @Test func onlyTextThisAccountMayChangeCanBeSaved() async throws {
        let fake = FakeDrive()
        let setup = try await folder(fake)
        for id in ["1word", "1doc", "1shared"] {
            let file = try await open(id, setup)
            #expect(!file.entry.isEditableText)
            await #expect(throws: DriveProblem.notAllowed) { try await setup.drive.save("x", over: file) }
            await #expect(throws: DriveProblem.notAllowed) { try await setup.drive.saveCopy("x", of: file) }
        }
        #expect(fake.savedFiles.isEmpty && fake.createdFiles.isEmpty)
        #expect(try await open("1list", setup).entry.isEditableText)
    }

    @Test func aFileNoLongerInALinkedFolderIsntSaved() async throws {
        let fake = FakeDrive()
        let setup = try await folder(fake)
        let file = try await open("1essay", setup)
        try await setup.drive.unlink(try #require(try await setup.drive.links().first))
        await #expect(throws: DriveProblem.notFound) { try await setup.drive.save("x", over: file, overwrite: true) }
        #expect(fake.savedFiles.isEmpty)
    }

    @Test func copyNamesKeepTheirKind() {
        #expect(GoogleDrive.copyName("Essay.md") == "Essay (from Totality).md")
        #expect(GoogleDrive.copyName("Notes") == "Notes (from Totality)")
        #expect(GoogleDrive.copyName("a.b.txt") == "a.b (from Totality).txt")
    }
}

@Suite struct DriveImportTests {
    @MainActor private func model(_ setup: DriveSetup, vault: ReaderVault) -> DriveModel {
        DriveModel(drive: setup.drive, vault: vault, settings: UserDefaults(suiteName: "drive-\(UUID())")!)
    }

    @MainActor @Test func aGoogleDocBecomesAnEditableDoc() async throws {
        let setup = try await folder(FakeDrive())
        let vault = try newVault()
        let item = try await model(setup, vault: vault).importToReader(try await open("1doc", setup))
        #expect(item.kind == .note)
        #expect(item.title == "Lecture notes")
        #expect(item.mime == MarkdownText.mime)
        #expect(String(decoding: try await vault.body(of: item.id), as: UTF8.self).contains("**chloroplast**"))
        #expect(try await vault.list().items.map(\.id) == [item.id])
    }

    @MainActor @Test func markdownBecomesADocAndTheTitleLosesItsExtension() async throws {
        let setup = try await folder(FakeDrive())
        let vault = try newVault()
        let item = try await model(setup, vault: vault).importToReader(try await open("1essay", setup))
        #expect(item.kind == .note)
        #expect(item.title == "Essay")
        #expect(try await vault.body(of: item.id) == essay)
    }

    @MainActor @Test func aSheetImportsAsAPDF() async throws {
        let setup = try await folder(FakeDrive())
        let vault = try newVault()
        let item = try await model(setup, vault: vault).importToReader(try await open("1sheet", setup))
        #expect(item.kind == .file)
        #expect(item.mime == "application/pdf")
    }

    @MainActor @Test func wordHeadingsAndParagraphsBecomeMarkdown() {
        let document = ReadableDocument(sections: [ReadableDocument.Section(blocks: [
            .init(text: "Results", isHeading: true),
            .init(text: "Yield rose by 12% *after* watering."),
            .init(text: "   "),
        ])])
        let markdown = DriveModel.markdown(from: document)
        #expect(markdown.hasPrefix("## Results\n\n"))
        // Word's own asterisks stay words, not emphasis.
        #expect(markdown.contains("\\*after\\*"))
        #expect(!markdown.hasSuffix("\n"))
    }

    @MainActor @Test func importingDoesntTouchDrive() async throws {
        let fake = FakeDrive()
        let setup = try await folder(fake)
        _ = try await model(setup, vault: try newVault()).importToReader(try await open("1essay", setup))
        #expect(fake.savedFiles.isEmpty && fake.createdFiles.isEmpty)
    }
}

@Suite struct DriveDisconnectTests {
    @Test func disconnectingRevokesAndLeavesNothingBehind() async throws {
        let fake = FakeDrive()
        let cache = MemoryBlobStore()
        let setup = try await folder(fake, cache: cache)
        _ = try await open("1essay", setup)
        try setup.accounts.keep(address: driveOwner, refreshToken: "1//shared", granted: [DriveAPI.scope, "https://www.googleapis.com/auth/calendar.readonly"])
        #expect(await setup.drive.alsoEnds(driveOwner) == [.calendar])
        try await setup.drive.disconnect(driveOwner)
        #expect(fake.revoked == 1)
        #expect(try setup.accounts.connection(driveOwner) == nil)
        #expect(try cache.names().isEmpty)
        // The device's state and the shared record, which now holds only the disconnection.
        #expect(try setup.store.names().count == 2)
        #expect(try await setup.drive.links().isEmpty)
    }

    @MainActor @Test func disconnectingClosesWhatsOpen() async throws {
        let setup = try await folder(FakeDrive())
        let vault = try newVault()
        let model = DriveModel(drive: setup.drive, vault: vault, settings: UserDefaults(suiteName: "drive-\(UUID())")!)
        let opened = try await model.openFile(DriveEntry(id: "1essay", name: "Essay.md", mime: "text/markdown"), in: "1notes", account: driveOwner)
        let before = model.openedGeneration
        await model.disconnect(driveOwner)
        #expect(model.openedGeneration > before)
        await #expect(throws: ReaderError.notFound) { try await vault.body(of: opened.item.id) }
    }
}

@Suite struct DriveEditTwoUserTests {
    @Test("User 2 can't save over a file user 1 opened")
    func user2CantSaveUser1sFile() async throws {
        let fake = FakeDrive()
        let user1 = try await folder(fake)
        let file = try await open("1essay", user1)
        let user2 = GoogleDrive(accounts: user1.accounts, store: user1.store, cache: user1.cache, rootKey: try .generate())
        await #expect(throws: DriveProblem.notFound) { try await user2.save("x", over: file, overwrite: true) }
        await #expect(throws: DriveProblem.notFound) { try await user2.saveCopy("x", of: file) }
        #expect(fake.savedFiles.isEmpty && fake.createdFiles.isEmpty)
    }
}

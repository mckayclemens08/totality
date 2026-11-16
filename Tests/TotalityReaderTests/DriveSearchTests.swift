import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

/// "School notes" linked and listed, with an essay in it and a "Biology" folder one down that was never
/// opened, holding a lab report. "Taxes" sits outside every linked folder.
private func linked() async throws -> (FakeDrive, DriveSetup) {
    let fake = FakeDrive()
    fake.children["root"] = [driveFile("1notes", "School notes", mime: DriveEntry.folderMime), driveFile("1taxes", "Taxes", mime: DriveEntry.folderMime)]
    fake.children["1notes"] = [
        driveFile("1essay", "Essay on rivers.md", mime: "text/markdown", size: 40),
        driveFile("1bio", "Biology", mime: DriveEntry.folderMime),
    ]
    fake.children["1bio"] = [driveFile("1cells", "Cells", mime: DriveEntry.folderMime)]
    fake.children["1cells"] = [driveFile("1lab", "Lab report.txt", mime: "text/plain", size: 40)]
    fake.children["1taxes"] = [driveFile("1return", "Return 2025.txt", mime: "text/plain", size: 40)]
    fake.contents["1essay"] = Data("The Tagus reaches the sea at Lisbon.".utf8)
    fake.contents["1lab"] = Data("Yeast in warm water, then the Tagus sample.".utf8)
    fake.contents["1return"] = Data("Tagus Holdings dividend, line 3b.".utf8)
    let setup = try makeDrive(fake)
    try await setup.drive.link(DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime), account: driveOwner)
    try await setup.drive.refresh("1notes", account: driveOwner)
    return (fake, setup)
}

@Suite struct DriveSearchTests {
    @Test("Names match the kept listings at once, without asking Google")
    func namesOffline() async throws {
        let (fake, setup) = try await linked()
        let asked = fake.listings.count
        fake.status = 503
        let hits = try await setup.drive.searchNames("rivers essay")
        #expect(hits.map(\.entry.id) == ["1essay"])
        #expect(hits[0].folders == ["1notes"] && !hits[0].byContents)
        #expect(fake.listings.count == asked)
        #expect(try await setup.drive.searchNames("lab").isEmpty, "Biology was never listed, so its files aren't kept")
    }

    @Test("Contents come from Drive's search, only inside linked folders")
    func contentsInLinkedFolders() async throws {
        let (fake, setup) = try await linked()
        let hits = await setup.drive.searchContents("tagus")
        #expect(Set(hits.map(\.entry.id)) == ["1essay", "1lab"], "The tax return isn't in a linked folder")
        #expect(hits.allSatisfy { $0.byContents })
        // The lab report's folders are followed up to the linked one.
        #expect(hits.first { $0.entry.id == "1lab" }?.folders == ["1cells", "1bio"])
        #expect(fake.searches.count == 1)
    }

    @Test("What's typed reaches Drive quoted, so it can't change the query")
    func wordsAreQuoted() async throws {
        let (fake, setup) = try await linked()
        _ = await setup.drive.searchContents(#"it's or name contains 'x' \"#)
        let query = try #require(fake.searches.first)
        #expect(query.contains(#"fullText contains 'it\'s'"#))
        #expect(query.contains(#"fullText contains '\'x\''"#))
        #expect(query.contains(#"fullText contains '\\'"#))
        #expect(DriveAPI.quoted("a'b\\c") == #"'a\'b\\c'"#)
    }

    @Test("A found file deep in a linked folder opens once its folders are read down to it")
    func deepFileOpens() async throws {
        let (_, setup) = try await linked()
        let lab = try #require(await setup.drive.searchContents("yeast").first)
        let entry = try await setup.drive.prepareFound(lab.entry.id, folders: lab.folders, account: lab.account)
        #expect(entry.name == "Lab report.txt")
        let opened = try await setup.drive.file("1lab", in: "1cells", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(String(decoding: opened.data, as: UTF8.self).hasPrefix("Yeast"))
    }

    @Test("A result made up to reach outside the linked folders gets nowhere")
    func forgedResultRefused() async throws {
        let (_, setup) = try await linked()
        await #expect(throws: DriveProblem.notFound) {
            _ = try await setup.drive.prepareFound("1return", folders: ["1taxes"], account: driveOwner)
        }
        #expect(DriveSearcher.parse("gdrive/1return/1taxes/\(driveOwner)")?.folders == ["1taxes"])
        #expect(DriveSearcher.parse("gdrive/1re turn/1taxes/\(driveOwner)") == nil)
        #expect(DriveSearcher.parse("gdrive/1return//\(driveOwner)") == nil)
        #expect(DriveSearcher.parse(UUID().uuidString) == nil)
    }

    @Test("A disconnected account is skipped without a word")
    func disconnectedSkipped() async throws {
        let (fake, setup) = try await linked()
        try setup.accounts.forget(driveOwner)
        #expect(try await setup.drive.searchNames("essay").isEmpty)
        #expect(await setup.drive.searchContents("tagus").isEmpty)
        #expect(fake.searches.isEmpty)
    }

    @Test("Results are capped")
    func capped() async throws {
        let (fake, setup) = try await linked()
        fake.children["1notes"] = (0..<30).map { driveFile("1ch\($0)", "Chapter \($0).txt", mime: "text/plain", size: 10) }
        for index in 0..<30 { fake.contents["1ch\(index)"] = Data("Tagus".utf8) }
        try await setup.drive.refresh("1notes", account: driveOwner)
        #expect(try await setup.drive.searchNames("chapter").count == GoogleDrive.mostSearchHits)
        #expect(await setup.drive.searchContents("tagus").count == GoogleDrive.mostSearchHits)
    }

    @Test("Results open in the Reader, as the Reader, with a Drive line")
    func hitsLookLikeTheReader() async throws {
        let (_, setup) = try await linked()
        let searcher = DriveSearcher(drive: setup.drive, part: .names)
        let hits = try await searcher.search("essay")
        #expect(hits.map(\.title) == ["Essay on rivers"])
        #expect(hits[0].module == .reader)
        #expect(hits[0].detail == "Markdown in Google Drive")
        let parsed = try #require(DriveSearcher.parse(hits[0].itemID))
        #expect(parsed.fileID == "1essay" && parsed.folders == ["1notes"] && parsed.account == driveOwner)
    }
}

@Suite struct DriveSearchTwoUserTests {
    @Test("User 2 finds nothing in user 1's Drive folders")
    func user2FindsNothing() async throws {
        let (fake, user1) = try await linked()
        let user2 = GoogleDrive(accounts: user1.accounts, store: user1.store, cache: user1.cache, rootKey: try .generate())
        #expect(try await user2.searchNames("essay").isEmpty)
        #expect(await user2.searchContents("tagus").isEmpty)
        #expect(fake.searches.isEmpty, "User 2 has no linked folder, so Google isn't asked")
    }
}

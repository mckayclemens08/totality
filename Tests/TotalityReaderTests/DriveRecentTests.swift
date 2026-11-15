import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

/// A clock the test moves on, so Drive's opened dates can sit before or after the library's.
private final class SetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

private struct Shelf {
    let fake: FakeDrive
    let setup: DriveSetup
    let clock: SetClock
}

/// "School notes" linked, with an essay in it and a lab report one folder down, both listed.
private func shelf(start: Date = Date(timeIntervalSince1970: 1_794_000_000), rootKey: ContentRootKey? = nil) async throws -> Shelf {
    let fake = FakeDrive()
    fake.children["1notes"] = [
        driveFile("1essay", "Essay.md", mime: "text/markdown", size: 5),
        driveFile("1bio", "Biology", mime: DriveEntry.folderMime),
    ]
    fake.children["1bio"] = [driveFile("1lab", "Lab report.txt", mime: "text/plain", size: 5)]
    fake.contents["1essay"] = Data("# Why".utf8)
    fake.contents["1lab"] = Data("Yield".utf8)
    let base = try makeDrive(fake, rootKey: rootKey)
    let clock = SetClock(start)
    let drive = GoogleDrive(accounts: base.accounts, store: base.store, cache: base.cache, rootKey: base.rootKey, now: { clock.now() })
    let setup = DriveSetup(drive: drive, accounts: base.accounts, store: base.store, rootKey: base.rootKey, cache: base.cache)
    try await drive.link(DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime), account: driveOwner)
    try await drive.refresh("1notes", account: driveOwner)
    try await drive.refresh("1bio", account: driveOwner)
    return Shelf(fake: fake, setup: setup, clock: clock)
}

private func open(_ id: String, in folder: String, _ shelf: Shelf, at date: Date) async throws {
    shelf.clock.set(date)
    _ = try await shelf.setup.drive.file(id, in: folder, account: driveOwner, limit: DriveCacheLimit.standard)
}

private let day = TimeInterval(86_400)
private let start = Date(timeIntervalSince1970: 1_794_000_000)

@Suite struct DriveRecentTests {
    @Test func linkedFoldersAndOpenedFilesComeNewestFirst() async throws {
        let shelf = try await shelf()
        try await open("1essay", in: "1notes", shelf, at: start + day)
        try await open("1lab", in: "1bio", shelf, at: start + 2 * day)
        let recent = try await shelf.setup.drive.recent()
        #expect(recent.map(\.title) == ["Lab report.txt", "Essay.md", "School notes"])
        #expect(recent.map(\.account) == [driveOwner, driveOwner, driveOwner])
        #expect(recent[0].mime == "text/plain")
        #expect(recent[2].isFolder && recent[2].openedAt == start)
    }

    @Test func openingAgainMovesItToTheFrontOnce() async throws {
        let shelf = try await shelf()
        try await open("1essay", in: "1notes", shelf, at: start + day)
        try await open("1lab", in: "1bio", shelf, at: start + 2 * day)
        try await open("1essay", in: "1notes", shelf, at: start + 3 * day)
        let recent = try await shelf.setup.drive.recent()
        #expect(recent.map(\.id) == ["1essay", "1lab", "1notes"])
    }

    @Test func onlyALinkedFolderIsRememberedAsOpened() async throws {
        let shelf = try await shelf()
        shelf.clock.set(start + day)
        try await shelf.setup.drive.noteOpenedFolder("1bio", account: driveOwner)
        try await shelf.setup.drive.noteOpenedFolder("1notes", account: driveOwner)
        let recent = try await shelf.setup.drive.recent()
        #expect(recent.map(\.id) == ["1notes"])
        #expect(recent[0].openedAt == start + day)
    }

    @Test func aFileIsFoundWhereItsFolderListsIt() async throws {
        let shelf = try await shelf()
        let found = try #require(try await shelf.setup.drive.whereIs("1lab", account: driveOwner))
        #expect(found.folderID == "1bio")
        #expect(found.entry.name == "Lab report.txt")
        #expect(try await shelf.setup.drive.whereIs("1elsewhere", account: driveOwner) == nil)
    }

    @Test func onlyTheLatestFilesAreKept() async throws {
        let shelf = try await shelf()
        let files = (0..<(GoogleDrive.mostRecent + 3)).map { driveFile("1f\($0)", "Chapter \($0).txt", mime: "text/plain", size: 1) }
        shelf.fake.children["1notes"] = files
        for index in files.indices { shelf.fake.contents["1f\(index)"] = Data("x".utf8) }
        try await shelf.setup.drive.refresh("1notes", account: driveOwner)
        for index in files.indices {
            try await open("1f\(index)", in: "1notes", shelf, at: start + Double(index + 1) * day)
        }
        let recent = try await shelf.setup.drive.recent()
        #expect(recent.filter { !$0.isFolder }.count == GoogleDrive.mostRecent)
        #expect(recent.first?.id == "1f\(GoogleDrive.mostRecent + 2)")
        // The linked folder stays, however many files were opened.
        #expect(recent.contains { $0.id == "1notes" })
    }

    @Test func itsKeptSealed() async throws {
        let shelf = try await shelf()
        try await open("1essay", in: "1notes", shelf, at: start + day)
        for name in try shelf.setup.store.names() {
            let bytes = try #require(try shelf.setup.store.read(name))
            #expect(!name.contains("Essay"))
            #expect(bytes.range(of: Data("Essay.md".utf8)) == nil)
            #expect(bytes.range(of: Data(driveOwner.utf8)) == nil)
        }
    }

    @Test func unlinkingDropsItsFiles() async throws {
        let shelf = try await shelf()
        try await open("1lab", in: "1bio", shelf, at: start + day)
        try await shelf.setup.drive.unlink(try #require(try await shelf.setup.drive.links().first))
        #expect(try await shelf.setup.drive.recent().isEmpty)
        // And not just hidden: linking it again starts with nothing opened.
        shelf.clock.set(start + 2 * day)
        try await shelf.setup.drive.link(DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime), account: driveOwner)
        try await shelf.setup.drive.refresh("1notes", account: driveOwner)
        try await shelf.setup.drive.refresh("1bio", account: driveOwner)
        #expect(try await shelf.setup.drive.recent().map(\.id) == ["1notes"])
    }

    @Test func disconnectingDropsTheAccountsEntries() async throws {
        let shelf = try await shelf()
        try await open("1essay", in: "1notes", shelf, at: start + day)
        try await shelf.setup.drive.disconnect(driveOwner)
        #expect(try await shelf.setup.drive.recent().isEmpty)
        // Gone from the sealed state, not only filtered out while disconnected.
        try shelf.setup.accounts.keep(address: driveOwner, refreshToken: "1//again", granted: [DriveAPI.scope])
        #expect(try await shelf.setup.drive.recent().isEmpty)
    }
}

@MainActor
@Suite struct DriveShelfTests {
    private func reader(_ shelf: Shelf) throws -> (ReaderModel, DriveModel) {
        let vault = try newVault()
        let model = ReaderModel(vault: vault, listen: ListenController(engine: FakeSpeechEngine()))
        let drive = DriveModel(drive: shelf.setup.drive, vault: vault, settings: UserDefaults(suiteName: "shelf-\(UUID())")!)
        model.drive = drive
        return (model, drive)
    }

    @Test("Drive files and linked folders sit on the home tile by when they were opened")
    func theShelfMixesTheLibraryAndDrive() async throws {
        let now = Date()
        let shelf = try await shelf(start: now - day)
        let (model, drive) = try reader(shelf)
        let note = try #require(await model.newNote())
        #expect(await model.saveNote(note.id, title: "Lease", body: "Rent is due on the first."))
        shelf.clock.set(now + day)
        _ = try await drive.openFile(DriveEntry(id: "1essay", name: "Essay.md", mime: "text/markdown"), in: "1notes", account: driveOwner)
        await model.load()
        #expect(model.shelf.map(\.title) == ["Essay", "Lease", "School notes"])
        #expect(model.frontOfShelf?.title == "Essay")
        #expect(model.frontOfShelf?.typeName == "Markdown in Google Drive")
        #expect(model.glance?.lines == ["Essay", "Lease", "School notes", "1 item"])
    }

    @Test("With only Drive, the home tile still shows")
    func onlyDrive() async throws {
        let (model, _) = try reader(try await shelf())
        await model.load()
        #expect(model.glance == ModuleGlance(lines: ["School notes", "In Google Drive"], isQuiet: false))
    }

    @Test("Tapping a Drive file opens it from the folder that lists it")
    func tappingOpensTheFile() async throws {
        let shelf = try await shelf()
        let (model, drive) = try reader(shelf)
        _ = try await drive.openFile(DriveEntry(id: "1lab", name: "Lab report.txt", mime: "text/plain"), in: "1bio", account: driveOwner)
        await model.load()
        let lab = try #require(model.shelf.first { $0.title == "Lab report" })
        guard case .driveFile(let route)?? = await model.openDriveShelfEntry(lab.id) else { Issue.record("not a file"); return }
        #expect(route.location.folderID == "1bio" && route.location.account == driveOwner)
        #expect(route.entry.id == "1lab")
        let folder = try #require(model.shelf.first { $0.title == "School notes" })
        guard case .drive(let location)?? = await model.openDriveShelfEntry(folder.id) else { Issue.record("not a folder"); return }
        #expect(location.folderID == "1notes")
        // A library item isn't Drive's to open.
        #expect(await model.openDriveShelfEntry(UUID()) == nil)
    }

    @Test("A file whose folder was unlinked meanwhile says so instead of opening")
    func goneFileDoesntOpen() async throws {
        let shelf = try await shelf()
        let (model, drive) = try reader(shelf)
        _ = try await drive.openFile(DriveEntry(id: "1essay", name: "Essay.md", mime: "text/markdown"), in: "1notes", account: driveOwner)
        await model.load()
        let essay = try #require(model.shelf.first { $0.title == "Essay" })
        try await shelf.setup.drive.unlink(try #require(try await shelf.setup.drive.links().first))
        guard case .some(.none) = await model.openDriveShelfEntry(essay.id) else { Issue.record("opened"); return }
    }

    @Test("Disconnecting the account takes its entries off the tile")
    func disconnectEmptiesTheTile() async throws {
        let (model, drive) = try reader(try await shelf())
        await model.load()
        #expect(!model.shelf.isEmpty)
        await drive.disconnect(driveOwner)
        #expect(model.shelf.isEmpty)
        #expect(model.glance == ModuleGlance(lines: ["Nothing saved yet"], isQuiet: true))
    }
}

@Suite struct DriveRecentTwoUserTests {
    @Test("User 2 sees none of what user 1 opened from Drive")
    func user2SeesNoneOfUser1sRecent() async throws {
        let user1 = try await shelf()
        try await open("1essay", in: "1notes", user1, at: start + day)
        let user2 = GoogleDrive(accounts: user1.setup.accounts, store: user1.setup.store, cache: user1.setup.cache, rootKey: try .generate())
        #expect(try await user2.recent().isEmpty)
        #expect(try await user2.whereIs("1essay", account: driveOwner) == nil)
        // And user 1's record is still theirs.
        #expect(try await user1.setup.drive.recent().map(\.id) == ["1essay", "1notes"])
    }
}

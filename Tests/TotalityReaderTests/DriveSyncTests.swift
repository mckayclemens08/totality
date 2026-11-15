import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

private func notes(_ fake: FakeDrive) {
    fake.children["1notes"] = [
        driveFile("1essay", "Essay.md", mime: "text/markdown", size: 5),
        driveFile("1bio", "Biology", mime: DriveEntry.folderMime),
    ]
    fake.children["1bio"] = [driveFile("1lab", "Lab report.txt", mime: "text/plain", size: 5)]
    fake.children["1art"] = [driveFile("1sketch", "Sketch notes.txt", mime: "text/plain", size: 5)]
    fake.contents["1essay"] = Data("# Why".utf8)
    fake.contents["1lab"] = Data("Yield".utf8)
    fake.contents["1sketch"] = Data("Lines".utf8)
}

private let schoolNotes = DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime)
private let art = DriveEntry(id: "1art", name: "Art class", mime: DriveEntry.folderMime)

/// One person's two devices: the same content key, each with its own storage and Google sign-in.
private struct Devices {
    let fake: FakeDrive
    let phone: DriveSetup
    let mac: DriveSetup
    let clock: Clock

    init(macConnected: Bool = true) throws {
        fake = FakeDrive()
        notes(fake)
        let key = try ContentRootKey.generate()
        // One clock for both, so which came first means the same on each.
        let clock = Clock()
        self.clock = clock
        func device(_ setup: DriveSetup) -> DriveSetup {
            let drive = GoogleDrive(accounts: setup.accounts, store: setup.store, cache: setup.cache, rootKey: key, now: { clock.tick() })
            return DriveSetup(drive: drive, accounts: setup.accounts, store: setup.store, rootKey: key, cache: setup.cache)
        }
        phone = device(try makeDrive(fake, rootKey: key))
        mac = device(try makeDrive(fake, rootKey: key, granted: macConnected ? [DriveAPI.scope] : nil))
    }
}

/// What sync does with one copy: takes it from one device and gives it to the other.
private func carry(_ from: GoogleDrive, to: GoogleDrive) async throws {
    let id = try #require(try await from.sealedObjectIDs().first)
    let object = try #require(try await from.verifiedObject(id))
    try await to.store(object, ifLocalHash: try await to.sealedHash(of: id))
}

/// What sync does when both changed: the other side's copy, settled by the module.
private func settle(_ local: GoogleDrive, with remote: GoogleDrive) async throws {
    let id = try #require(try await remote.sealedObjectIDs().first)
    let mine = try #require(try await local.sealedObject(id))
    let theirs = try #require(try await remote.sealedObject(id))
    #expect(try await local.resolveConflict(local: mine, remote: theirs) == .keepRemote)
    try await local.store(theirs, ifLocalHash: mine.hash)
}

private func list(_ drive: GoogleDrive) async throws {
    try await drive.refresh("1notes", account: driveOwner)
    try await drive.refresh("1bio", account: driveOwner)
}

@Suite struct DriveSyncTests {
    @Test func linksAndOpenedFilesReachTheOtherDevice() async throws {
        let devices = try Devices()
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        try await list(devices.phone.drive)
        _ = try await devices.phone.drive.file("1lab", in: "1bio", account: driveOwner, limit: DriveCacheLimit.standard)
        // The phone goes to the background, which sends what was opened.
        try await devices.phone.drive.publishHeld()
        try await carry(devices.phone.drive, to: devices.mac.drive)
        #expect(try await devices.mac.drive.links().map(\.name) == ["School notes"])
        // The Mac reads Drive itself. Once it has, the lab report is on its tile too.
        try await list(devices.mac.drive)
        #expect(try await devices.mac.drive.recent().map(\.id) == ["1lab", "1notes"])
        // Only the record travelled: no listings, and nothing downloaded on the Mac.
        #expect(try devices.mac.cache.names().isEmpty)
    }

    @Test func opensWaitBeforeTheySync() async throws {
        let devices = try Devices()
        let phone = devices.phone.drive
        try await phone.link(schoolNotes, account: driveOwner)
        try await list(phone)
        let id = try #require(try await phone.sealedObjectIDs().first)
        let linked = try await phone.sealedHash(of: id)
        _ = try await phone.file("1lab", in: "1bio", account: driveOwner, limit: DriveCacheLimit.standard)
        // Shown here at once, but not yet in what syncs, so the server can't tell when it was opened.
        #expect(try await phone.recent().first?.id == "1lab")
        #expect(try await phone.sealedHash(of: id) == linked)
        _ = await phone.refreshAll(onlyChanged: true)
        #expect(try await phone.sealedHash(of: id) == linked)
        // Once the first open has waited a few minutes, the quiet refresh sends them all.
        devices.clock.advance(by: GoogleDrive.holdOpens)
        _ = await phone.refreshAll(onlyChanged: true)
        #expect(try await phone.sealedHash(of: id) != linked)
        try await carry(phone, to: devices.mac.drive)
        try await list(devices.mac.drive)
        #expect(try await devices.mac.drive.recent().map(\.id) == ["1lab", "1notes"])
    }

    @Test func linkingDoesntWait() async throws {
        let devices = try Devices()
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        try await list(devices.phone.drive)
        _ = try await devices.phone.drive.file("1lab", in: "1bio", account: driveOwner, limit: DriveCacheLimit.standard)
        // A link goes straight away, and takes the waiting open with it.
        try await devices.phone.drive.link(art, account: driveOwner)
        try await carry(devices.phone.drive, to: devices.mac.drive)
        try await list(devices.mac.drive)
        #expect(try await devices.mac.drive.allLinks().count == 2)
        #expect(try await devices.mac.drive.recent().contains { $0.id == "1lab" })
    }

    @Test func theRecordIsSealedAndOnePerPerson() async throws {
        let devices = try Devices()
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        try await devices.mac.drive.link(art, account: driveOwner)
        // The same ID on both devices, worked out from the key, so they settle into one record.
        let phoneID = try #require(try await devices.phone.drive.sealedObjectIDs().first)
        #expect(try await devices.mac.drive.sealedObjectIDs() == [phoneID])
        #expect(phoneID != UUID(derivedFrom: "totality.reader.drive.links"))
        let object = try #require(try await devices.phone.drive.sealedObject(phoneID))
        #expect(object.kind == .readerDrive)
        #expect(object.body == nil)
        for secret in ["School notes", driveOwner, "1notes"] {
            #expect(object.meta.range(of: Data(secret.utf8)) == nil)
        }
    }

    @Test func linkingOnBothDevicesAtOnceKeepsBoth() async throws {
        let devices = try Devices()
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        try await devices.mac.drive.link(art, account: driveOwner)
        try await settle(devices.mac.drive, with: devices.phone.drive)
        #expect(Set(try await devices.mac.drive.links().map(\.folderID)) == ["1notes", "1art"])
        // The merge goes back up, so the phone ends up with both too.
        try await carry(devices.mac.drive, to: devices.phone.drive)
        #expect(Set(try await devices.phone.drive.links().map(\.folderID)) == ["1notes", "1art"])
    }

    @Test func unlinkingOnOneDeviceUnlinksEverywhere() async throws {
        let devices = try Devices()
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        try await devices.phone.drive.link(art, account: driveOwner)
        try await carry(devices.phone.drive, to: devices.mac.drive)
        try await devices.phone.drive.unlink(try #require(try await devices.phone.drive.links().first { $0.folderID == "1notes" }))
        // The Mac changed the record too, opening a file from Art class, so the two settle.
        try await devices.mac.drive.refresh("1art", account: driveOwner)
        _ = try await devices.mac.drive.file("1sketch", in: "1art", account: driveOwner, limit: DriveCacheLimit.standard)
        try await settle(devices.mac.drive, with: devices.phone.drive)
        #expect(try await devices.mac.drive.links().map(\.folderID) == ["1art"])
        #expect(try await devices.mac.drive.recent().map(\.id) == ["1sketch", "1art"])
        // And the Mac's older copy can't bring School notes back to the phone.
        try await carry(devices.mac.drive, to: devices.phone.drive)
        #expect(try await devices.phone.drive.links().map(\.folderID) == ["1art"])
    }

    @Test func disconnectingRemovesTheAccountEverywhere() async throws {
        let devices = try Devices()
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        try await list(devices.phone.drive)
        _ = try await devices.phone.drive.file("1lab", in: "1bio", account: driveOwner, limit: DriveCacheLimit.standard)
        // The phone goes to the background, which sends what was opened.
        try await devices.phone.drive.publishHeld()
        try await carry(devices.phone.drive, to: devices.mac.drive)
        try await devices.phone.drive.disconnect(driveOwner)
        // The Mac still had its copy and changed it meanwhile.
        try await devices.mac.drive.link(art, account: driveOwner)
        try await settle(devices.mac.drive, with: devices.phone.drive)
        // Only what came after the disconnection stays.
        #expect(try await devices.mac.drive.allLinks().map(\.folderID) == ["1art"])
        #expect(try await devices.mac.drive.recent().allSatisfy { $0.id != "1lab" })
    }

    @Test func anAccountNotConnectedHereShowsConnectToSee() async throws {
        let devices = try Devices(macConnected: false)
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        try await list(devices.phone.drive)
        _ = try await devices.phone.drive.file("1lab", in: "1bio", account: driveOwner, limit: DriveCacheLimit.standard)
        // The phone goes to the background, which sends what was opened.
        try await devices.phone.drive.publishHeld()
        try await carry(devices.phone.drive, to: devices.mac.drive)
        #expect(try await devices.mac.drive.links().isEmpty)
        #expect(try await devices.mac.drive.allLinks().map(\.folderID) == ["1notes"])
        // The folder is on the tile, to connect; its files wait until this device can read them.
        #expect(try await devices.mac.drive.recent().map(\.id) == ["1notes"])
        // Refreshing here doesn't take it for a disconnection, because it was never connected here.
        _ = await devices.mac.drive.refreshAll()
        #expect(try await devices.mac.drive.allLinks().map(\.folderID) == ["1notes"])
        #expect(try await devices.mac.drive.sealedHash(of: try #require(try await devices.mac.drive.sealedObjectIDs().first)) != nil)
        let model = await DriveModel(drive: devices.mac.drive)
        await model.load()
        #expect(await model.elsewhere.map(\.folderID) == ["1notes"])
        #expect(await model.needsConnecting(driveOwner))
    }

    @Test func aDisconnectionHereFromElsewhereStillCounts() async throws {
        let devices = try Devices()
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        // Calendar disconnects the account on the phone.
        try devices.phone.accounts.forget(driveOwner)
        _ = await devices.phone.drive.refreshAll()
        try await carry(devices.phone.drive, to: devices.mac.drive)
        #expect(try await devices.mac.drive.allLinks().isEmpty)
    }

    @Test func foldersLinkedBeforeSyncMoveIntoTheRecord() async throws {
        let fake = FakeDrive()
        let setup = try makeDrive(fake)
        var old = GoogleDrive.LocalState()
        old.links = [DriveLink(account: driveOwner, folderID: "1notes", name: "School notes", linkedAt: Date(timeIntervalSince1970: 1_794_000_000))]
        try await setup.drive.seal(JSONEncoder().encode(old), id: GoogleDrive.linksID)
        #expect(try await setup.drive.links().map(\.folderID) == ["1notes"])
        #expect(try await setup.drive.sealedObjectIDs().isEmpty)
        try await setup.drive.refresh("1notes", account: driveOwner)
        #expect(try await setup.drive.sealedObjectIDs().count == 1)
        #expect(try await setup.drive.links().map(\.folderID) == ["1notes"])
    }

    @Test func aServerDeletionDoesntTakeLinksAway() async throws {
        let devices = try Devices()
        try await devices.phone.drive.link(schoolNotes, account: driveOwner)
        let id = try #require(try await devices.phone.drive.sealedObjectIDs().first)
        try await devices.phone.drive.removeObject(id, ifLocalHash: try #require(try await devices.phone.drive.sealedHash(of: id)))
        #expect(try await devices.phone.drive.links().count == 1)
    }
}

@Suite struct DriveSyncTwoUserTests {
    @Test("User 2 never takes in user 1's Drive record")
    func user2NeverReceivesUser1sRecord() async throws {
        let fake = FakeDrive()
        notes(fake)
        let user1 = try makeDrive(fake)
        let user2 = try makeDrive(fake)
        try await user1.drive.link(schoolNotes, account: driveOwner)
        try await user2.drive.link(art, account: driveOwner)
        let id1 = try #require(try await user1.drive.sealedObjectIDs().first)
        let id2 = try #require(try await user2.drive.sealedObjectIDs().first)
        // Different people's records never share an ID on the server.
        #expect(id1 != id2)
        let object = try #require(try await user1.drive.sealedObject(id1))
        await #expect(throws: (any Error).self) { try await user2.drive.store(object, ifLocalHash: nil) }
        // Even forced into user 2's own ID, it doesn't open.
        let renamed = SealedObject(id: id2, kind: .readerDrive, meta: object.meta, body: nil)
        await #expect(throws: (any Error).self) { try await user2.drive.store(renamed, ifLocalHash: try await user2.drive.sealedHash(of: id2)) }
        #expect(try await user2.drive.allLinks().map(\.folderID) == ["1art"])
        #expect(try await user2.drive.sealedObjectIDs() == [id2])
    }
}

@Suite struct DriveChangesTests {
    private func linked() async throws -> (FakeDrive, DriveSetup) {
        let fake = FakeDrive()
        notes(fake)
        let setup = try makeDrive(fake, cache: MemoryBlobStore())
        try await setup.drive.link(schoolNotes, account: driveOwner)
        try await list(setup.drive)
        // The first quiet refresh reads everything, and learns where Drive's changes start.
        #expect(await setup.drive.refreshAll(onlyChanged: true).problems.isEmpty)
        return (fake, setup)
    }

    @Test func onlyTheFoldersThatChangedAreRead() async throws {
        let (fake, setup) = try await linked()
        let before = fake.listedFolders.count
        // Nothing changed: Google is asked what changed, and no folder is read.
        _ = await setup.drive.refreshAll(onlyChanged: true)
        #expect(fake.listedFolders.count == before)
        fake.add(driveFile("1lab2", "Lab report 2.txt", mime: "text/plain", size: 3), to: "1bio")
        _ = await setup.drive.refreshAll(onlyChanged: true)
        #expect(Array(fake.listedFolders.dropFirst(before)) == ["1bio"])
        #expect(try await setup.drive.kept("1bio", account: driveOwner)?.entries.map(\.id) == ["1lab", "1lab2"])
    }

    @Test func aFileDeletedElsewhereLeavesItsFolder() async throws {
        let (fake, setup) = try await linked()
        let before = fake.listedFolders.count
        fake.remove("1essay")
        _ = await setup.drive.refreshAll(onlyChanged: true)
        #expect(Array(fake.listedFolders.dropFirst(before)) == ["1notes"])
        #expect(try await setup.drive.kept("1notes", account: driveOwner)?.entries.map(\.id) == ["1bio"])
    }

    @Test func whenDriveForgetsWhereItWasEverythingIsRead() async throws {
        let (fake, setup) = try await linked()
        let before = fake.listedFolders.count
        fake.forgetsChangeTokens = true
        #expect(await setup.drive.refreshAll(onlyChanged: true).problems.isEmpty)
        #expect(Set(fake.listedFolders.dropFirst(before)) == ["1notes", "1bio"])
    }

    @Test func aNewlyLinkedFolderIsReadOnTheNextQuietRefresh() async throws {
        let (fake, setup) = try await linked()
        try await setup.drive.link(art, account: driveOwner)
        let before = fake.listedFolders.count
        _ = await setup.drive.refreshAll(onlyChanged: true)
        #expect(Array(fake.listedFolders.dropFirst(before)) == ["1art"])
    }

    @Test func aKeptFileIsDownloadedAgainWhenItChanges() async throws {
        let (fake, setup) = try await linked()
        _ = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        fake.contents["1essay"] = Data("# Why, revised".utf8)
        fake.changeElsewhere("1essay")
        _ = await setup.drive.refreshAll(onlyChanged: true)
        let downloads = fake.downloaded.count
        #expect(await setup.drive.refreshKeptFiles(limit: DriveCacheLimit.standard) == ["\(driveOwner)/1essay"])
        #expect(fake.downloaded.count == downloads + 1)
        // Opening it now needs nothing from Google, and it's the new version.
        let opened = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(opened.data == Data("# Why, revised".utf8))
        #expect(fake.downloaded.count == downloads + 1)
        // Nothing changed since, so the next refresh downloads nothing.
        #expect(await setup.drive.refreshKeptFiles(limit: DriveCacheLimit.standard).isEmpty)
    }

    @Test func aGoogleDocKeptOnTheDeviceStaysCurrent() async throws {
        let (fake, setup) = try await linked()
        fake.add(driveFile("1doc", "Lecture notes", mime: DriveEntry.googleDocMime), to: "1notes")
        fake.exports["1doc"] = Data("# Lecture 4".utf8)
        _ = await setup.drive.refreshAll(onlyChanged: true)
        _ = try await setup.drive.file("1doc", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        fake.exports["1doc"] = Data("# Lecture 4, with the slides".utf8)
        fake.changeElsewhere("1doc")
        _ = await setup.drive.refreshAll(onlyChanged: true)
        #expect(await setup.drive.refreshKeptFiles(limit: DriveCacheLimit.standard) == ["\(driveOwner)/1doc"])
        let opened = try await setup.drive.file("1doc", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        #expect(opened.data == Data("# Lecture 4, with the slides".utf8))
    }

    @Test func refreshingKeptFilesStaysInsideTheAllowance() async throws {
        let (fake, setup) = try await linked()
        _ = try await setup.drive.file("1essay", in: "1notes", account: driveOwner, limit: DriveCacheLimit.standard)
        _ = try await setup.drive.file("1lab", in: "1bio", account: driveOwner, limit: DriveCacheLimit.standard)
        fake.contents["1essay"] = Data("# Why, and a much longer answer".utf8)
        fake.changeElsewhere("1essay")
        _ = await setup.drive.refreshAll(onlyChanged: true)
        // Room for one: the essay was opened before the lab report, so it gives way rather than push it out.
        _ = await setup.drive.refreshKeptFiles(limit: 10)
        #expect(try await setup.drive.cachedBytes() <= 10)
        #expect(try await setup.drive.cachedBytes() == 5)
    }

    @Test func aRenameInDriveReachesTheTile() async throws {
        let (fake, setup) = try await linked()
        _ = try await setup.drive.file("1lab", in: "1bio", account: driveOwner, limit: DriveCacheLimit.standard)
        fake.remove("1lab")
        fake.add(driveFile("1lab", "Lab report, final.txt", mime: "text/plain", size: 5), to: "1bio")
        _ = await setup.drive.refreshAll(onlyChanged: true)
        #expect(try await setup.drive.recent().first?.title == "Lab report, final.txt")
    }

    @MainActor @Test func theQuietRefreshTellsAnOpenScreenWhenItsFileChanged() async throws {
        let (fake, setup) = try await linked()
        let model = DriveModel(drive: setup.drive, vault: try newVault(), settings: UserDefaults(suiteName: "changes-\(UUID())")!)
        _ = try await model.openFile(DriveEntry(id: "1essay", name: "Essay.md", mime: "text/markdown"), in: "1notes", account: driveOwner)
        fake.contents["1essay"] = Data("# Why, revised".utf8)
        fake.changeElsewhere("1essay")
        #expect(await model.refreshAll(force: false) == .done)
        #expect(model.fileUpdates["\(driveOwner)/1essay"] == 1)
    }
}

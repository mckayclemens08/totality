import Foundation
import Testing
import TotalityCore
@testable import TotalityAccount

actor FakeBackupService: KeyBackupService {
    var stored: KeyBackup?
    var fetchError: AccountError?
    var saveError: AccountError?
    var matrixWorks = true
    /// Stands in for another device saving first.
    var raceWinner: KeyBackup?
    private(set) var matrixCopies = 0

    func set(stored: KeyBackup?) { self.stored = stored }
    func fail(fetch: AccountError? = nil, save: AccountError? = nil) {
        fetchError = fetch
        saveError = save
    }
    func setMatrixWorks(_ works: Bool) { matrixWorks = works }
    func setRaceWinner(_ backup: KeyBackup) { raceWinner = backup }

    func fetchBackup() async throws -> KeyBackup? {
        if let fetchError { throw fetchError }
        return stored
    }
    func saveBackup(_ backup: KeyBackup) async throws {
        if let saveError { throw saveError }
        if let raceWinner {
            stored = raceWinner
            throw AccountError.backupExists
        }
        stored = backup
    }
    func copyBackupToMatrix(_ backup: KeyBackup) async -> Bool {
        matrixCopies += 1
        return matrixWorks
    }
}

actor FakeContentKeys: ContentKeyAccess {
    var key: ContentRootKey
    var joined: String?
    var adoptError: Error?
    var report = KeyMoveReport(moved: 0, unreadable: 0)
    private(set) var adopted: [ContentRootKey] = []

    init(key: ContentRootKey) { self.key = key }
    func failAdopting() { adoptError = CryptoError.authenticationFailed }
    func setReport(_ report: KeyMoveReport) { self.report = report }
    func setJoined(_ id: String) { joined = id }

    func rootKey() async throws -> ContentRootKey { key }
    func adopt(_ key: ContentRootKey) async throws -> KeyMoveReport {
        if let adoptError { throw adoptError }
        adopted.append(key)
        self.key = key
        return report
    }
    func joinedBackupID() async throws -> String? { joined }
    func markJoined(_ id: String) async throws { joined = id }
}

@MainActor
@Suite struct BackupModelTests {
    private func setUp() throws -> (model: BackupModel, service: FakeBackupService, content: FakeContentKeys) {
        let service = FakeBackupService()
        let content = FakeContentKeys(key: try ContentRootKey.generate())
        return (BackupModel(service: service, content: content), service, content)
    }

    private func shownKey(_ model: BackupModel) throws -> String {
        guard case .showingKey(let key) = model.phase else {
            Issue.record("No key on screen")
            throw AccountError.failed
        }
        return key
    }

    @Test func aNewAccountIsOfferedSetup() async throws {
        let (model, _, _) = try setUp()
        await model.load()
        #expect(model.phase == .notSetUp)
    }

    @Test("Nothing is stored until the key has been typed back")
    func nothingStoredBeforeConfirming() async throws {
        let (model, service, _) = try setUp()
        await model.load()
        model.begin()
        _ = try shownKey(model)
        model.continueToConfirm()
        #expect(await service.stored == nil)
    }

    @Test("Setting up locks this device's own key, and proves the typed key opens it")
    func setupLocksTheCurrentKey() async throws {
        let (model, service, content) = try setUp()
        await model.load()
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await model.confirm(key)
        #expect(model.phase == .ready(matrixCopy: true))
        let stored = try #require(await service.stored)
        #expect(try stored.open(with: RecoveryKey(encoded: key)) == (await content.key))
        #expect(await content.joined == stored.keyID)
    }

    @Test("A wrong key at the confirm step stores nothing and says so")
    func wrongConfirmationStoresNothing() async throws {
        let (model, service, _) = try setUp()
        await model.load()
        model.begin()
        model.continueToConfirm()
        await model.confirm(try RecoveryKey.generate().encoded)
        #expect(model.phase == .confirmingKey)
        #expect(model.notice != nil)
        #expect(await service.stored == nil)
    }

    @Test("A typo that isn't a key at all is also refused")
    func garbageConfirmationIsRefused() async throws {
        let (model, service, _) = try setUp()
        await model.load()
        model.begin()
        model.continueToConfirm()
        await model.confirm("not a recovery key")
        #expect(model.notice != nil)
        #expect(await service.stored == nil)
    }

    @Test("You can go back and look at the key before finishing")
    func canSeeTheKeyAgain() async throws {
        let (model, _, _) = try setUp()
        model.begin()
        let first = try shownKey(model)
        model.continueToConfirm()
        model.showKeyAgain()
        #expect(try shownKey(model) == first)
    }

    @Test("Leaving the screen forgets an unconfirmed key")
    func reloadingForgetsTheKey() async throws {
        let (model, _, _) = try setUp()
        model.begin()
        await model.load()
        model.showKeyAgain()
        #expect(model.phase == .notSetUp)
    }

    @Test("A failed save keeps the key so the person can finish")
    func failedSaveCanRetry() async throws {
        let (model, service, _) = try setUp()
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await service.fail(save: .offline)
        await model.confirm(key)
        #expect(model.phase == .confirmingKey)
        #expect(model.notice == AccountError.offline.message)
        await service.fail()
        await model.confirm(key)
        #expect(model.phase == .ready(matrixCopy: true))
    }

    @Test("If another device set up first, this one joins that key instead of replacing it")
    func losingTheRaceJoins() async throws {
        let (model, service, content) = try setUp()
        let otherRecovery = try RecoveryKey.generate()
        let other = try KeyBackup.seal(try ContentRootKey.generate(), with: otherRecovery)
        await model.load()
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await service.setRaceWinner(other)
        await model.confirm(key)
        #expect(model.phase == .needsKey)
        #expect(model.notice != nil)
        #expect(await service.stored == other)
        #expect(await content.joined == nil)
    }

    @Test("Without Matrix, the backup is still saved and the screen says so")
    func matrixDownStillSaves() async throws {
        let (model, service, _) = try setUp()
        await service.setMatrixWorks(false)
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await model.confirm(key)
        #expect(model.phase == .ready(matrixCopy: false))
        #expect(await service.stored != nil)
    }

    @Test("The Matrix copy is retried each time the screen opens")
    func matrixCopyRetries() async throws {
        let (model, service, content) = try setUp()
        let backup = try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate())
        await service.set(stored: backup)
        await content.setJoined(backup.keyID)
        await model.load()
        #expect(model.phase == .ready(matrixCopy: true))
        #expect(await service.matrixCopies == 1)
    }

    @Test("A second device is asked for the key, and takes on the shared content key")
    func secondDeviceJoins() async throws {
        let (model, service, content) = try setUp()
        let shared = try ContentRootKey.generate()
        let recovery = try RecoveryKey.generate()
        let backup = try KeyBackup.seal(shared, with: recovery)
        await service.set(stored: backup)
        await model.load()
        #expect(model.phase == .needsKey)
        await model.enter(recovery.encoded)
        #expect(model.phase == .ready(matrixCopy: true))
        #expect(await content.adopted == [shared])
        #expect(await content.joined == backup.keyID)
    }

    @Test("The wrong recovery key touches nothing")
    func wrongKeyTouchesNothing() async throws {
        let (model, service, content) = try setUp()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate()))
        await model.load()
        await model.enter(try RecoveryKey.generate().encoded)
        #expect(model.phase == .needsKey)
        #expect(model.notice?.contains("not the recovery key") == true)
        #expect(await content.adopted.isEmpty)
        #expect(await content.joined == nil)
    }

    @Test("Garbage isn't treated as a key")
    func garbageEntryIsRefused() async throws {
        let (model, service, content) = try setUp()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate()))
        await model.load()
        await model.enter("hello")
        #expect(model.notice != nil)
        #expect(await content.adopted.isEmpty)
    }

    @Test("A move that fails doesn't count as joined, so it can be tried again")
    func failedMoveCanRetry() async throws {
        let (model, service, content) = try setUp()
        let recovery = try RecoveryKey.generate()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: recovery))
        await content.failAdopting()
        await model.load()
        await model.enter(recovery.encoded)
        #expect(model.phase == .needsKey)
        #expect(model.notice != nil)
        #expect(await content.joined == nil)
    }

    @Test("Items that couldn't move are reported, not hidden")
    func unreadableItemsAreReported() async throws {
        let (model, service, content) = try setUp()
        let recovery = try RecoveryKey.generate()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: recovery))
        await content.setReport(KeyMoveReport(moved: 4, unreadable: 2))
        await model.load()
        await model.enter(recovery.encoded)
        #expect(model.notice?.contains("2 items") == true)
    }

    @Test("When the backup can't be checked, nothing assumes it's missing")
    func unavailableIsNotNotSetUp() async throws {
        let (model, service, _) = try setUp()
        await service.fail(fetch: .offline)
        await model.load()
        #expect(model.phase == .unavailable)
    }

    @Test("A joined device isn't asked again")
    func joinedDeviceIsReady() async throws {
        let (model, service, content) = try setUp()
        let backup = try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate())
        await service.set(stored: backup)
        await content.setJoined(backup.keyID)
        await model.load()
        #expect(model.phase == .ready(matrixCopy: true))
    }

    @Test("A device joined to an old backup is asked again, not treated as current")
    func staleJoinIsAskedAgain() async throws {
        let (model, service, content) = try setUp()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate()))
        await content.setJoined("0123456789abcdef0123456789abcdef")
        await model.load()
        #expect(model.phase == .needsKey)
    }
}

import Foundation
import Testing
import TotalityCore
@testable import TotalityAccount

actor FakeBackupService: KeyBackupService {
    var stored: KeyBackup?
    var account: String? = "user-1"
    var inSupabase = true
    var supabaseRestores = true
    var fetchError: AccountError?
    var saveError: AccountError?
    var matrixWorks = true
    /// Stands in for another device saving first.
    var raceWinner: KeyBackup?
    private(set) var matrixCopies: [KeyBackup] = []
    private(set) var supabaseRestoreCount = 0

    func set(stored: KeyBackup?, inSupabase: Bool = true) {
        self.stored = stored
        self.inSupabase = inSupabase
    }
    func set(account: String?) { self.account = account }
    func setSupabaseRestores(_ works: Bool) { supabaseRestores = works }
    func signedInAccountID() async -> String? { account }
    func fail(fetch: AccountError? = nil, save: AccountError? = nil) {
        fetchError = fetch
        saveError = save
    }
    func setMatrixWorks(_ works: Bool) { matrixWorks = works }
    func setRaceWinner(_ backup: KeyBackup) { raceWinner = backup }

    func fetchBackup() async throws -> FetchedBackup? {
        if let fetchError { throw fetchError }
        return stored.map { FetchedBackup(backup: $0, inSupabase: inSupabase) }
    }
    func saveBackup(_ backup: KeyBackup) async throws {
        if let saveError { throw saveError }
        if let raceWinner {
            stored = raceWinner
            throw AccountError.backupExists
        }
        stored = backup
    }
    func restoreSupabaseCopy(_ backup: KeyBackup) async -> Bool {
        supabaseRestoreCount += 1
        return supabaseRestores
    }
    func copyBackupToMatrix(_ backup: KeyBackup) async -> Bool {
        matrixCopies.append(backup)
        return matrixWorks
    }
}

actor FakeContentKeys: ContentKeyAccess {
    var key: ContentRootKey
    var joined: String?
    var owner: String?
    var sealedContent = false
    var settled = false
    private(set) var resets = 0
    var adoptError: Error?
    var report = KeyMoveReport(moved: 0, unreadable: 0)
    private(set) var adopted: [ContentRootKey] = []

    init(key: ContentRootKey) { self.key = key }
    func failAdopting() { adoptError = CryptoError.authenticationFailed }
    func setReport(_ report: KeyMoveReport) { self.report = report }
    func setJoined(_ fingerprint: String) { joined = fingerprint }
    func setOwner(_ owner: String) { self.owner = owner }
    func setSealedContent(_ present: Bool) { sealedContent = present }
    func setRootKeyMissing() { rootKeyMissing = true }

    private var rootKeyMissing = false
    func rootKey() async throws -> ContentRootKey {
        if rootKeyMissing { throw KeyStoreError.keyMissing }
        return key
    }
    func settleExistingInstall(signedInAccount: String?) async throws {
        guard !settled else { return }
        settled = true
        if owner == nil { owner = signedInAccount }
    }
    func hasSealedContent() async throws -> Bool { sealedContent }
    func reassign(to account: String, provenBy key: ContentRootKey) async throws {
        guard key == self.key else { throw ContentKeyError.keyDoesNotOpenContent }
        owner = account
    }
    func release(by account: String) async throws {
        guard owner == account else { throw ContentKeyError.otherAccount }
        guard joined == nil else { throw ContentKeyError.notAllowedNow }
        owner = nil
    }
    func resetEmptyDevice() async throws {
        guard !sealedContent else { throw ContentKeyError.notAllowedNow }
        resets += 1
        key = try ContentRootKey.generate()
        owner = nil
        joined = nil
    }
    func adopt(_ key: ContentRootKey) async throws -> KeyMoveReport {
        if let adoptError { throw adoptError }
        adopted.append(key)
        self.key = key
        return report
    }
    func keyOwner() async throws -> String? { owner }
    func claim(for account: String) async throws {
        if let owner, owner != account { throw ContentKeyError.otherAccount }
        owner = account
    }
    func joinedBackup() async throws -> String? { joined }
    func markJoined(_ fingerprint: String) async throws { joined = fingerprint }
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
        #expect(model.phase == .ready(BackupCopies(supabase: true, matrix: true)))
        let stored = try #require(await service.stored)
        #expect(try stored.open(with: RecoveryKey(encoded: key)) == (await content.key))
        #expect(await content.joined == stored.fingerprint)
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
        #expect(model.phase == .ready(BackupCopies(supabase: true, matrix: true)))
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
        #expect(model.phase == .ready(BackupCopies(supabase: true, matrix: false)))
        #expect(await service.stored != nil)
    }

    @Test("The Matrix copy is retried each time the screen opens")
    func matrixCopyRetries() async throws {
        let (model, service, content) = try setUp()
        let backup = try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate())
        await service.set(stored: backup)
        await content.setJoined(backup.fingerprint)
        await model.load()
        #expect(model.phase == .ready(BackupCopies(supabase: true, matrix: true)))
        #expect(await service.matrixCopies.count == 1)
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
        #expect(model.phase == .ready(BackupCopies(supabase: true, matrix: true)))
        #expect(await content.adopted == [shared])
        #expect(await content.joined == backup.fingerprint)
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
        await content.setJoined(backup.fingerprint)
        await model.load()
        #expect(model.phase == .ready(BackupCopies(supabase: true, matrix: true)))
    }

    @Test("A device joined to an old backup is asked again, not treated as current")
    func staleJoinIsAskedAgain() async throws {
        let (model, service, content) = try setUp()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate()))
        await content.setJoined("0123456789abcdef0123456789abcdef")
        await model.load()
        #expect(model.phase == .needsKey)
    }

    @Test("Another account can't lock this device's key into its own backup")
    func anotherAccountCannotTakeTheKey() async throws {
        let (model, service, content) = try setUp()
        await content.setSealedContent(true)
        await content.setOwner("user-1")
        await service.set(account: "user-2")
        await model.load()
        #expect(model.phase == .otherAccount)
        #expect(await service.stored == nil)
    }

    @Test("Even past the first check, a confirm for another account stores nothing")
    func confirmRefusesAnotherAccount() async throws {
        let (model, service, content) = try setUp()
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await content.setOwner("user-1")
        await service.set(account: "user-2")
        await model.confirm(key)
        #expect(model.phase == .otherAccount)
        #expect(await service.stored == nil)
    }

    @Test("Another account's recovery key can't move this device's content")
    func anotherAccountCannotMoveContent() async throws {
        let (model, service, content) = try setUp()
        let recovery = try RecoveryKey.generate()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: recovery))
        await model.load()
        await content.setOwner("user-1")
        await service.set(account: "user-2")
        await model.enter(recovery.encoded)
        #expect(model.phase == .otherAccount)
        #expect(await content.adopted.isEmpty)
    }

    @Test("Setting up ties the key to the signed-in account")
    func setupClaimsTheKey() async throws {
        let (model, _, content) = try setUp()
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await model.confirm(key)
        #expect(await content.owner == "user-1")
    }

    @Test("A swapped backup with the same ID isn't treated as joined, or pushed over the good copy")
    func swappedBackupIsNotTrusted() async throws {
        let (model, service, content) = try setUp()
        let recovery = try RecoveryKey.generate()
        let good = try KeyBackup.seal(try ContentRootKey.generate(), with: recovery)
        let other = try KeyBackup.seal(try ContentRootKey.generate(), with: recovery)
        await content.setJoined(good.fingerprint)
        await service.set(stored: KeyBackup(keyID: good.keyID, check: good.check, secret: other.secret))
        await model.load()
        #expect(model.phase == .needsKey)
        #expect(await service.matrixCopies.isEmpty)
    }

    @Test("A backup found only on Matrix is put back in Supabase, and the screen tells the truth if not")
    func missingSupabaseCopyIsRestored() async throws {
        let (model, service, content) = try setUp()
        let backup = try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate())
        await service.set(stored: backup, inSupabase: false)
        await content.setJoined(backup.fingerprint)
        await model.load()
        #expect(model.phase == .ready(BackupCopies(supabase: true, matrix: true)))
        #expect(await service.supabaseRestoreCount == 1)

        await service.setSupabaseRestores(false)
        await model.load()
        #expect(model.phase == .ready(BackupCopies(supabase: false, matrix: true)))
    }

    @Test("Leaving the screen drops an unconfirmed key")
    func leavingForgetsTheKey() async throws {
        let (model, _, _) = try setUp()
        model.begin()
        model.leave()
        model.showKeyAgain()
        #expect(model.phase == .checking)
    }

    @Test("An old install takes its signed-in account at launch, so a later sign-in can't claim it")
    func launchSettlesAnExistingInstall() async throws {
        let (model, service, content) = try setUp()
        await content.setSealedContent(true)
        await model.settleDevice()
        #expect(await content.owner == "user-1")
        await service.set(account: "user-2")
        await model.settleDevice()
        await model.load()
        #expect(model.phase == .otherAccount)
    }

    @Test("A fresh sign-in on a device with someone's content has to answer whether it's theirs")
    func unclaimedContentIsAskedAbout() async throws {
        let (model, service, content) = try setUp()
        await service.set(account: nil)
        await model.settleDevice()
        await content.setSealedContent(true)
        await service.set(account: "user-2")
        await model.accountSignedIn()
        #expect(await content.owner == nil)
        await model.load()
        #expect(model.phase == .confirmingOwnership)
    }

    @Test("Saying it isn't yours touches nothing")
    func decliningClaimsNothing() async throws {
        let (model, _, content) = try setUp()
        await content.setSealedContent(true)
        await model.load()
        model.declineOwnership()
        #expect(model.phase == .otherAccount)
        #expect(await content.owner == nil)
    }

    @Test("Saying it's yours carries on without claiming, because an answer can be wrong")
    func confirmingClaims() async throws {
        let (model, _, content) = try setUp()
        await content.setSealedContent(true)
        await model.load()
        await model.confirmOwnership()
        #expect(await content.owner == nil)
        #expect(model.phase == .notSetUp)
    }

    @Test("One account's yes doesn't carry over to the next account on this device")
    func ownershipAnswerBelongsToOneAccount() async throws {
        let (model, service, content) = try setUp()
        await content.setSealedContent(true)
        await model.load()
        await model.confirmOwnership()
        await service.set(account: "user-2")
        await model.load()
        #expect(model.phase == .confirmingOwnership)
    }

    @Test("Only the account that owns the device's key counts as its owner")
    func deviceOwner() async throws {
        let (model, service, content) = try setUp()
        var changes = 0
        model.onOwnerChanged = { changes += 1 }
        #expect(await model.deviceOwner() == nil)

        await model.accountSignedIn()
        #expect(changes == 1)
        #expect(await model.deviceOwner() == "user-1")

        await service.set(account: "user-2")
        #expect(await model.deviceOwner() == nil)
        await service.set(account: nil)
        await model.accountSignedOut()
        #expect(changes == 2)
        #expect(await model.deviceOwner() == nil)
        #expect(try await content.keyOwner() == "user-1")
    }

    @Test("An empty device simply belongs to whoever signs in")
    func emptyDeviceIsClaimedAtSignIn() async throws {
        let (model, _, content) = try setUp()
        await model.accountSignedIn()
        #expect(await content.owner == "user-1")
    }

    @Test("A device that already has an owner isn't reassigned by a sign-in")
    func signInDoesNotReassign() async throws {
        let (model, service, content) = try setUp()
        await content.setOwner("user-1")
        await service.set(account: "user-2")
        await model.accountSignedIn()
        #expect(await content.owner == "user-1")
    }

    @Test("A failed setup leaves no claim on the device")
    func failedSetupClaimsNothing() async throws {
        let (model, service, content) = try setUp()
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await service.fail(save: .offline)
        await model.confirm(key)
        #expect(await content.owner == nil)
    }

    @Test("Sealed content with no key can't claim the device either")
    func missingKeyClaimsNothing() async throws {
        let (model, _, content) = try setUp()
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await content.setRootKeyMissing()
        await model.confirm(key)
        #expect(await content.owner == nil)
    }

    @Test("A failed join leaves no claim on the device")
    func failedJoinClaimsNothing() async throws {
        let (model, service, content) = try setUp()
        let recovery = try RecoveryKey.generate()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: recovery))
        await content.failAdopting()
        await model.load()
        await model.enter(recovery.encoded)
        #expect(await content.owner == nil)
    }

    @Test("Joining a backup found only on Matrix puts the Supabase copy back")
    func joiningFromMatrixRestoresSupabase() async throws {
        let (model, service, _) = try setUp()
        let recovery = try RecoveryKey.generate()
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: recovery), inSupabase: false)
        await model.load()
        await model.enter(recovery.encoded)
        #expect(await service.supabaseRestoreCount == 1)
    }

    @Test("Signed out, nothing assumes anything")
    func signedOutIsUnavailable() async throws {
        let (model, service, _) = try setUp()
        await service.set(account: nil)
        await model.load()
        #expect(model.phase == .unavailable)
    }

    @Test("The wrong account on a device with content can prove it's theirs with their recovery key")
    func recoveryKeyReclaimsADevice() async throws {
        let (model, service, content) = try setUp()
        let recovery = try RecoveryKey.generate()
        let shared = await content.key
        let backup = try KeyBackup.seal(shared, with: recovery)
        await content.setOwner("test-account")
        await content.setSealedContent(true)
        await service.set(stored: backup)
        await model.load()
        #expect(model.phase == .otherAccount)
        #expect(model.canProveOwnership)
        await model.proveOwnership(recovery.encoded)
        #expect(await content.owner == "user-1")
        #expect(await content.joined == backup.fingerprint)
        #expect(model.phase == .ready(BackupCopies(supabase: true, matrix: true)))
    }

    @Test("A recovery key that doesn't open the content changes nothing")
    func wrongProofChangesNothing() async throws {
        let (model, service, content) = try setUp()
        let recovery = try RecoveryKey.generate()
        await content.setOwner("test-account")
        await content.setSealedContent(true)
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: recovery))
        await model.load()
        await model.proveOwnership(recovery.encoded)
        #expect(await content.owner == "test-account")
        #expect(await content.adopted.isEmpty)
        #expect(model.notice != nil)
    }

    @Test("A key that isn't this account's says so, and touches nothing")
    func strangerKeyIsRefusedByName() async throws {
        let (model, service, content) = try setUp()
        await content.setOwner("test-account")
        await content.setSealedContent(true)
        await service.set(stored: try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate()))
        await model.load()
        await model.proveOwnership(try RecoveryKey.generate().encoded)
        #expect(model.notice?.contains("not the recovery key") == true)
        #expect(await content.owner == "test-account")
    }

    @Test("Without a backup of its own, the other account has nothing to prove with")
    func noBackupNoProof() async throws {
        let (model, _, content) = try setUp()
        await content.setOwner("test-account")
        await content.setSealedContent(true)
        await model.load()
        #expect(model.phase == .otherAccount)
        #expect(!model.canProveOwnership)
    }

    @Test("An empty device passes to the next account with a new key")
    func emptyDevicePassesOn() async throws {
        let (model, _, content) = try setUp()
        let old = await content.key
        await content.setOwner("old-account")
        await model.load()
        #expect(model.phase == .notSetUp)
        #expect(await content.resets == 1)
        #expect(await content.key != old)
    }

    @Test("A device with content is never reset for a new account")
    func contentIsNeverReset() async throws {
        let (model, _, content) = try setUp()
        await content.setOwner("old-account")
        await content.setSealedContent(true)
        await model.load()
        #expect(await content.resets == 0)
    }

    @Test("An owner that never joined can release the device, and it asks again")
    func ownerCanRelease() async throws {
        let (model, _, content) = try setUp()
        await content.setOwner("user-1")
        await content.setSealedContent(true)
        await model.load()
        #expect(model.canRelease)
        await model.release()
        #expect(await content.owner == nil)
        #expect(model.phase == .confirmingOwnership)
    }

    @Test("Once joined, a device can't be released")
    func joinedDeviceCannotRelease() async throws {
        let (model, service, content) = try setUp()
        let backup = try KeyBackup.seal(try ContentRootKey.generate(), with: try RecoveryKey.generate())
        await content.setOwner("user-1")
        await service.set(stored: backup)
        await content.setJoined(backup.fingerprint)
        await model.load()
        #expect(!model.canRelease)
    }

    @Test("Signing in ends the first-launch rule, so a relaunch can't claim for this session")
    func signInEndsTheFirstLaunchRule() async throws {
        let (model, service, content) = try setUp()
        await content.setSealedContent(true)
        await service.set(account: "user-2")
        await model.accountSignedIn()
        await model.settleDevice()
        #expect(await content.owner == nil)
    }

    @Test("With content but no key, setup says so instead of offering a retry that can't work")
    func missingKeySaysSo() async throws {
        let (model, _, content) = try setUp()
        model.begin()
        let key = try shownKey(model)
        model.continueToConfirm()
        await content.setRootKeyMissing()
        await model.confirm(key)
        #expect(model.phase == .notSetUp)
        #expect(model.notice?.contains("not the key") == true)
    }
}

@Suite struct MatrixIDTests {
    @Test(arguments: ["", "a b", "../../evil", String(repeating: "G", count: 32), String(repeating: "A", count: 32), String(repeating: "a", count: 31)])
    func refusesBadIDs(id: String) {
        #expect(!MatrixSession.isValidID(id))
    }

    @Test func acceptsARealID() {
        #expect(MatrixSession.isValidID(String(repeating: "a", count: 32)))
    }
}

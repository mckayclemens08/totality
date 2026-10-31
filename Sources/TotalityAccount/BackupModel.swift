import Foundation
import Observation
import TotalityCore

/// Which servers hold a locked copy of the key.
public struct BackupCopies: Equatable, Sendable {
    public let supabase: Bool
    public let matrix: Bool

    public init(supabase: Bool, matrix: Bool) {
        self.supabase = supabase
        self.matrix = matrix
    }
}

/// The recovery key ceremony and joining a device to it. A new recovery key lives only in memory here,
/// only until it's been typed back, and the app never writes it anywhere.
@MainActor
@Observable
public final class BackupModel {
    public enum Phase: Equatable {
        case checking
        /// The backup couldn't be checked, so nothing can safely be assumed either way.
        case unavailable
        case notSetUp
        case showingKey(String)
        case confirmingKey
        case working
        case needsKey
        /// Sealed content is here and no account owns it, so the person has to say whether it's theirs.
        case confirmingOwnership
        /// This device's content belongs to a different account, so nothing here can be touched.
        case otherAccount
        case ready(BackupCopies)
    }

    public private(set) var phase = Phase.checking
    public var notice: String?
    /// True when this account owns the device and can still give it up.
    public private(set) var canRelease = false
    /// True on the other-account screen when this account has a recovery key to prove the content with.
    public private(set) var canProveOwnership = false
    /// Called once this device has joined, so sync can start.
    public var onJoined: (() async -> Void)?

    private let service: any KeyBackupService
    private let content: any ContentKeyAccess
    private var newKey: RecoveryKey?
    private var existing: FetchedBackup?
    /// Which account said the content here is theirs. A "yes" proves nothing, so it's held only in
    /// memory, the claim waits until setup or joining succeeds, and it never carries over to anyone else.
    private var ownershipConfirmedBy: String?

    public init(service: any KeyBackupService, content: any ContentKeyAccess) {
        self.service = service
        self.content = content
    }

    /// At launch, before anything else can sign in. Old installs get their owner here, once.
    public func settleDevice() async {
        try? await content.settleExistingInstall(signedInAccount: await service.signedInAccountID())
    }

    /// After a sign-in. An empty device simply belongs to whoever arrived. A device with content
    /// doesn't, because that content could be someone else's, so `load` asks. Either way this ends the
    /// first-launch rule, so a later launch can't mistake this session for an old install's.
    public func accountSignedIn() async {
        guard let account = await service.signedInAccountID() else { return }
        do {
            try await content.settleExistingInstall(signedInAccount: nil)
            guard try await content.keyOwner() == nil, try await !content.hasSealedContent() else { return }
            try await content.claim(for: account)
        } catch {
            // Nothing is claimed, so `load` falls back to asking.
        }
    }

    /// Whether this device may sync: it has to belong to the signed-in account and have joined.
    public func deviceCanSync() async -> Bool {
        guard let account = await service.signedInAccountID(),
              let owner = try? await content.keyOwner(), owner == account,
              let joined = try? await content.joinedBackup()
        else { return false }
        return !joined.isEmpty
    }

    public func load() async {
        phase = .checking
        notice = nil
        newKey = nil
        do {
            guard let account = await service.signedInAccountID() else {
                phase = .unavailable
                return
            }
            canRelease = false
            canProveOwnership = false
            let hasContent = try await content.hasSealedContent()
            if let owner = try await content.keyOwner(), owner != account {
                if hasContent {
                    existing = try? await service.fetchBackup()
                    canProveOwnership = existing != nil
                    phase = .otherAccount
                    return
                }
                // Nothing here to protect, so the device passes on with a key of its own.
                try await content.resetEmptyDevice()
            } else if try await content.keyOwner() == account {
                canRelease = try await content.joinedBackup() == nil
            } else if ownershipConfirmedBy != account, hasContent {
                phase = .confirmingOwnership
                return
            }
            guard let fetched = try await service.fetchBackup() else {
                existing = nil
                phase = .notSetUp
                return
            }
            existing = fetched
            // The whole backup is compared, not its ID, so a swapped copy never counts as this one and
            // never gets pushed over the good copy on the other server.
            if try await content.joinedBackup() == fetched.backup.fingerprint {
                phase = .ready(await copies(of: fetched))
            } else {
                phase = .needsKey
            }
        } catch {
            phase = .unavailable
        }
    }

    /// Lets the screen carry on. Nothing is written, because an answer can be wrong.
    public func confirmOwnership() async {
        ownershipConfirmedBy = await service.signedInAccountID()
        await load()
    }

    public func declineOwnership() {
        canProveOwnership = false
        phase = .otherAccount
    }

    /// For a device claimed by the wrong account. Sign in with the right one afterwards.
    public func release() async {
        do {
            guard let account = await service.signedInAccountID() else { return }
            try await content.release(by: account)
            ownershipConfirmedBy = nil
            await load()
        } catch {
            notice = "This device couldn't be released."
        }
    }

    /// A recovery key that opens the content here proves it's this account's, whoever claimed it first.
    public func proveOwnership(_ typed: String) async {
        guard let existing, let account = await service.signedInAccountID() else { return }
        guard let recovery = try? RecoveryKey(encoded: typed), existing.backup.opens(with: recovery) else {
            notice = "That's not the recovery key for this account."
            return
        }
        do {
            try await content.reassign(to: account, provenBy: try existing.backup.open(with: recovery))
            ownershipConfirmedBy = account
            await enter(typed)
        } catch {
            notice = "That recovery key doesn't open what's on this device, so it stays as it is."
        }
    }

    private func copies(of fetched: FetchedBackup) async -> BackupCopies {
        let supabase = fetched.inSupabase ? true : await service.restoreSupabaseCopy(fetched.backup)
        return BackupCopies(supabase: supabase, matrix: await service.copyBackupToMatrix(fetched.backup))
    }

    public func begin() {
        do {
            let key = try RecoveryKey.generate()
            newKey = key
            notice = nil
            phase = .showingKey(key.encoded)
        } catch {
            notice = "A recovery key couldn't be made. Try again."
        }
    }

    public func continueToConfirm() {
        notice = nil
        phase = .confirmingKey
    }

    public func showKeyAgain() {
        guard let newKey else { return }
        notice = nil
        phase = .showingKey(newKey.encoded)
    }

    public func cancel() {
        newKey = nil
        notice = nil
        phase = .notSetUp
    }

    /// Leaving the screen drops a key that was never confirmed, so it isn't left in memory.
    public func leave() {
        guard newKey != nil else { return }
        newKey = nil
        notice = nil
        phase = .checking
    }

    /// Nothing is stored until the person has proved they have the key, so a mistake here can't leave
    /// a backup that nobody can open.
    public func confirm(_ typed: String) async {
        guard let newKey else { return }
        guard let entered = try? RecoveryKey(encoded: typed), entered == newKey else {
            notice = "That doesn't match. Check each character, or look at the key again."
            return
        }
        phase = .working
        do {
            let account = try await requireOwnership()
            let backup = try KeyBackup.seal(try await content.rootKey(), with: newKey)
            try await service.saveBackup(backup)
            // Claimed only now, so a failed attempt leaves no mark on the device.
            try await content.claim(for: account)
            try await content.markJoined(backup.fingerprint)
            self.newKey = nil
            existing = FetchedBackup(backup: backup, inSupabase: true)
            phase = .ready(await copies(of: FetchedBackup(backup: backup, inSupabase: true)))
            await onJoined?()
        } catch ContentKeyError.otherAccount {
            self.newKey = nil
            phase = .otherAccount
        } catch KeyStoreError.keyMissing {
            self.newKey = nil
            phase = .notSetUp
            notice = "This device has encrypted content but not the key that opens it, so it can't start a new recovery key."
        } catch AccountError.backupExists {
            // Another device finished first. Its key is the one that counts.
            await load()
            notice = "Your account already has a recovery key. Enter that one instead."
        } catch let error as AccountError {
            phase = .confirmingKey
            notice = error.message
        } catch {
            phase = .confirmingKey
            notice = "Your backup may not have saved. Try again."
        }
    }

    /// Checks without writing anything, so nothing is claimed by an attempt that goes on to fail.
    private func requireOwnership() async throws -> String {
        guard let account = await service.signedInAccountID() else { throw AccountError.failed }
        if let owner = try await content.keyOwner(), owner != account { throw ContentKeyError.otherAccount }
        return account
    }

    /// Joins this device, moving anything sealed under its old key. It can take a while.
    public func enter(_ typed: String) async {
        guard let existing else { return }
        guard let recovery = try? RecoveryKey(encoded: typed) else {
            notice = "That isn't a recovery key. Check each character."
            return
        }
        guard existing.backup.opens(with: recovery) else {
            notice = "That's not the recovery key for this account."
            return
        }
        phase = .working
        do {
            let account = try await requireOwnership()
            let report = try await content.adopt(try existing.backup.open(with: recovery))
            try await content.claim(for: account)
            try await content.markJoined(existing.backup.fingerprint)
            phase = .ready(await copies(of: existing))
            if report.unreadable > 0 {
                notice = "\(report.unreadable) items can't be opened with this key. They're untouched."
            }
            await onJoined?()
        } catch ContentKeyError.otherAccount {
            phase = .otherAccount
        } catch ContentKeyError.keyDoesNotOpenContent {
            phase = .needsKey
            notice = "This recovery key doesn't open what's on this device. Nothing was changed."
        } catch {
            phase = .needsKey
            notice = "This device didn't finish joining, but nothing was lost. Try again."
        }
    }
}

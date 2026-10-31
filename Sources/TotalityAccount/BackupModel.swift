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
        /// This device's content belongs to a different account, so nothing here can be touched.
        case otherAccount
        case ready(BackupCopies)
    }

    public private(set) var phase = Phase.checking
    public var notice: String?

    private let service: any KeyBackupService
    private let content: any ContentKeyAccess
    private var newKey: RecoveryKey?
    private var existing: KeyBackup?

    public init(service: any KeyBackupService, content: any ContentKeyAccess) {
        self.service = service
        self.content = content
    }

    public func load() async {
        phase = .checking
        notice = nil
        newKey = nil
        do {
            let account = try await service.accountID()
            if let owner = try await content.keyOwner(), owner != account {
                phase = .otherAccount
                return
            }
            guard let fetched = try await service.fetchBackup() else {
                existing = nil
                phase = .notSetUp
                return
            }
            existing = fetched.backup
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
            // Claiming comes first, so another account's key can never be locked into this backup.
            try await content.claim(for: try await service.accountID())
            let backup = try KeyBackup.seal(try await content.rootKey(), with: newKey)
            try await service.saveBackup(backup)
            try await content.markJoined(backup.fingerprint)
            self.newKey = nil
            existing = backup
            phase = .ready(await copies(of: FetchedBackup(backup: backup, inSupabase: true)))
        } catch ContentKeyError.otherAccount {
            self.newKey = nil
            phase = .otherAccount
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

    /// Joins this device, moving anything sealed under its old key. It can take a while.
    public func enter(_ typed: String) async {
        guard let existing else { return }
        guard let recovery = try? RecoveryKey(encoded: typed) else {
            notice = "That isn't a recovery key. Check each character."
            return
        }
        guard existing.opens(with: recovery) else {
            notice = "That's not the recovery key for this account."
            return
        }
        phase = .working
        do {
            try await content.claim(for: try await service.accountID())
            let report = try await content.adopt(try existing.open(with: recovery))
            try await content.markJoined(existing.fingerprint)
            phase = .ready(await copies(of: FetchedBackup(backup: existing, inSupabase: true)))
            if report.unreadable > 0 {
                notice = "\(report.unreadable) items couldn't be opened, so they weren't moved. They're untouched."
            }
        } catch ContentKeyError.otherAccount {
            phase = .otherAccount
        } catch {
            phase = .needsKey
            notice = "This device didn't finish joining, but nothing was lost. Try again."
        }
    }
}

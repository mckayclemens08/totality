import Foundation
import Observation
import TotalityCore

/// The recovery key ceremony and joining a device to it. A new recovery key lives only in memory here,
/// only until it's been typed back, and is never written anywhere.
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
        /// `matrixCopy` is false when only Supabase holds the backup so far.
        case ready(matrixCopy: Bool)
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
            existing = try await service.fetchBackup()
            guard let existing else {
                phase = .notSetUp
                return
            }
            if try await content.joinedBackupID() == existing.keyID {
                phase = .ready(matrixCopy: await service.copyBackupToMatrix(existing))
            } else {
                phase = .needsKey
            }
        } catch {
            phase = .unavailable
        }
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
            let backup = try KeyBackup.seal(try await content.rootKey(), with: newKey)
            try await service.saveBackup(backup)
            try await content.markJoined(backup.keyID)
            self.newKey = nil
            existing = backup
            phase = .ready(matrixCopy: await service.copyBackupToMatrix(backup))
        } catch AccountError.backupExists {
            // Another device finished first. Its key is the one that counts.
            await load()
            notice = "Your account already has a recovery key. Enter that one instead."
        } catch let error as AccountError {
            phase = .confirmingKey
            notice = error.message
        } catch {
            phase = .confirmingKey
            notice = "Your backup wasn't saved. Try again."
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
            let report = try await content.adopt(try existing.open(with: recovery))
            try await content.markJoined(existing.keyID)
            phase = .ready(matrixCopy: await service.copyBackupToMatrix(existing))
            if report.unreadable > 0 {
                notice = "\(report.unreadable) items couldn't be moved. They're untouched, and this device kept its old key in case they can be opened later."
            }
        } catch {
            phase = .needsKey
            notice = "This device didn't finish joining, but nothing was lost. Try again."
        }
    }
}

import Foundation
import Observation
import TotalityCore

/// When sync runs and how it went. Only one runs at a time, and a key move waits for it to stop,
/// because sync reads and writes the same sealed files.
@MainActor
@Observable
public final class SyncModel {
    public enum Status: Equatable {
        case idle
        case syncing
        case failed
    }

    /// Supabase's free plan.
    public static let storageLimit = 1_073_741_824
    private static let warningShare = 0.8

    public private(set) var status = Status.idle
    public private(set) var lastSynced: Date?
    public private(set) var lastReport: SyncReport?

    /// The app supplies this once content is open. It returns nil when this device can't sync yet.
    public var run: (@MainActor () async throws -> SyncReport?)?
    /// Called when a sync changed something here, so screens can reload.
    public var onChanged: (@MainActor () async -> Void)?

    private var current: Task<Void, Never>?
    private var isPaused = false

    public init() {}

    public var isNearlyFull: Bool {
        guard let lastReport else { return false }
        return Double(lastReport.byteCount) >= Double(Self.storageLimit) * Self.warningShare
    }

    /// A plain statement for the settings screen, or nil if there's nothing to say yet.
    public var summary: String? {
        guard let lastSynced else {
            return status == .syncing ? "Syncing." : nil
        }
        var text = "Last synced \(lastSynced.formatted(.relative(presentation: .named)))."
        if let lastReport {
            if lastReport.failed > 0 {
                text += " \(lastReport.failed) items didn't sync. They're safe here and will be tried again."
            }
            if lastReport.rejected > 0 {
                text += " \(lastReport.rejected) items from the server couldn't be opened, so they were ignored."
            }
        }
        if isNearlyFull { text += " Your free storage is over 80% full." }
        return text
    }

    public func syncNow() async {
        if let current {
            await current.value
            return
        }
        guard !isPaused, let run else { return }
        status = .syncing
        let task = Task { @MainActor in
            do {
                guard let report = try await run() else {
                    status = .idle
                    return
                }
                lastReport = report
                lastSynced = Date()
                status = report.failed > 0 ? .failed : .idle
                if report.changedThisDevice { await onChanged?() }
            } catch {
                status = .failed
            }
        }
        current = task
        await task.value
        current = nil
    }

    /// Stops new runs and waits for one in progress, so a key move has the files to itself.
    public func pause() async {
        isPaused = true
        await current?.value
    }

    public func resume() {
        isPaused = false
    }
}

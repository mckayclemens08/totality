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

    private static let lastSuccessKey = "sync.lastSuccess"

    public private(set) var status = Status.idle
    public private(set) var lastSynced: Date?
    public private(set) var lastReport: SyncReport?
    /// True once this device can sync at all, which is when its status is worth showing.
    public private(set) var isAvailable = false

    /// The app supplies this once content is open. It's told whether a large removal has been agreed,
    /// and it returns nil when this device can't sync yet.
    public var run: (@MainActor (_ allowLargeRemoval: Bool) async throws -> SyncReport?)?
    /// Called when a sync changed something here, so screens can reload.
    public var onChanged: (@MainActor () async -> Void)?
    /// Called after every run, so screens can say what's now true.
    public var onFinished: (@MainActor () -> Void)?

    private var current: Task<Void, Never>?
    private var isPaused = false
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastSynced = defaults.object(forKey: Self.lastSuccessKey) as? Date
    }

    public var isNearlyFull: Bool {
        guard let lastReport else { return false }
        return Double(lastReport.byteCount) >= Double(Self.storageLimit) * Self.warningShare
    }

    /// True only when a sync has really finished cleanly, so a label can claim the content is safe.
    public var isProtected: Bool {
        guard isAvailable, lastSynced != nil, status != .failed else { return false }
        return (lastReport?.failed ?? 0) == 0 && (lastReport?.rejected ?? 0) == 0
    }

    public var heldRemovals: Int {
        lastReport?.heldRemovals ?? 0
    }

    /// A plain statement for the settings screen, or nil if there's nothing to say yet.
    public var summary: String? {
        guard isAvailable else { return nil }
        if status == .syncing { return "Syncing." }
        var text = lastSynced.map { "Last synced \($0.formatted(.relative(presentation: .named)))." } ?? "This device hasn't finished a sync yet."
        if status == .failed, (lastReport?.failed ?? 0) == 0 {
            text += " The last sync didn't finish. Your content is safe here, and it will try again."
        }
        if let lastReport {
            if lastReport.failed > 0 {
                text += " \(lastReport.failed) items didn't sync. They're safe here and will be tried again."
            }
            if lastReport.rejected > 0 {
                text += " \(lastReport.rejected) items couldn't be opened, so they were left as they are."
            }
            if lastReport.heldRemovals > 0 {
                text += " \(lastReport.heldRemovals) items were deleted somewhere else. They stay here until you agree."
            }
        }
        if isNearlyFull { text += " Your free storage is over 80% full." }
        return text
    }

    public func syncNow() async {
        await perform(allowLargeRemoval: false)
    }

    /// The person agreed that the items deleted elsewhere should go here too.
    public func applyHeldRemovals() async {
        await perform(allowLargeRemoval: true)
    }

    private func perform(allowLargeRemoval: Bool) async {
        if let current {
            await current.value
            return
        }
        guard !isPaused, let run else { return }
        status = .syncing
        let task = Task { @MainActor in
            do {
                guard let report = try await run(allowLargeRemoval) else {
                    isAvailable = false
                    status = .idle
                    return
                }
                isAvailable = true
                lastReport = report
                status = report.failed > 0 ? .failed : .idle
                if report.failed == 0, report.rejected == 0 {
                    let now = Date()
                    lastSynced = now
                    defaults.set(now, forKey: Self.lastSuccessKey)
                }
                if report.changedThisDevice { await onChanged?() }
            } catch {
                isAvailable = true
                status = .failed
            }
        }
        current = task
        await task.value
        current = nil
        onFinished?()
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

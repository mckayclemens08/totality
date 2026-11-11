import Foundation
import TotalityCore

/// iPhone sync (issue 77): off until the person turns it on, then whenever Photos opens and when iOS
/// gives background time. Each item is sealed on the device before it uploads, like everything else.
extension PhotosModel {
    public var canSync: Bool { librarySync != nil }
    public var isSyncing: Bool { syncTask != nil }

    func loadSync() async {
        guard let librarySync else { return }
        syncRecord = try? await librarySync.record()
    }

    /// Turns sync on from today, or off. Turning it off keeps what it brought, and remembers it, so
    /// turning it back on never brings anything twice.
    public func setSync(on: Bool, now: Date = Date()) async {
        await changeSync { record in
            // "From today on" means the day it's turned on, each time: nothing taken while it was off comes in.
            if on, !record.isOn { record.start = now }
            record.isOn = on
        }
        if on {
            startSync()
        } else {
            stopSync()
            try? await librarySync?.library.removeSyncRecordIfUnused()
        }
    }

    public func setSyncVideos(_ on: Bool) async {
        await changeSync { $0.videos = on }
        startSync()
    }

    public func setSyncMobileData(_ on: Bool) async {
        await changeSync { $0.mobileData = on }
        startSync()
    }

    /// Brings in an earlier month too, or stops bringing it. What's already in stays.
    public func setSyncMonth(_ month: String, included: Bool) async {
        await changeSync { record in
            if included { record.months.insert(month) } else { record.months.remove(month) }
        }
        startSync()
    }

    /// The device's months, newest first, with how many items each, for choosing earlier ones.
    public func syncMonths() async -> [(id: String, count: Int)] {
        await librarySync?.months() ?? []
    }

    private func changeSync(_ change: @Sendable (inout SyncRecord) -> Void) async {
        guard let librarySync else { return }
        do {
            syncRecord = try await librarySync.change(change)
        } catch {
            notice = "Sync settings couldn't be saved on this device. Try again."
        }
    }

    /// Starts a run unless one is going. Safe to call whenever.
    func startSync() {
        guard syncRecord?.isOn == true, syncTask == nil else { return }
        syncTask = Task { [weak self] in
            await self?.runSyncNow()
            self?.syncTask = nil
        }
    }

    /// Stops the run going now after the item it's on, which is sealed and kept.
    public func stopSync() {
        syncTask?.cancel()
    }

    /// What iOS's background time runs. Waits for a run already going instead of starting a second.
    public func runSync() async {
        if syncRecord == nil { await loadSync() }
        if let running = syncTask {
            await running.value
            return
        }
        startSync()
        await syncTask?.value
    }

    private func runSyncNow() async {
        guard let librarySync else { return }
        let background = BackgroundTime.begin()
        defer { background.end() }
        let report = await librarySync.run(network: { await NetworkCheck.isOnWiFi() }) { [weak self] done, total in
            await MainActor.run { self?.syncProgress = (done, total) }
        }
        syncProgress = nil
        syncReport = report
        syncRecord = try? await librarySync.record()
        if report.full { isFull = true }
        if report.brought > 0 { await refreshAfterSync() }
        SyncSchedule.ask()
    }

    /// The line under the library about sync, or nil when it's off.
    public var syncLine: String? {
        guard let record = syncRecord, record.isOn else { return nil }
        if let progress = syncProgress {
            return "Syncing this iPhone: \(progress.done.formatted()) of \(progress.total.formatted())"
        }
        return Self.syncLine(syncReport)
    }

    nonisolated static func syncLine(_ report: SyncReport?) -> String? {
        guard let report else { return nil }
        func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count.formatted()) items" }
        func are(_ count: Int) -> String { count == 1 ? "is" : "are" }
        var parts: [String] = []
        if report.full {
            parts.append("Sync stopped because your space is full. \(items(report.remaining)) \(are(report.remaining)) still on this iPhone only.")
        } else if report.offline, report.remaining > 0 {
            parts.append("\(items(report.remaining)) will sync on Wi-Fi.")
        } else if report.remaining == 0 {
            parts.append("This iPhone is synced.")
        } else if report.waitingForWiFi > 0 {
            parts.append("\(items(report.waitingForWiFi)) \(are(report.waitingForWiFi)) only in iCloud and will sync on Wi-Fi.")
        } else {
            parts.append("\(items(report.remaining)) still to sync.")
        }
        if report.cantTake > 0 {
            parts.append(report.cantTake == 1 ? "One item can't be synced, because it's over 10 minutes or 4 GB, or can't be read."
                : "\(report.cantTake.formatted()) items can't be synced, because they're over 10 minutes or 4 GB, or can't be read.")
        }
        return parts.joined(separator: " ")
    }
}

extension LibrarySync {
    func record() async throws -> SyncRecord {
        try await library.syncRecord()
    }

    func change(_ change: @Sendable (inout SyncRecord) -> Void) async throws -> SyncRecord {
        try await library.updateSyncRecord(change)
    }
}

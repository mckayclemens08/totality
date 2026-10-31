import Foundation
import Testing
import TotalityCore
@testable import TotalityAccount

@MainActor
@Suite struct SyncModelTests {
    private func report(_ change: (inout SyncReport) -> Void = { _ in }) -> SyncReport {
        var report = SyncReport()
        change(&report)
        return report
    }

    private func fresh() -> SyncModel {
        SyncModel(defaults: UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!)
    }

    @Test("Protected means a sync really finished cleanly, not just that the device joined")
    func protectionMustBeEarned() async {
        let model = fresh()
        #expect(!model.isProtected)
        model.run = { _ in self.report { $0.failed = 1 } }
        await model.syncNow()
        #expect(!model.isProtected)
        model.run = { _ in throw URLError(.notConnectedToInternet) }
        await model.syncNow()
        #expect(!model.isProtected)
        model.run = { _ in self.report() }
        await model.syncNow()
        #expect(model.isProtected)
    }

    @Test("A sync that stops partway takes back what a clean one earlier said")
    func aThrownRunEndsProtection() async {
        let model = fresh()
        model.run = { _ in self.report() }
        await model.syncNow()
        #expect(model.isProtected)
        model.run = { _ in throw URLError(.notConnectedToInternet) }
        await model.syncNow()
        #expect(!model.isProtected)
    }

    @Test("A run with failures doesn't count as the last good sync")
    func failuresDoNotMoveLastSynced() async {
        let model = fresh()
        model.run = { _ in self.report { $0.failed = 1 } }
        await model.syncNow()
        model.run = { _ in self.report { $0.rejected = 1 } }
        await model.syncNow()
        #expect(model.lastSynced == nil)
    }

    @Test("After sign-out it claims nothing, tells the screens, and keeps nothing for the next person")
    func signingOutForgets() async {
        let defaults = UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!
        let model = SyncModel(defaults: defaults)
        var refreshed = 0
        model.onFinished = { refreshed += 1 }
        model.run = { _ in self.report() }
        await model.syncNow()
        #expect(model.isProtected)
        let before = refreshed
        model.forget()
        #expect(!model.isProtected)
        #expect(model.summary == nil)
        #expect(refreshed == before + 1)
        #expect(SyncModel(defaults: defaults).lastSynced == nil)
    }

    @Test("The account stops sync and clears it when someone signs out")
    func accountSignOutClearsSync() async {
        let sync = fresh()
        sync.run = { _ in self.report() }
        let account = AccountModel(service: FakeAccountService(username: "wren"), sync: sync)
        await account.load()
        await sync.syncNow()
        #expect(sync.isProtected)
        await account.signOut()
        #expect(!sync.isProtected)
        await sync.syncNow()
        #expect(sync.isProtected)
    }

    @Test("Signing out cuts a run short instead of waiting for it")
    func signOutCancelsARun() async {
        let model = fresh()
        var wasCancelled = false
        model.run = { _ in
            while !Task.isCancelled { await Task.yield() }
            wasCancelled = true
            return self.report()
        }
        let running = Task { await model.syncNow() }
        await Task.yield()
        await Task.yield()
        await model.stopForSignOut()
        await running.value
        #expect(wasCancelled)
    }

    @Test("A sync that keeps failing still says so, instead of showing nothing")
    func neverSyncedStillReports() async {
        let model = fresh()
        model.run = { _ in throw URLError(.notConnectedToInternet) }
        await model.syncNow()
        #expect(model.summary?.contains("hasn't finished") == true)
    }

    @Test("Signed out, it can't claim anything")
    func notAvailableClaimsNothing() async {
        let model = fresh()
        model.run = { _ in self.report() }
        await model.syncNow()
        model.run = { _ in nil }
        await model.syncNow()
        #expect(!model.isProtected)
        #expect(model.summary == nil)
    }

    @Test("Held removals are said out loud, and agreeing passes that on")
    func heldRemovals() async {
        let model = fresh()
        var allowed: [Bool] = []
        model.run = { allow in
            allowed.append(allow)
            return self.report { $0.heldRemovals = allow ? 0 : 20 }
        }
        await model.syncNow()
        #expect(model.heldRemovals == 20)
        #expect(model.summary?.contains("20 items were deleted") == true)
        await model.applyHeldRemovals()
        #expect(allowed == [false, true])
        #expect(model.heldRemovals == 0)
    }

    @Test func aRunRecordsWhenItFinished() async {
        let model = fresh()
        model.run = { _ in self.report() }
        await model.syncNow()
        #expect(model.lastSynced != nil)
        #expect(model.status == .idle)
    }

    @Test("A device that can't sync yet changes nothing")
    func nilMeansNotYet() async {
        let model = fresh()
        model.run = { _ in nil }
        await model.syncNow()
        #expect(model.lastSynced == nil)
        #expect(model.summary == nil)
    }

    @Test func aFailureIsShown() async {
        let model = fresh()
        model.run = { _ in throw URLError(.notConnectedToInternet) }
        await model.syncNow()
        #expect(model.status == .failed)
    }

    @Test("Items that didn't sync are reported, not hidden")
    func partialFailuresAreSaid() async {
        let model = fresh()
        model.run = { _ in self.report { $0.failed = 2; $0.rejected = 1 } }
        await model.syncNow()
        #expect(model.status == .failed)
        #expect(model.summary?.contains("2 items didn't sync") == true)
        #expect(model.summary?.contains("1 items couldn't be opened") == true)
    }

    @Test("Screens reload only when something here changed")
    func reloadsOnlyOnChange() async {
        let model = fresh()
        var reloads = 0
        model.onChanged = { reloads += 1 }
        model.run = { _ in self.report { $0.uploaded = 3 } }
        await model.syncNow()
        #expect(reloads == 0)
        model.run = { _ in self.report { $0.downloaded = 1 } }
        await model.syncNow()
        #expect(reloads == 1)
    }

    @Test("A key move waits for a running sync, and nothing starts until it's done")
    func pauseWaitsAndBlocks() async {
        let model = fresh()
        var runs = 0
        var release: CheckedContinuation<Void, Never>?
        model.run = { _ in
            runs += 1
            await withCheckedContinuation { release = $0 }
            return self.report()
        }
        let first = Task { await model.syncNow() }
        while release == nil { await Task.yield() }
        var paused = false
        let pausing = Task {
            await model.pause()
            paused = true
        }
        await Task.yield()
        #expect(!paused)
        release?.resume()
        await pausing.value
        await first.value
        #expect(paused)
        await model.syncNow()
        #expect(runs == 1)
        model.resume()
        model.run = { _ in self.report() }
        await model.syncNow()
        #expect(model.lastReport != nil)
    }

    @Test("Two requests at once run once")
    func onlyOneAtATime() async {
        let model = fresh()
        var runs = 0
        model.run = { _ in
            runs += 1
            await Task.yield()
            return self.report()
        }
        async let one: Void = model.syncNow()
        async let two: Void = model.syncNow()
        _ = await (one, two)
        #expect(runs == 1)
    }

    @Test("It warns at 80% of the free storage")
    func warnsWhenNearlyFull() async {
        let model = fresh()
        model.run = { _ in self.report { $0.byteCount = 800_000_000 } }
        await model.syncNow()
        #expect(!model.isNearlyFull)
        model.run = { _ in self.report { $0.byteCount = 860_000_000 } }
        await model.syncNow()
        #expect(model.isNearlyFull)
        #expect(model.summary?.contains("80%") == true)
    }
}

@Suite struct SyncRemoteFormatTests {
    @Test("Bytes survive the database's text format")
    func bytesRoundTrip() {
        let data = Data([0, 1, 255, 16])
        #expect(SupabaseSyncRemote.literal(data) == "\\x0001ff10")
        #expect(SupabaseSyncRemote.bytes("\\x0001ff10") == data)
    }

    @Test(arguments: ["0001", "\\x0", "\\xzz"])
    func refusesWhatIsNotBytes(text: String) {
        #expect(SupabaseSyncRemote.bytes(text) == nil)
    }
}

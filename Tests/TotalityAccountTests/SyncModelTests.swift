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

    @Test func aRunRecordsWhenItFinished() async {
        let model = SyncModel()
        model.run = { self.report() }
        await model.syncNow()
        #expect(model.lastSynced != nil)
        #expect(model.status == .idle)
    }

    @Test("A device that can't sync yet changes nothing")
    func nilMeansNotYet() async {
        let model = SyncModel()
        model.run = { nil }
        await model.syncNow()
        #expect(model.lastSynced == nil)
        #expect(model.summary == nil)
    }

    @Test func aFailureIsShown() async {
        let model = SyncModel()
        model.run = { throw URLError(.notConnectedToInternet) }
        await model.syncNow()
        #expect(model.status == .failed)
    }

    @Test("Items that didn't sync are reported, not hidden")
    func partialFailuresAreSaid() async {
        let model = SyncModel()
        model.run = { self.report { $0.failed = 2; $0.rejected = 1 } }
        await model.syncNow()
        #expect(model.status == .failed)
        #expect(model.summary?.contains("2 items didn't sync") == true)
        #expect(model.summary?.contains("1 items from the server") == true)
    }

    @Test("Screens reload only when something here changed")
    func reloadsOnlyOnChange() async {
        let model = SyncModel()
        var reloads = 0
        model.onChanged = { reloads += 1 }
        model.run = { self.report { $0.uploaded = 3 } }
        await model.syncNow()
        #expect(reloads == 0)
        model.run = { self.report { $0.downloaded = 1 } }
        await model.syncNow()
        #expect(reloads == 1)
    }

    @Test("A key move waits for a running sync, and nothing starts until it's done")
    func pauseWaitsAndBlocks() async {
        let model = SyncModel()
        var runs = 0
        var release: CheckedContinuation<Void, Never>?
        model.run = {
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
        model.run = { self.report() }
        await model.syncNow()
        #expect(model.lastReport != nil)
    }

    @Test("Two requests at once run once")
    func onlyOneAtATime() async {
        let model = SyncModel()
        var runs = 0
        model.run = {
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
        let model = SyncModel()
        model.run = { self.report { $0.byteCount = 800_000_000 } }
        await model.syncNow()
        #expect(!model.isNearlyFull)
        model.run = { self.report { $0.byteCount = 860_000_000 } }
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

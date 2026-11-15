import Foundation
import Testing
@testable import TotalityCore

private let gigabyte = 1_000_000_000

/// Stands in for the server: answers what it's told to, and counts how often it was asked.
private final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Result<StorageQuota, Error>
    private var mailAnswer: Result<StorageQuota, Error>
    private var asked = 0
    var account: String? = "8b3c1f0e-2d4a-4c6b-9e8f-0a1b2c3d4e5f"

    init(_ sealed: StorageQuota, mail: StorageQuota = StorageQuota(used: 120_000_000, limit: gigabyte)) {
        answer = .success(sealed)
        mailAnswer = .success(mail)
    }

    var reads: Int { lock.withLock { asked } }
    func answer(_ result: Result<StorageQuota, Error>) { lock.withLock { answer = result } }
    func answerMail(_ result: Result<StorageQuota, Error>) { lock.withLock { mailAnswer = result } }

    func sources(parts: [StoragePart] = []) -> StorageModel.Sources {
        .init(
            account: { self.lock.withLock { self.account } },
            sealed: { try self.lock.withLock { self.asked += 1; return try self.answer.get() } },
            mailbox: { try self.lock.withLock { try self.mailAnswer.get() } },
            parts: { parts }
        )
    }
}

private func freshDefaults() -> UserDefaults {
    let name = "storage-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func aQuotaReadsAsUsedOfLimit() {
    let quota = StorageQuota(used: 4_200_000_000, limit: 20 * gigabyte)
    #expect(quota.line == "4.2 GB of 20 GB")
    #expect(abs(quota.fraction - 0.21) < 0.0001)
}

@Test func warningsStartAt80And95Percent() {
    #expect(StorageQuota(used: 79, limit: 100).level == .fine)
    #expect(StorageQuota(used: 80, limit: 100).level == .nearlyFull)
    #expect(StorageQuota(used: 94, limit: 100).level == .nearlyFull)
    #expect(StorageQuota(used: 95, limit: 100).level == .almostFull)
    // Over the limit still draws a full bar, never past its end.
    #expect(StorageQuota(used: 130, limit: 100).fraction == 1)
    #expect(StorageQuota(used: 0, limit: 0).fraction == 0)
    #expect(StorageQuota(used: -5, limit: 100).used == 0)
}

@MainActor
@Test func itStartsLoadingThenShowsBothBarsAndTheParts() async {
    let server = Server(StorageQuota(used: 4_200_000_000, limit: 20 * gigabyte))
    let model = StorageModel(sources: server.sources(parts: [
        StoragePart(name: "Photos", bytes: 3_900_000_000), StoragePart(name: "Reader", bytes: 0), StoragePart(name: "Mail", bytes: 118_000_000),
    ]), defaults: freshDefaults())
    #expect(model.sealed == .loading)
    #expect(model.mailbox == .loading)
    await model.refresh()
    #expect(model.sealed == .current(StorageQuota(used: 4_200_000_000, limit: 20 * gigabyte)))
    #expect(model.mailbox == .current(StorageQuota(used: 120_000_000, limit: gigabyte)))
    // A module with nothing stored isn't listed.
    #expect(model.parts.map(\.name) == ["Photos", "Mail"])
}

@MainActor
@Test func noMailboxMeansNoMailboxBar() async {
    let server = Server(StorageQuota(used: 1, limit: 10))
    var sources = server.sources()
    sources.mailbox = nil
    let model = StorageModel(sources: sources, defaults: freshDefaults())
    await model.refresh()
    #expect(model.mailbox == nil)
}

@MainActor
@Test func oneFailureKeepsWhatShowsAndOneThatLastsSaysSo() async {
    let server = Server(StorageQuota(used: 1, limit: 10))
    server.answer(.failure(SealedStoreError.unavailable))
    let model = StorageModel(sources: server.sources(), defaults: freshDefaults())
    await model.refresh()
    #expect(model.sealed == .loading)
    await model.refresh()
    guard case .failed = model.sealed else {
        Issue.record("A failure that lasts should show")
        return
    }
    server.answer(.success(StorageQuota(used: 2, limit: 10)))
    await model.refresh()
    #expect(model.sealed == .current(StorageQuota(used: 2, limit: 10)))
}

@MainActor
@Test func offlineShowsTheLastValueAndWhenItWasRead() async {
    let readAt = Date(timeIntervalSince1970: 1_800_000_000)
    let server = Server(StorageQuota(used: 4_200_000_000, limit: 20 * gigabyte))
    let defaults = freshDefaults()
    let first = StorageModel(sources: server.sources(), defaults: defaults, now: { readAt })
    await first.refresh()

    // A later launch, with no network.
    server.answer(.failure(SealedStoreError.offline))
    server.answerMail(.failure(StorageReadError.offline))
    let later = StorageModel(sources: server.sources(), defaults: defaults)
    await later.refresh()
    #expect(later.sealed == .lastKnown(StorageQuota(used: 4_200_000_000, limit: 20 * gigabyte), at: readAt))
    #expect(later.mailbox == .lastKnown(StorageQuota(used: 120_000_000, limit: gigabyte), at: readAt))
}

@MainActor
@Test func anotherAccountNeverSeesTheLastOnesNumbers() async {
    let server = Server(StorageQuota(used: 4_200_000_000, limit: 20 * gigabyte))
    let defaults = freshDefaults()
    let model = StorageModel(sources: server.sources(parts: [StoragePart(name: "Photos", bytes: 10)]), defaults: defaults)
    await model.refresh()
    #expect(model.sealed.quota != nil)

    server.account = "11111111-2222-4333-8444-555555555555"
    server.answer(.failure(SealedStoreError.offline))
    server.answerMail(.failure(StorageReadError.offline))
    await model.refresh()
    #expect(model.sealed == .loading)
    #expect(model.parts.isEmpty)

    server.account = nil
    await model.refresh()
    #expect(model.sealed == .loading)
}

@MainActor
@Test func anUploadOrDeleteReadsAgainStraightAway() async throws {
    let server = Server(StorageQuota(used: 1, limit: 10))
    let model = StorageModel(sources: server.sources(), defaults: freshDefaults())
    await model.refresh()
    #expect(server.reads == 1)
    server.answer(.success(StorageQuota(used: 5, limit: 10)))
    // Several at once, like emptying Recently Deleted, read only once.
    StorageActivity.didChange()
    StorageActivity.didChange()
    StorageActivity.didChange()
    for _ in 0..<60 where model.sealed != .current(StorageQuota(used: 5, limit: 10)) {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.sealed == .current(StorageQuota(used: 5, limit: 10)))
    #expect(server.reads == 2)
}

@Test func offlineIsToldApartFromOtherFailures() {
    #expect(StorageModel.isOffline(URLError(.notConnectedToInternet)))
    #expect(StorageModel.isOffline(SealedStoreError.offline))
    #expect(StorageModel.isOffline(StorageReadError.offline))
    #expect(!StorageModel.isOffline(SealedStoreError.unavailable))
    #expect(!StorageModel.isOffline(URLError(.badServerResponse)))
}

@MainActor
@Test func appRefreshRunsTheStorageStep() async {
    let refresh = AppRefresh()
    var ran = false
    refresh.extras["storage"] = { ran = true }
    await refresh.refresh()
    #expect(ran)
}

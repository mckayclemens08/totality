import Foundation
import Observation

/// How much of one server-side allowance is used.
public struct StorageQuota: Codable, Equatable, Sendable {
    public let used: Int
    public let limit: Int

    public init(used: Int, limit: Int) {
        self.used = max(0, used)
        self.limit = max(0, limit)
    }

    /// From 0 to 1. A limit of nothing counts as full once anything is used.
    public var fraction: Double {
        guard limit > 0 else { return used > 0 ? 1 : 0 }
        return min(1, Double(used) / Double(limit))
    }

    public enum Level: Equatable, Sendable {
        case fine
        /// 80% or more.
        case nearlyFull
        /// 95% or more.
        case almostFull
    }

    public var level: Level {
        if fraction >= 0.95 { return .almostFull }
        if fraction >= 0.8 { return .nearlyFull }
        return .fine
    }

    /// "4.2 GB of 20 GB".
    public var line: String {
        "\(StorageQuota.bytes(used)) of \(StorageQuota.bytes(limit))"
    }

    public static func bytes(_ count: Int) -> String {
        Int64(count).formatted(ByteCountFormatStyle(style: .file))
    }
}

/// One server allowance as the settings page shows it.
public enum StorageMeter: Equatable, Sendable {
    /// Nothing read yet.
    case loading
    case current(StorageQuota)
    /// The last value read, and when, because the server can't be reached now.
    case lastKnown(StorageQuota, at: Date)
    /// It can't be read, and nothing was read before.
    case failed(String)

    public var quota: StorageQuota? {
        switch self {
        case .current(let quota), .lastKnown(let quota, _): quota
        case .loading, .failed: nil
        }
    }
}

/// One module's share of what's stored, as this device counts it. The server can't split it, because
/// the blobs it holds are sealed and unlabelled.
public struct StoragePart: Equatable, Identifiable, Sendable {
    public let name: String
    public let bytes: Int
    public var id: String { name }

    public init(name: String, bytes: Int) {
        self.name = name
        self.bytes = max(0, bytes)
    }
}

/// Why a usage read failed.
public enum StorageReadError: Error, Equatable, Sendable {
    case offline
    case unavailable
}

/// What's said whenever something is stored on, or removed from, the server, so the settings page's
/// bars catch up straight away instead of on the next timer. Any module may post it through Core.
public enum StorageActivity {
    public static let changed = Notification.Name("app.totality.storageChanged")

    public static func didChange() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// The Storage section of settings: the sealed store's bar, the mailbox's bar, and each module's share.
/// The app hands it the readers, so no module needs to know about another. `AppRefresh` keeps it fresh,
/// any upload or delete nudges it, and the open page asks every 10 seconds.
@MainActor
@Observable
public final class StorageModel {
    public struct Sources: Sendable {
        /// The signed-in account, so one person's last known numbers never show for another.
        public var account: @Sendable () async -> String?
        /// Photos, Reader files and anything else in the sealed blob store.
        public var sealed: @Sendable () async throws -> StorageQuota
        /// The Totality mailbox. Nil when this build has no mail.
        public var mailbox: (@Sendable () async throws -> StorageQuota)?
        /// Each module's share, from sizes this device already knows.
        public var parts: @MainActor @Sendable () async -> [StoragePart]

        public init(
            account: @escaping @Sendable () async -> String?,
            sealed: @escaping @Sendable () async throws -> StorageQuota,
            mailbox: (@Sendable () async throws -> StorageQuota)?,
            parts: @escaping @MainActor @Sendable () async -> [StoragePart]
        ) {
            self.account = account
            self.sealed = sealed
            self.mailbox = mailbox
            self.parts = parts
        }
    }

    /// How often the open page asks.
    public static let whileOpen = Duration.seconds(10)
    /// A failure shows only once it has happened this many times in a row.
    static let failuresBeforeShowing = 2

    public private(set) var sealed: StorageMeter = .loading
    public private(set) var mailbox: StorageMeter?
    public private(set) var parts: [StoragePart] = []

    private let sources: Sources
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    public init(sources: Sources, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.sources = sources
        self.defaults = defaults
        self.now = now
        mailbox = sources.mailbox == nil ? nil : .loading
        observer = NotificationCenter.default.addObserver(forName: StorageActivity.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudge() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reads everything again. Asking while a read is under way waits for that one.
    public func refresh() async {
        if let running { return await running.value }
        let task = Task { await read() }
        running = task
        await task.value
        running = nil
    }

    /// An upload or delete finished: read again shortly, once whatever else it set off has settled.
    @ObservationIgnored private var nudged: Task<Void, Never>?
    func nudge() {
        nudged?.cancel()
        nudged = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Asks every 10 seconds until the task is cancelled, for while the page is open.
    public func keepCurrent() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.whileOpen)
        }
    }

    private func read() async {
        let current = await sources.account()
        if current != account {
            // Another account, or none: nothing of the last one's stays on screen.
            account = current
            failures = [:]
            sealed = remembered("sealed").map { .lastKnown($0.quota, at: $0.at) } ?? .loading
            mailbox = sources.mailbox == nil ? nil : remembered("mailbox").map { .lastKnown($0.quota, at: $0.at) } ?? .loading
            parts = []
        }
        guard current != nil else { return }
        async let sealedRead = Self.attempt(sources.sealed)
        async let mailboxRead: Result<StorageQuota, Error>? = sources.mailbox.map { await Self.attempt($0) }
        let (sealedResult, mailboxResult) = await (sealedRead, mailboxRead)
        let found = await sources.parts()
        // The account may have changed while this was out.
        guard await sources.account() == current, current == account else { return }
        sealed = settle(sealedResult, name: "sealed", was: sealed)
        if let mailboxResult { mailbox = settle(mailboxResult, name: "mailbox", was: mailbox ?? .loading) }
        parts = found.filter { $0.bytes > 0 }
    }

    private nonisolated static func attempt(_ read: @Sendable () async throws -> StorageQuota) async -> Result<StorageQuota, Error> {
        do { return .success(try await read()) } catch { return .failure(error) }
    }

    private func settle(_ result: Result<StorageQuota, Error>, name: String, was: StorageMeter) -> StorageMeter {
        switch result {
        case .success(let quota):
            failures[name] = 0
            remember(quota, as: name)
            return .current(quota)
        case .failure(let error):
            let count = (failures[name] ?? 0) + 1
            failures[name] = count
            let offline = Self.isOffline(error)
            if let last = remembered(name), offline || count >= Self.failuresBeforeShowing {
                return .lastKnown(last.quota, at: last.at)
            }
            // A single failure keeps what's showing; one that lasts says so.
            guard count >= Self.failuresBeforeShowing else { return was }
            return .failed(offline
                ? "You're offline, and this device hasn't read it before."
                : "This couldn't be read. It'll try again shortly.")
        }
    }

    static func isOffline(_ error: Error) -> Bool {
        if let error = error as? StorageReadError { return error == .offline }
        if let error = error as? SealedStoreError { return error == .offline }
        if let error = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                    .dataNotAllowed, .internationalRoamingOff].contains(error.code)
        }
        return false
    }

    // MARK: The last value read, per account

    private struct Remembered: Codable {
        let quota: StorageQuota
        let at: Date
    }

    private func key(_ name: String) -> String? {
        account.map { "storage.\(name).\($0)" }
    }

    private func remember(_ quota: StorageQuota, as name: String) {
        guard let key = key(name), let data = try? JSONEncoder().encode(Remembered(quota: quota, at: now())) else { return }
        defaults.set(data, forKey: key)
    }

    private func remembered(_ name: String) -> Remembered? {
        guard let key = key(name), let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Remembered.self, from: data)
    }
}

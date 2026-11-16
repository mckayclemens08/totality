import Foundation
import Observation

/// Which modules the person took off Home, and when each was last removed or added back. Removing hides a
/// module: its data stays where it is, and a link to its content still opens it.
///
/// Each module keeps the time of its last removal and its last return, so two devices' choices come together
/// by keeping the later of each, whichever way round. Modules are kept by name, so a module this version
/// doesn't know survives a trip through it.
public struct HomeChoices: Codable, Equatable, Sendable {
    public private(set) var removedAt: [String: Date]
    public private(set) var addedAt: [String: Date]

    public init(removedAt: [String: Date] = [:], addedAt: [String: Date] = [:]) {
        self.removedAt = removedAt
        self.addedAt = addedAt
    }

    /// Modules whose last removal is later than their last return.
    public var removed: Set<ModuleID> {
        Set(removedAt.compactMap { name, removed in
            guard let module = ModuleID(rawValue: name), removed > (addedAt[name] ?? .distantPast) else { return nil }
            return module
        })
    }

    public func isRemoved(_ module: ModuleID) -> Bool {
        removed.contains(module)
    }

    public mutating func remove(_ module: ModuleID, at date: Date) {
        removedAt[module.rawValue] = Self.later(removedAt[module.rawValue], date)
    }

    public mutating func restore(_ module: ModuleID, at date: Date) {
        addedAt[module.rawValue] = Self.later(addedAt[module.rawValue], date)
    }

    public static func merged(_ one: HomeChoices, _ other: HomeChoices) -> HomeChoices {
        HomeChoices(
            removedAt: one.removedAt.merging(other.removedAt, uniquingKeysWith: { max($0, $1) }),
            addedAt: one.addedAt.merging(other.addedAt, uniquingKeysWith: { max($0, $1) })
        )
    }

    private static func later(_ date: Date?, _ other: Date) -> Date {
        max(date ?? .distantPast, other)
    }
}

extension HomeChoices: MergedRecord {}

/// The person's `HomeChoices`, sealed with the content key as one record and synced with their other devices.
public actor HomeChoicesBook {
    public static let suffix = ".home"
    /// How a key move finds the record to seal again.
    public static let sealedPurposes: [String: KeyPurpose] = [suffix: .homeLayout]

    private let record: SealedRecordStore<HomeChoices>
    private var pending: SealedRecordStore<HomeChoices>.Pending?

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        // The label gives the record's ID with the key. Never change it.
        record = SealedRecordStore(store: store, rootKey: rootKey, kind: .homeLayout, label: "home-layout", suffix: Self.suffix, purpose: .homeLayout)
    }

    /// What this key's record holds, or nothing chosen yet.
    public func load() -> HomeChoices {
        (try? record.load()) ?? HomeChoices()
    }

    /// Whose record this is, without saying anything about them: the same on all of one person's devices.
    public func owner() -> String? {
        try? record.id().uuidString
    }

    /// Adds `choices` to what's kept and returns the result.
    @discardableResult
    public func add(_ choices: HomeChoices) throws -> HomeChoices {
        let merged = HomeChoices.merged(load(), choices)
        if merged != (try? record.load()) { try record.write(merged) }
        return merged
    }
}

extension HomeChoicesBook: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.homeLayout] }

    public func sealedObjectIDs() throws -> [UUID] { try record.ids() }

    public func sealedHash(of id: UUID) throws -> String? { try record.object(id)?.hash }

    public func sealedObject(_ id: UUID) throws -> SealedObject? { try record.object(id) }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? { try record.verified(id) }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        try record.take(object, ifLocalHash: expected, pending: &pending)
    }

    /// A server's word that the record was deleted can't be proved, and nothing here deletes it, so it stays.
    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {}

    public func deletedObjectIDs() throws -> Set<UUID> { [] }

    public func clearDeletion(_ id: UUID) throws {}

    /// Both sides' choices, the later of each.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        pending = try record.conflict(local: local, remote: remote)
        return .keepRemote
    }

    public func emptyOldTrash() throws {}
}

/// What Home, search and refresh read to know which modules are removed. It shows a copy kept on this device
/// straight away, before the content key opens, and joins the sealed record once it does.
///
/// The copy on the device holds module names and times, never content, and is marked with whose record it
/// came from, so one person's choices never join another's.
@MainActor
@Observable
public final class HomeChoicesModel {
    public static let cacheKey = "home.choices"

    public private(set) var choices: HomeChoices
    public var removed: Set<ModuleID> { choices.removed }

    @ObservationIgnored private var book: HomeChoicesBook?
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date

    private struct Cached: Codable {
        let choices: HomeChoices
        /// Nil for choices made before any record was open on this device.
        let owner: String?
    }

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        let cached = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(Cached.self, from: $0) }
        choices = cached?.choices ?? HomeChoices()
        owner = cached?.owner
    }

    public func remove(_ module: ModuleID) async {
        choices.remove(module, at: now())
        await keep()
    }

    public func restore(_ module: ModuleID) async {
        choices.restore(module, at: now())
        await keep()
    }

    /// Joins this key's record. Choices made here before any record was open go into it; a copy from
    /// someone else's record is dropped.
    public func open(_ book: HomeChoicesBook) async {
        self.book = book
        let theirs = await book.owner()
        if owner != nil, owner != theirs { choices = HomeChoices() }
        owner = theirs
        await keep()
    }

    /// Lets go of the record, for a key change. What shows stays until the next record opens.
    public func close() {
        book = nil
    }

    /// Reads the record again, after a sync may have brought another device's choices.
    public func reload() async {
        guard let book else { return }
        let stored = await book.load()
        let merged = HomeChoices.merged(stored, choices)
        if merged != choices { choices = merged }
        save()
    }

    private func keep() async {
        if let book, let merged = try? await book.add(choices), merged != choices { choices = merged }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Cached(choices: choices, owner: owner)) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }
}

extension Array where Element == any ModuleSearcher {
    /// Home search reaches only the modules on Home.
    public func onHome(removed: Set<ModuleID>) -> [any ModuleSearcher] {
        filter { !removed.contains($0.module) }
    }
}

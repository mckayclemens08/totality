import Foundation
import TotalityCore

public struct TaskListing: Sendable, Equatable {
    public let tasks: [TaskItem]
    public let lists: [TaskList]
    /// Items that would not open. The screen says so instead of hiding them.
    public let unreadable: Int
}

public enum TaskVaultError: Error, Equatable {
    case notFound, mismatched, closed
}

/// A person's own tasks and lists. Each is one sealed blob whose name holds only its random ID, so the
/// device's storage says no more than the server does.
public actor TaskVault {
    /// How each kind of blob is sealed, so a key change can reach them without knowing what they are.
    public static let sealedPurposes: [String: KeyPurpose] = [
        ".task": .task, ".task.trash": .task, ".tasklist": .taskList, ".tasklist.trash": .taskList,
    ]
    /// How long something removed by another device stays recoverable here.
    public static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var isClosed = false
    private var hashes: [UUID: String] = [:]

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    private enum Shape {
        case task, list

        var suffix: String { self == .task ? ".task" : ".tasklist" }
        var purpose: KeyPurpose { self == .task ? .task : .taskList }
        var kind: ContentKind { self == .task ? .task : .taskList }
    }

    private func name(_ id: UUID, _ shape: Shape) -> String { id.uuidString.lowercased() + shape.suffix }
    private func deletionName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).deleted" }
    private func trashStampName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).trashed" }

    /// Refuses all further writes, so nothing lands under the old key during a key move.
    public func close() {
        isClosed = true
    }

    private func seal<T: Encodable>(_ value: T, id: UUID, _ shape: Shape) throws -> Data {
        let key = rootKey.objectKey(for: id, purpose: shape.purpose)
        return try ContentCipher.seal(JSONEncoder().encode(value), key: key, objectID: id)
    }

    private func open<T: Decodable>(_ sealed: Data, as type: T.Type, id: UUID, _ shape: Shape) throws -> T {
        let key = rootKey.objectKey(for: id, purpose: shape.purpose)
        return try JSONDecoder().decode(type, from: ContentCipher.open(sealed, key: key, objectID: id))
    }

    public func save(_ task: TaskItem) throws {
        guard !isClosed else { throw TaskVaultError.closed }
        hashes[task.id] = nil
        try store.write(try seal(task, id: task.id, .task), as: name(task.id, .task))
    }

    public func save(_ list: TaskList) throws {
        guard !isClosed else { throw TaskVaultError.closed }
        hashes[list.id] = nil
        try store.write(try seal(list, id: list.id, .list), as: name(list.id, .list))
    }

    public func task(_ id: UUID) throws -> TaskItem {
        guard let sealed = try store.read(name(id, .task)) else { throw TaskVaultError.notFound }
        let task = try open(sealed, as: TaskItem.self, id: id, .task)
        guard task.id == id else { throw TaskVaultError.mismatched }
        return task
    }

    public func list(_ id: UUID) throws -> TaskList {
        guard let sealed = try store.read(name(id, .list)) else { throw TaskVaultError.notFound }
        let list = try open(sealed, as: TaskList.self, id: id, .list)
        guard list.id == id else { throw TaskVaultError.mismatched }
        return list
    }

    /// Saves `task` over `original` only if nothing else changed it meanwhile. Otherwise the two are merged
    /// part by part, so a change from a sync that landed meanwhile is never undone. Returns what was saved.
    @discardableResult
    public func save(_ task: TaskItem, over original: TaskItem?) throws -> TaskItem {
        guard let original, let current = try? self.task(task.id), current != original else {
            try save(task)
            return task
        }
        let merged = current.merged(with: task)
        try save(merged)
        return merged
    }

    public func everything() throws -> TaskListing {
        var tasks: [TaskItem] = []
        var lists: [TaskList] = []
        var unreadable = 0
        for file in try store.names() {
            if file.hasSuffix(".task"), let id = UUID(uuidString: String(file.dropLast(5))) {
                do { tasks.append(try task(id)) } catch is CryptoError, is DecodingError, is TaskVaultError { unreadable += 1 }
            } else if file.hasSuffix(".tasklist"), let id = UUID(uuidString: String(file.dropLast(9))) {
                do { lists.append(try list(id)) } catch is CryptoError, is DecodingError, is TaskVaultError { unreadable += 1 }
            }
        }
        return TaskListing(tasks: tasks, lists: lists, unreadable: unreadable)
    }

    public func delete(_ id: UUID) throws {
        guard !isClosed else { throw TaskVaultError.closed }
        // The record goes first, so a crash can't lose the fact that this was deleted on purpose.
        try store.write(Data(), as: deletionName(id))
        try store.delete(name(id, .task))
        try store.delete(name(id, .list))
        hashes[id] = nil
    }

    private func shape(of id: UUID) throws -> Shape? {
        if try store.exists(name(id, .task)) { return .task }
        if try store.exists(name(id, .list)) { return .list }
        return nil
    }
}

extension TaskVault: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.task, .taskList] }

    public func sealedObjectIDs() throws -> [UUID] {
        // A crash can stop a delete halfway. The record says what was meant, so finish it.
        if !isClosed {
            for id in try deletedObjectIDs() where try shape(of: id) != nil {
                try store.delete(name(id, .task))
                try store.delete(name(id, .list))
                hashes[id] = nil
            }
        }
        return try store.names().compactMap { file in
            if file.hasSuffix(".task") { return UUID(uuidString: String(file.dropLast(5))) }
            if file.hasSuffix(".tasklist") { return UUID(uuidString: String(file.dropLast(9))) }
            return nil
        }
    }

    public func sealedHash(of id: UUID) throws -> String? {
        if let known = hashes[id] { return known }
        let hash = try sealedObject(id)?.hash
        hashes[id] = hash
        return hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        guard let shape = try shape(of: id), let sealed = try store.read(name(id, shape)) else { return nil }
        return SealedObject(id: id, kind: shape.kind, meta: sealed, body: nil)
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        try check(object)
        return object
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw TaskVaultError.closed }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        if expected == nil, try store.read(deletionName(object.id)) != nil { throw SyncError.changedLocally }
        let shape = try check(object)
        // An ID is one kind for good, so a server can't turn a task into a list.
        if let existing = try self.shape(of: object.id), existing != shape { throw CryptoError.authenticationFailed }
        try store.write(object.meta, as: name(object.id, shape))
        hashes[object.id] = nil
    }

    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {
        guard !isClosed else { throw TaskVaultError.closed }
        guard try sealedHash(of: id) == expected else { throw SyncError.changedLocally }
        guard let shape = try shape(of: id), let sealed = try store.read(name(id, shape)) else { return }
        // The stamp goes first, so a crash can't leave trash that's never cleaned up.
        try store.write(Data(ISO8601DateFormatter().string(from: Date()).utf8), as: trashStampName(id))
        try store.write(sealed, as: name(id, shape) + ".trash")
        try store.delete(name(id, shape))
        hashes[id] = nil
    }

    public func emptyOldTrash() throws {
        guard !isClosed else { return }
        let formatter = ISO8601DateFormatter()
        for file in try store.names() where file.hasSuffix(".trashed") {
            guard let id = UUID(uuidString: String(file.dropLast(".trashed".count))),
                  let stamp = try store.read(file), let date = formatter.date(from: String(decoding: stamp, as: UTF8.self)),
                  Date().timeIntervalSince(date) > Self.trashLifetime
            else { continue }
            try store.delete(name(id, .task) + ".trash")
            try store.delete(name(id, .list) + ".trash")
            try store.delete(file)
        }
    }

    public func deletedObjectIDs() throws -> Set<UUID> {
        Set(try store.names().compactMap { file in
            file.hasSuffix(".deleted") ? UUID(uuidString: String(file.dropLast(".deleted".count))) : nil
        })
    }

    public func clearDeletion(_ id: UUID) throws {
        try store.delete(deletionName(id))
    }

    /// Tasks merge part by part, so nothing either device changed is lost and no copy is needed. The
    /// merged task is saved here, and the next sync sends it up. Lists keep the newer.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        let shape = try check(local)
        guard try check(remote) == shape else { throw CryptoError.authenticationFailed }
        switch shape {
        case .task:
            let mine = try open(local.meta, as: TaskItem.self, id: local.id, .task)
            let theirs = try open(remote.meta, as: TaskItem.self, id: remote.id, .task)
            let merged = mine.merged(with: theirs)
            if merged == theirs { return .keepRemote }
            if merged != mine { try save(merged) }
            return .keepLocal
        case .list:
            let mine = try open(local.meta, as: TaskList.self, id: local.id, .list)
            let theirs = try open(remote.meta, as: TaskList.self, id: remote.id, .list)
            return mine.updatedAt >= theirs.updatedAt ? .keepLocal : .keepRemote
        }
    }

    /// Proves the object opens under this device's key as what it says it is.
    @discardableResult
    private func check(_ object: SealedObject) throws -> Shape {
        switch object.kind {
        case .task:
            let task = try open(object.meta, as: TaskItem.self, id: object.id, .task)
            guard task.id == object.id else { throw CryptoError.authenticationFailed }
            return .task
        case .taskList:
            let list = try open(object.meta, as: TaskList.self, id: object.id, .list)
            guard list.id == object.id else { throw CryptoError.authenticationFailed }
            return .list
        default:
            throw CryptoError.authenticationFailed
        }
    }
}

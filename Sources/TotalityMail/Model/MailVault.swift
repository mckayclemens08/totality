import Foundation
import TotalityCore

/// A message as this device keeps it: what `MailKey` opened, exactly as it came, re-sealed with the
/// content key so a key move carries it along. `raw` is nil when the server's seal wouldn't open, so
/// the date is all that's known and it isn't fetched again and again.
public struct MailStoredMessage: Codable, Equatable, Sendable {
    public let id: UUID
    public let received: Date
    public let raw: Data?

    public init(id: UUID, received: Date, raw: Data?) {
        self.id = id
        self.received = received
        self.raw = raw
    }
}

public enum MailVaultError: Error, Equatable {
    case closed
}

/// One account's mail on this device. Everything is sealed with the content key, and file names hold
/// only IDs, so nothing readable reaches the disk.
///
/// Messages stay on this device, because they come from the mail server. Marks and settings sync, as
/// one sealed object per message's marks and one for the settings. Two devices changing different
/// messages never touch the same object, so neither can overwrite the other, and a conflict on one
/// message costs only that message's older marks. One object for all marks would make every change on
/// one device clash with every change on another.
///
/// The device has one content key, so the key doesn't keep two accounts apart: the IDs do. Each ID is
/// derived from the account and the message, so every device works out the same one for the same
/// message, and a key move doesn't change it. It also isn't the mail server's ID, so the sync server
/// can't line its rows up with the mailbox. Every record names its account and message inside the seal,
/// and must derive to the ID it's stored under, so nothing can be moved between accounts or messages.
public actor MailVault {
    private static let messageSuffix = ".mail"
    private static let marksSuffix = ".mail.marks"
    private static let settingsSuffix = ".mail.settings"

    /// How each file is sealed, so a key move can reach them without knowing what they are. The IDs are
    /// derived from text only Mail uses, so no other module's blob can share one.
    public static let sealedPurposes: [String: KeyPurpose] = [
        messageSuffix: .content,
        marksSuffix: .metadata, marksSuffix + ".trash": .metadata,
        settingsSuffix: .metadata, settingsSuffix + ".trash": .metadata,
    ]
    public static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60

    struct MarksRecord: Codable, Equatable {
        let account: String
        let message: UUID
        let marks: MailMarks
        let updatedAt: Date
    }

    struct SettingsRecord: Codable, Equatable {
        let account: String
        let settings: MailSettings
        let updatedAt: Date
    }

    struct MessageRecord: Codable {
        let account: String
        let message: MailStoredMessage
    }

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    public nonisolated let account: String
    private var isClosed = false
    private var hashes: [UUID: String] = [:]

    public init(store: any BlobStore, rootKey: ContentRootKey, account: String) {
        self.store = store
        self.rootKey = rootKey
        self.account = account
    }

    public func close() {
        isClosed = true
    }

    // MARK: IDs and names

    static func messageID(_ message: UUID, account: String) -> UUID {
        UUID(derivedFrom: "totality.mail.message.\(account).\(message.uuidString.lowercased())")
    }

    static func marksID(_ message: UUID, account: String) -> UUID {
        UUID(derivedFrom: "totality.mail.marks.\(account).\(message.uuidString.lowercased())")
    }

    static func settingsID(account: String) -> UUID {
        UUID(derivedFrom: "totality.mail.settings.\(account)")
    }

    private func name(_ id: UUID, _ suffix: String) -> String { id.uuidString.lowercased() + suffix }
    private func deletionName(_ id: UUID) -> String { name(id, SealedArea.deletionSuffix) }
    private func trashStampName(_ id: UUID) -> String { name(id, ".mail.trashed") }

    private func ids(_ suffix: String) throws -> [UUID] {
        try store.names().compactMap { file in
            guard file.hasSuffix(suffix) else { return nil }
            return UUID(uuidString: String(file.dropLast(suffix.count)))
        }
    }

    private func seal<Value: Encodable>(_ value: Value, id: UUID, purpose: KeyPurpose) throws -> Data {
        try ContentCipher.seal(JSONEncoder().encode(value), key: rootKey.objectKey(for: id, purpose: purpose), objectID: id)
    }

    private func open<Value: Decodable>(_ type: Value.Type, _ sealed: Data, id: UUID, purpose: KeyPurpose) throws -> Value {
        let opened = try ContentCipher.open(sealed, key: rootKey.objectKey(for: id, purpose: purpose), objectID: id)
        // It opened but isn't what it's filed as, so it's treated like any other blob that isn't ours.
        guard let value = try? JSONDecoder().decode(type, from: opened) else { throw CryptoError.authenticationFailed }
        return value
    }

    // MARK: Messages

    public func keep(_ message: MailStoredMessage) throws {
        guard !isClosed else { throw MailVaultError.closed }
        let id = Self.messageID(message.id, account: account)
        try store.write(try seal(MessageRecord(account: account, message: message), id: id, purpose: .content), as: name(id, Self.messageSuffix))
    }

    public func hasMessage(_ message: UUID) throws -> Bool {
        try store.read(name(Self.messageID(message, account: account), Self.messageSuffix)) != nil
    }

    public func message(_ message: UUID) throws -> MailStoredMessage? {
        let id = Self.messageID(message, account: account)
        guard let sealed = try store.read(name(id, Self.messageSuffix)) else { return nil }
        let record = try open(MessageRecord.self, sealed, id: id, purpose: .content)
        guard record.account == account, record.message.id == message else { throw CryptoError.authenticationFailed }
        return record.message
    }

    /// This account's messages. One that won't open, or is someone else's, is left out and left alone.
    public func messages() throws -> [MailStoredMessage] {
        try ids(Self.messageSuffix).compactMap { id in
            guard let sealed = try store.read(name(id, Self.messageSuffix)),
                  let record = try? open(MessageRecord.self, sealed, id: id, purpose: .content),
                  record.account == account, Self.messageID(record.message.id, account: account) == id
            else { return nil }
            return record.message
        }
    }

    /// For good, with their marks. The marks' removal reaches other devices through sync.
    public func erase(_ messages: Set<UUID>) throws {
        guard !isClosed else { throw MailVaultError.closed }
        for message in messages {
            let marks = Self.marksID(message, account: account)
            if try store.read(name(marks, Self.marksSuffix)) != nil {
                // The record goes first, so a crash can't lose the fact that this was deleted on purpose.
                try store.write(Data(), as: deletionName(marks))
                try store.delete(name(marks, Self.marksSuffix))
                hashes[marks] = nil
            }
            try store.delete(name(Self.messageID(message, account: account), Self.messageSuffix))
        }
    }

    // MARK: Marks and settings

    /// Keyed by message. One that won't open is left out, and stays on disk for sync or a key move.
    public func marks() throws -> [UUID: MailMarks] {
        var found: [UUID: MailMarks] = [:]
        for id in try ids(Self.marksSuffix) {
            guard let sealed = try store.read(name(id, Self.marksSuffix)),
                  let record = try? openedMarks(id: id, sealed: sealed)
            else { continue }
            found[record.message] = record.marks
        }
        return found
    }

    public func save(_ marks: [UUID: MailMarks], at now: Date = Date()) throws {
        guard !isClosed else { throw MailVaultError.closed }
        for (message, value) in marks {
            let id = Self.marksID(message, account: account)
            hashes[id] = nil
            let record = MarksRecord(account: account, message: message, marks: value, updatedAt: now)
            try store.write(try seal(record, id: id, purpose: .metadata), as: name(id, Self.marksSuffix))
            try store.delete(deletionName(id))
        }
    }

    /// Nil until the person changes something, so a new device takes what syncs instead of overwriting it.
    public func settings() throws -> MailSettings? {
        let id = Self.settingsID(account: account)
        guard let sealed = try store.read(name(id, Self.settingsSuffix)) else { return nil }
        return try openedSettings(id: id, sealed: sealed).settings
    }

    public func save(_ settings: MailSettings, at now: Date = Date()) throws {
        guard !isClosed else { throw MailVaultError.closed }
        let id = Self.settingsID(account: account)
        hashes[id] = nil
        let record = SettingsRecord(account: account, settings: settings, updatedAt: now)
        try store.write(try seal(record, id: id, purpose: .metadata), as: name(id, Self.settingsSuffix))
    }

    private func openedMarks(id: UUID, sealed: Data) throws -> MarksRecord {
        let record = try open(MarksRecord.self, sealed, id: id, purpose: .metadata)
        guard record.account == account, Self.marksID(record.message, account: account) == id else {
            throw CryptoError.authenticationFailed
        }
        return record
    }

    private func openedSettings(id: UUID, sealed: Data) throws -> SettingsRecord {
        let record = try open(SettingsRecord.self, sealed, id: id, purpose: .metadata)
        guard record.account == account, Self.settingsID(account: account) == id else { throw CryptoError.authenticationFailed }
        return record
    }

    /// When an object was last changed, after proving it opens and belongs here.
    private func updatedAt(_ object: SealedObject) throws -> Date {
        switch object.kind {
        case .mailMarks: try openedMarks(id: object.id, sealed: object.meta).updatedAt
        case .mailSettings: try openedSettings(id: object.id, sealed: object.meta).updatedAt
        default: throw CryptoError.authenticationFailed
        }
    }

    private func suffix(for kind: ContentKind) -> String? {
        switch kind {
        case .mailMarks: Self.marksSuffix
        case .mailSettings: Self.settingsSuffix
        default: nil
        }
    }

    /// The synced file under this ID, if there is one.
    private func synced(_ id: UUID) throws -> (kind: ContentKind, data: Data)? {
        if let data = try store.read(name(id, Self.marksSuffix)) { return (.mailMarks, data) }
        if let data = try store.read(name(id, Self.settingsSuffix)) { return (.mailSettings, data) }
        return nil
    }
}

extension MailVault: SyncArea {
    /// Only marks and settings. Messages have no kind here, so sync can never see them.
    public nonisolated var kinds: Set<ContentKind> { [.mailMarks, .mailSettings] }

    /// Only this account's. Another account's files on this device stay out of this account's sync.
    public func sealedObjectIDs() throws -> [UUID] {
        // A crash can stop an erase halfway. The record says what was meant, so finish it.
        if !isClosed {
            for id in try deletedObjectIDs() where try store.read(name(id, Self.marksSuffix)) != nil {
                try store.delete(name(id, Self.marksSuffix))
                hashes[id] = nil
            }
        }
        var found: [UUID] = []
        for id in try ids(Self.marksSuffix) {
            if let sealed = try store.read(name(id, Self.marksSuffix)), (try? openedMarks(id: id, sealed: sealed)) == nil { continue }
            found.append(id)
        }
        let settings = Self.settingsID(account: account)
        if try store.read(name(settings, Self.settingsSuffix)) != nil { found.append(settings) }
        return found
    }

    public func sealedHash(of id: UUID) throws -> String? {
        if let known = hashes[id] { return known }
        let hash = try sealedObject(id)?.hash
        hashes[id] = hash
        return hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        try synced(id).map { SealedObject(id: id, kind: $0.kind, meta: $0.data, body: nil) }
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        _ = try updatedAt(object)
        return object
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw MailVaultError.closed }
        guard let suffix = suffix(for: object.kind), object.body == nil else { throw CryptoError.authenticationFailed }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        if expected == nil, try store.read(deletionName(object.id)) != nil { throw SyncError.changedLocally }
        _ = try updatedAt(object)
        try store.write(object.meta, as: name(object.id, suffix))
        hashes[object.id] = nil
    }

    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {
        guard !isClosed else { throw MailVaultError.closed }
        guard try sealedHash(of: id) == expected else { throw SyncError.changedLocally }
        guard let (kind, sealed) = try synced(id), let suffix = suffix(for: kind) else { return }
        // The stamp goes first, so a crash can't leave trash that's never cleaned up.
        try store.write(Data(ISO8601DateFormatter().string(from: Date()).utf8), as: trashStampName(id))
        try store.write(sealed, as: name(id, suffix) + ".trash")
        try store.delete(name(id, suffix))
        hashes[id] = nil
    }

    public func emptyOldTrash() throws {
        guard !isClosed else { return }
        let formatter = ISO8601DateFormatter()
        for file in try store.names() where file.hasSuffix(".mail.trashed") {
            guard let id = UUID(uuidString: String(file.dropLast(".mail.trashed".count))),
                  let stamp = try store.read(file), let date = formatter.date(from: String(decoding: stamp, as: UTF8.self)),
                  Date().timeIntervalSince(date) > Self.trashLifetime
            else { continue }
            try store.delete(name(id, Self.marksSuffix) + ".trash")
            try store.delete(name(id, Self.settingsSuffix) + ".trash")
            try store.delete(file)
        }
    }

    public func deletedObjectIDs() throws -> Set<UUID> {
        Set(try ids(SealedArea.deletionSuffix))
    }

    public func clearDeletion(_ id: UUID) throws {
        try store.delete(deletionName(id))
    }

    /// The newest wins. One message's marks or one set of settings is small, and the screens can't show
    /// a second copy of either, so keeping one would only hide it.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        guard local.kind == remote.kind else { throw CryptoError.authenticationFailed }
        return try updatedAt(local) >= updatedAt(remote) ? .keepLocal : .keepRemote
    }
}

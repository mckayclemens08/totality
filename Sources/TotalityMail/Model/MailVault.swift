import Foundation
import TotalityCore

/// A message as this device keeps it: what `MailKey` or `MailSentKey` opened, exactly as it came,
/// re-sealed with the content key so a key move carries it along. `raw` is nil when the server's seal
/// wouldn't open, so the date is all that's known and it isn't fetched again and again.
public struct MailStoredMessage: Codable, Equatable, Sendable {
    public let id: UUID
    public let received: Date
    public let raw: Data?
    /// This account's own Sent copy: written on this device, or opened from the format only this
    /// person's devices can seal. Only then does the line above the message count when it says "sent".
    public let ownCopy: Bool
    /// For mail from another Totality account, the sender's public key its inner seal was checked
    /// against. Nil when no key was found, so it can't be opened.
    public let senderKey: Data?
    /// The key the server gave for the sender wasn't the one this account pinned for them, so the
    /// message is never shown as proved.
    public let senderKeyChanged: Bool

    public init(id: UUID, received: Date, raw: Data?, ownCopy: Bool = false, senderKey: Data? = nil, senderKeyChanged: Bool = false) {
        self.id = id
        self.received = received
        self.raw = raw
        self.ownCopy = ownCopy
        self.senderKey = senderKey
        self.senderKeyChanged = senderKeyChanged
    }

    private enum CodingKeys: String, CodingKey {
        case id, received, raw, ownCopy, senderKey, senderKeyChanged
    }

    /// Kept before these existed, it's nobody's own copy and has no sender key, so it claims nothing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        received = try container.decode(Date.self, forKey: .received)
        raw = try container.decodeIfPresent(Data.self, forKey: .raw)
        ownCopy = try container.decodeIfPresent(Bool.self, forKey: .ownCopy) ?? false
        senderKey = try container.decodeIfPresent(Data.self, forKey: .senderKey)
        senderKeyChanged = try container.decodeIfPresent(Bool.self, forKey: .senderKeyChanged) ?? false
    }
}

public enum MailVaultError: Error, Equatable {
    case closed
}

/// One account's mail on this device. Everything is sealed with the content key, and file names hold
/// only IDs, so nothing readable reaches the disk.
///
/// Messages stay on this device, because they come from the mail server. Marks, settings, and pinned
/// keys sync, as one sealed object per message's marks, one for the settings, and one for the pins. Two devices changing different
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
    private static let keysSuffix = ".mail.keys"
    private static let draftSuffix = ".mail.draft"
    private static let draftBodySuffix = ".mail.draft.body"
    /// A Sent copy the server didn't take. The message itself is kept like any other; this only says
    /// it still has to reach the server, so it's never pruned or lost meanwhile. It stays on this device.
    private static let unkeptSuffix = ".mail.unkept"
    /// One outside account, with its app password. It has no trash file: a sign-in is never kept
    /// after it's removed, here or because the server says so.
    private static let outsideSuffix = ".mail.outside"

    /// How each file is sealed, so a key move can reach them without knowing what they are. The IDs are
    /// derived from text only Mail uses, so no other module's blob can share one.
    public static let sealedPurposes: [String: KeyPurpose] = [
        messageSuffix: .content,
        marksSuffix: .metadata, marksSuffix + ".trash": .metadata,
        settingsSuffix: .metadata, settingsSuffix + ".trash": .metadata,
        keysSuffix: .metadata,
        draftSuffix: .metadata, draftSuffix + ".trash": .metadata,
        draftBodySuffix: .content, draftBodySuffix + ".trash": .content,
        unkeptSuffix: .metadata,
        outsideSuffix: .metadata,
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

    /// Never moved to the trash, so it has no trash file.
    struct KeysRecord: Codable, Equatable {
        let account: String
        let pins: MailPins
    }

    /// Settings sealed before the pins moved out of them, read only for the pins they still carry.
    private struct LegacySettingsRecord: Decodable {
        struct Settings: Decodable {
            let knownKeys: [String: Data]?
        }

        let account: String
        let settings: Settings
        let updatedAt: Date
    }

    /// A draft's words and who it's for. Its files go in the body, so a change to the words alone
    /// doesn't move them all again.
    struct DraftRecord: Codable, Equatable {
        let account: String
        let draft: MailDraft
        let updatedAt: Date
    }

    struct DraftBody: Codable, Equatable {
        let account: String
        let draft: UUID
        let attachments: [MailDraftAttachment]
    }

    struct UnkeptRecord: Codable, Equatable {
        let account: String
        let message: UUID
    }

    /// The app password or Google's token travels only inside this seal. On the device it's also in
    /// the keychain, which is where it's used from.
    struct OutsideRecord: Codable, Equatable {
        let account: String
        let outside: OutsideAccount
        let credential: OutsideCredential
        let updatedAt: Date
    }

    struct MessageRecord: Codable {
        let account: String
        let message: MailStoredMessage
    }

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    public nonisolated let account: String
    /// Where outside accounts' sign-ins are used from. Nil means this vault keeps none.
    private let secrets: (any KeyStore)?
    private var isClosed = false
    private var hashes: [UUID: String] = [:]

    public init(store: any BlobStore, rootKey: ContentRootKey, account: String, secrets: (any KeyStore)? = nil) {
        self.store = store
        self.rootKey = rootKey
        self.account = account
        self.secrets = secrets
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

    static func unkeptID(_ message: UUID, account: String) -> UUID {
        UUID(derivedFrom: "totality.mail.unkept.\(account).\(message.uuidString.lowercased())")
    }

    static func settingsID(account: String) -> UUID {
        UUID(derivedFrom: "totality.mail.settings.\(account)")
    }

    static func keysID(account: String) -> UUID {
        UUID(derivedFrom: "totality.mail.keys.\(account)")
    }

    static func outsideID(_ outside: UUID, account: String) -> UUID {
        UUID(derivedFrom: "totality.mail.outside.\(account).\(outside.uuidString.lowercased())")
    }

    /// The keychain name for one outside account's app password. It names the Totality account, so
    /// another account on this device can never reach it.
    static func secretName(_ outside: UUID, account: String) -> String {
        "mail.outside.\(account.lowercased()).\(outside.uuidString.lowercased())"
    }

    static func draftID(_ draft: UUID, account: String) -> UUID {
        UUID(derivedFrom: "totality.mail.draft.\(account).\(draft.uuidString.lowercased())")
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

    // MARK: Sent copies the server didn't take

    /// Kept here, and marked to be tried on the server again.
    public func keepUnkept(_ message: MailStoredMessage) throws {
        try keep(message)
        let id = Self.unkeptID(message.id, account: account)
        try store.write(try seal(UnkeptRecord(account: account, message: message.id), id: id, purpose: .metadata), as: name(id, Self.unkeptSuffix))
    }

    /// The Sent copies still waiting for the server. One that won't open is left alone.
    public func unkept() throws -> [UUID] {
        try ids(Self.unkeptSuffix).compactMap { id in
            guard let sealed = try store.read(name(id, Self.unkeptSuffix)),
                  let record = try? open(UnkeptRecord.self, sealed, id: id, purpose: .metadata),
                  record.account == account, Self.unkeptID(record.message, account: account) == id
            else { return nil }
            return record.message
        }
    }

    /// The server has it now, or it's been deleted.
    public func kept(_ message: UUID) throws {
        guard !isClosed else { throw MailVaultError.closed }
        try store.delete(name(Self.unkeptID(message, account: account), Self.unkeptSuffix))
    }

    /// For good, with their marks. The marks' removal reaches other devices through sync.
    public func erase(_ messages: Set<UUID>) throws {
        guard !isClosed else { throw MailVaultError.closed }
        for message in messages {
            try store.delete(name(Self.unkeptID(message, account: account), Self.unkeptSuffix))
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

    // MARK: Pinned keys

    /// Every pin this device knows, with any still in settings sealed before the pins moved out of them.
    /// Those are moved over the first time they're seen, so they sync like the rest.
    public func pins() throws -> MailPins {
        let stored = try storedPins()
        var merged = stored ?? MailPins()
        if let legacy = try legacyPins() { merged.merge(legacy) }
        if merged != (stored ?? MailPins()), !isClosed { try write(merged) }
        return merged
    }

    /// The one way a pin is added. It reads, merges, and writes with no wait in between, and the vault
    /// is an actor, so two callers can't overwrite each other's pins. A name that already has a different
    /// key keeps it and is marked disputed. Returns every pin after the change.
    @discardableResult
    public func pin(_ name: String, key: Data, at now: Date = Date()) throws -> MailPins {
        guard !isClosed else { throw MailVaultError.closed }
        let before = try pins()
        var after = before
        after.add(name, key: key, at: now)
        if after != before { try write(after) }
        return after
    }

    private func storedPins() throws -> MailPins? {
        let id = Self.keysID(account: account)
        guard let sealed = try store.read(name(id, Self.keysSuffix)) else { return nil }
        return try openedKeys(id: id, sealed: sealed).pins
    }

    private func legacyPins() throws -> MailPins? {
        let id = Self.settingsID(account: account)
        guard let sealed = try store.read(name(id, Self.settingsSuffix)),
              let record = try? open(LegacySettingsRecord.self, sealed, id: id, purpose: .metadata),
              record.account == account, let known = record.settings.knownKeys, !known.isEmpty
        else { return nil }
        var pins = MailPins()
        for (name, key) in known { pins.add(name, key: key, at: record.updatedAt) }
        return pins
    }

    private func write(_ pins: MailPins) throws {
        let id = Self.keysID(account: account)
        hashes[id] = nil
        try store.write(try seal(KeysRecord(account: account, pins: pins), id: id, purpose: .metadata), as: name(id, Self.keysSuffix))
    }

    private func openedKeys(id: UUID, sealed: Data) throws -> KeysRecord {
        let record = try open(KeysRecord.self, sealed, id: id, purpose: .metadata)
        guard record.account == account, Self.keysID(account: account) == id else { throw CryptoError.authenticationFailed }
        return record
    }

    // MARK: Outside accounts

    /// This account's outside accounts, oldest first. One that won't open, or is someone else's, is
    /// left out and left alone.
    public func outsideAccounts() throws -> [OutsideAccount] {
        try outsideRecords().map(\.outside).sorted { ($0.addedAt, $0.id.uuidString) < ($1.addedAt, $1.id.uuidString) }
    }

    /// Keeps the account and its sign-in, or replaces them. The keychain is written first, so a saved
    /// account always has its sign-in here.
    public func save(_ outside: OutsideAccount, credential: OutsideCredential, at now: Date = Date()) throws {
        guard !isClosed else { throw MailVaultError.closed }
        guard let secrets else { throw OutsideAccountError.unavailable }
        let id = Self.outsideID(outside.id, account: account)
        try secrets.save(try credential.keychainData, as: Self.secretName(outside.id, account: account))
        let record = OutsideRecord(account: account, outside: outside, credential: credential, updatedAt: now)
        try store.write(try seal(record, id: id, purpose: .metadata), as: name(id, Self.outsideSuffix))
        try store.delete(deletionName(id))
        hashes[id] = nil
    }

    /// Changes what's kept about the account, with the sign-in it already has.
    public func update(_ outside: OutsideAccount, at now: Date = Date()) throws {
        guard let record = try outsideRecord(outside.id) else { throw OutsideAccountError.notFound }
        try save(outside, credential: record.credential, at: now)
    }

    /// The account's sign-in, from the keychain. A device that got the account through sync and lost
    /// the keychain copy gets it back from the sealed record.
    public func credential(for outside: UUID) throws -> OutsideCredential? {
        guard let secrets, let record = try outsideRecord(outside) else { return nil }
        let secret = Self.secretName(outside, account: account)
        let kept = try secrets.load(secret).flatMap { try? OutsideCredential(keychainData: $0) }
        if kept != record.credential {
            try secrets.save(try record.credential.keychainData, as: secret)
        }
        return record.credential
    }

    /// An app-password account's sign-in, ready for IMAP or SMTP.
    public func signIn(for outside: UUID) throws -> OutsideSignIn? {
        guard case .appPassword(let password) = try credential(for: outside),
              let record = try outsideRecord(outside) else { return nil }
        return OutsideSignIn(provider: record.outside.provider, address: record.outside.address, appPassword: password)
    }

    /// The sign-in leaves the keychain first, then the record goes, and the removal reaches the other
    /// devices through sync. Nothing at the provider is touched.
    public func removeOutside(_ outside: UUID) throws {
        guard !isClosed else { throw MailVaultError.closed }
        let id = Self.outsideID(outside, account: account)
        try secrets?.delete(Self.secretName(outside, account: account))
        guard try store.read(name(id, Self.outsideSuffix)) != nil else { return }
        try store.write(Data(), as: deletionName(id))
        try store.delete(name(id, Self.outsideSuffix))
        hashes[id] = nil
    }

    private func outsideRecord(_ outside: UUID) throws -> OutsideRecord? {
        let id = Self.outsideID(outside, account: account)
        guard let sealed = try store.read(name(id, Self.outsideSuffix)) else { return nil }
        return try openedOutside(id: id, sealed: sealed)
    }

    private func outsideRecords() throws -> [OutsideRecord] {
        try ids(Self.outsideSuffix).compactMap { id in
            guard let sealed = try store.read(name(id, Self.outsideSuffix)) else { return nil }
            return try? openedOutside(id: id, sealed: sealed)
        }
    }

    private func openedOutside(id: UUID, sealed: Data) throws -> OutsideRecord {
        let record = try open(OutsideRecord.self, sealed, id: id, purpose: .metadata)
        guard record.account == account, Self.outsideID(record.outside.id, account: account) == id else {
            throw CryptoError.authenticationFailed
        }
        return record
    }

    /// Keeps the keychain in step with a record that arrived through sync.
    private func keepSecret(of object: SealedObject) throws {
        let record = try openedOutside(id: object.id, sealed: object.meta)
        try secrets?.save(try record.credential.keychainData, as: Self.secretName(record.outside.id, account: account))
    }

    // MARK: Drafts

    /// Every draft that opens, newest first. One that won't is left out and left alone.
    public func drafts() throws -> [MailDraft] {
        var found: [(MailDraft, Date)] = []
        for id in try ids(Self.draftSuffix) {
            guard let meta = try store.read(name(id, Self.draftSuffix)), let body = try store.read(name(id, Self.draftBodySuffix)),
                  let opened = try? openedDraft(id: id, meta: meta, body: body)
            else { continue }
            found.append(opened)
        }
        return found.sorted { ($0.1, $0.0.id.uuidString) > ($1.1, $1.0.id.uuidString) }.map(\.0)
    }

    public func draft(_ draft: UUID) throws -> MailDraft? {
        let id = Self.draftID(draft, account: account)
        guard let meta = try store.read(name(id, Self.draftSuffix)), let body = try store.read(name(id, Self.draftBodySuffix)) else { return nil }
        return try openedDraft(id: id, meta: meta, body: body).draft
    }

    public func save(_ draft: MailDraft, at now: Date = Date()) throws {
        guard !isClosed else { throw MailVaultError.closed }
        let id = Self.draftID(draft.id, account: account)
        hashes[id] = nil
        var words = draft
        words.attachments = draft.attachments.map { MailDraftAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: Data()) }
        let body = DraftBody(account: account, draft: draft.id, attachments: draft.attachments)
        // The body first, so the words never point at files that aren't there yet.
        try store.write(try seal(body, id: id, purpose: .content), as: name(id, Self.draftBodySuffix))
        try store.write(try seal(DraftRecord(account: account, draft: words, updatedAt: now), id: id, purpose: .metadata), as: name(id, Self.draftSuffix))
        try store.delete(deletionName(id))
    }

    /// Sent or thrown away. The removal reaches other devices through sync.
    public func deleteDraft(_ draft: UUID) throws {
        guard !isClosed else { throw MailVaultError.closed }
        let id = Self.draftID(draft, account: account)
        guard try store.read(name(id, Self.draftSuffix)) != nil || store.read(name(id, Self.draftBodySuffix)) != nil else { return }
        try store.write(Data(), as: deletionName(id))
        try store.delete(name(id, Self.draftSuffix))
        try store.delete(name(id, Self.draftBodySuffix))
        hashes[id] = nil
    }

    private func openedDraft(id: UUID, meta: Data, body: Data) throws -> (draft: MailDraft, updatedAt: Date) {
        let record = try open(DraftRecord.self, meta, id: id, purpose: .metadata)
        let files = try open(DraftBody.self, body, id: id, purpose: .content)
        guard record.account == account, files.account == account, files.draft == record.draft.id,
              Self.draftID(record.draft.id, account: account) == id,
              files.attachments.map(\.id) == record.draft.attachments.map(\.id)
        else { throw CryptoError.authenticationFailed }
        var draft = record.draft
        draft.attachments = files.attachments
        return (draft, record.updatedAt)
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
        case .mailMarks: return try openedMarks(id: object.id, sealed: object.meta).updatedAt
        case .mailSettings: return try openedSettings(id: object.id, sealed: object.meta).updatedAt
        // Pins are merged, never chosen between by date, so this only proves the object opens.
        case .mailKeys:
            _ = try openedKeys(id: object.id, sealed: object.meta)
            return .distantPast
        case .mailDraft:
            guard let body = object.body else { throw CryptoError.malformedCiphertext }
            return try openedDraft(id: object.id, meta: object.meta, body: body).updatedAt
        case .mailOutside: return try openedOutside(id: object.id, sealed: object.meta).updatedAt
        default: throw CryptoError.authenticationFailed
        }
    }

    private func suffix(for kind: ContentKind) -> String? {
        switch kind {
        case .mailMarks: Self.marksSuffix
        case .mailSettings: Self.settingsSuffix
        case .mailKeys: Self.keysSuffix
        case .mailDraft: Self.draftSuffix
        case .mailOutside: Self.outsideSuffix
        default: nil
        }
    }

    /// The synced file under this ID, if there is one.
    private func synced(_ id: UUID) throws -> (kind: ContentKind, data: Data)? {
        if let data = try store.read(name(id, Self.marksSuffix)) { return (.mailMarks, data) }
        if let data = try store.read(name(id, Self.settingsSuffix)) { return (.mailSettings, data) }
        if let data = try store.read(name(id, Self.keysSuffix)) { return (.mailKeys, data) }
        if let data = try store.read(name(id, Self.draftSuffix)) { return (.mailDraft, data) }
        if let data = try store.read(name(id, Self.outsideSuffix)) { return (.mailOutside, data) }
        return nil
    }
}

extension MailVault: SyncArea {
    /// Marks, settings, pinned keys, drafts, and outside accounts. Messages have no kind here, so sync
    /// can never see them.
    public nonisolated var kinds: Set<ContentKind> { [.mailMarks, .mailSettings, .mailKeys, .mailDraft, .mailOutside] }

    /// Only this account's. Another account's files on this device stay out of this account's sync.
    public func sealedObjectIDs() throws -> [UUID] {
        // A crash can stop an erase halfway. The record says what was meant, so finish it.
        if !isClosed {
            for id in try deletedObjectIDs() {
                for suffix in [Self.marksSuffix, Self.draftSuffix, Self.draftBodySuffix, Self.outsideSuffix] where try store.read(name(id, suffix)) != nil {
                    try store.delete(name(id, suffix))
                    hashes[id] = nil
                }
            }
        }
        var found: [UUID] = []
        for id in try ids(Self.marksSuffix) {
            if let sealed = try store.read(name(id, Self.marksSuffix)), (try? openedMarks(id: id, sealed: sealed)) == nil { continue }
            found.append(id)
        }
        let settings = Self.settingsID(account: account)
        if try store.read(name(settings, Self.settingsSuffix)) != nil { found.append(settings) }
        // Pins still in old settings move over first, so they sync too.
        if !isClosed { _ = try? pins() }
        let keys = Self.keysID(account: account)
        if try store.read(name(keys, Self.keysSuffix)) != nil { found.append(keys) }
        for id in try ids(Self.draftSuffix) {
            guard let meta = try store.read(name(id, Self.draftSuffix)), let body = try store.read(name(id, Self.draftBodySuffix)),
                  (try? openedDraft(id: id, meta: meta, body: body)) != nil
            else { continue }
            found.append(id)
        }
        for id in try ids(Self.outsideSuffix) {
            guard let sealed = try store.read(name(id, Self.outsideSuffix)), (try? openedOutside(id: id, sealed: sealed)) != nil else { continue }
            found.append(id)
        }
        return found
    }

    public func sealedHash(of id: UUID) throws -> String? {
        if let known = hashes[id] { return known }
        let hash = try sealedObject(id)?.hash
        hashes[id] = hash
        return hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        guard let (kind, meta) = try synced(id) else { return nil }
        guard kind == .mailDraft else { return SealedObject(id: id, kind: kind, meta: meta, body: nil) }
        guard let body = try store.read(name(id, Self.draftBodySuffix)) else { return nil }
        return SealedObject(id: id, kind: kind, meta: meta, body: body)
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        _ = try updatedAt(object)
        return object
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw MailVaultError.closed }
        guard let suffix = suffix(for: object.kind), (object.kind == .mailDraft) == (object.body != nil) else {
            throw CryptoError.authenticationFailed
        }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        if expected == nil, try store.read(deletionName(object.id)) != nil { throw SyncError.changedLocally }
        _ = try updatedAt(object)
        if object.kind == .mailKeys { return try merge(object) }
        if object.kind == .mailOutside {
            guard secrets != nil else { throw OutsideAccountError.unavailable }
            try keepSecret(of: object)
        }
        if let body = object.body { try store.write(body, as: name(object.id, Self.draftBodySuffix)) }
        try store.write(object.meta, as: name(object.id, suffix))
        hashes[object.id] = nil
    }

    /// Pins are never removed because the server says so: a stolen session could delete them, and the
    /// next message from that person would look like first contact. They stay, and the next sync sends
    /// them back.
    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {
        guard !isClosed else { throw MailVaultError.closed }
        guard try sealedHash(of: id) == expected else { throw SyncError.changedLocally }
        guard let (kind, sealed) = try synced(id), let suffix = suffix(for: kind), kind != .mailKeys else { return }
        // A sign-in is gone for good, never kept in a trash. A stolen session could use this to remove
        // an account, which only disconnects it until it's added again.
        if kind == .mailOutside {
            if let record = try? openedOutside(id: id, sealed: sealed) {
                try secrets?.delete(Self.secretName(record.outside.id, account: account))
            }
            try store.delete(name(id, suffix))
            hashes[id] = nil
            return
        }
        // The stamp goes first, so a crash can't leave trash that's never cleaned up.
        try store.write(Data(ISO8601DateFormatter().string(from: Date()).utf8), as: trashStampName(id))
        try store.write(sealed, as: name(id, suffix) + ".trash")
        if kind == .mailDraft, let body = try store.read(name(id, Self.draftBodySuffix)) {
            try store.write(body, as: name(id, Self.draftBodySuffix) + ".trash")
            try store.delete(name(id, Self.draftBodySuffix))
        }
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
            try store.delete(name(id, Self.draftSuffix) + ".trash")
            try store.delete(name(id, Self.draftBodySuffix) + ".trash")
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
    ///
    /// Pins aren't chosen between. Taking the server's copy here means `store`, which merges it into the
    /// pins already here, so nothing is lost, and the next sync sends the union back.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        guard local.kind == remote.kind else { throw CryptoError.authenticationFailed }
        if local.kind == .mailKeys {
            _ = try updatedAt(local)
            _ = try updatedAt(remote)
            return .keepRemote
        }
        return try updatedAt(local) >= updatedAt(remote) ? .keepLocal : .keepRemote
    }

    /// Whatever arrives, older, newer, or from another device, joins the pins already here. The copy
    /// that arrived is kept as it is when it already holds everything, so this device and the server
    /// agree; otherwise the union is kept and goes back up on the next sync.
    private func merge(_ object: SealedObject) throws {
        let incoming = try openedKeys(id: object.id, sealed: object.meta).pins
        let local = try? storedPins()
        let merged = (local ?? MailPins()).merging(incoming)
        if merged == incoming {
            try store.write(object.meta, as: name(object.id, Self.keysSuffix))
            hashes[object.id] = nil
        } else if merged != local {
            try write(merged)
        }
    }
}

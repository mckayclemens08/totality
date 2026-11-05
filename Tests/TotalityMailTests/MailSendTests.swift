import CryptoKit
import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

/// The mail server as it's being built for mail between accounts, wrapping exactly as it does: what the
/// sender's device sealed goes inside the standard outer seal to the recipient, under one line naming
/// the signed-in sender. It can't read either layer.
private actor PostOffice {
    struct Box {
        let account: UUID
        let publicKey: Data
        var files: [UUID: (sealed: Data, received: Date)] = [:]
    }

    private(set) var boxes: [String: Box] = [:]
    private(set) var deliveries = 0
    var isOffline = false
    /// Stands in for a server that lies about who sent something.
    var claimedSender: String?

    func set(offline: Bool) { isOffline = offline }
    /// Stands in for a server that takes deliveries but won't keep the sender's own copy.
    var refusesKeep = false
    func set(refusesKeep: Bool) { self.refusesKeep = refusesKeep }
    /// A reserved name, written by hand on the server, that delivers to another name's mailbox.
    func alias(_ name: String, to owner: String) { aliases[name] = owner }
    private var aliases: [String: String] = [:]
    private func box(for name: String) -> String { aliases[name] ?? name }
    func set(claimedSender: String?) { self.claimedSender = claimedSender }

    func publish(_ name: String, account: UUID, publicKey: Data) throws -> MailKeyPublication {
        if let box = boxes[name] {
            guard box.publicKey == publicKey else { throw MailServerError.keyConflict }
            return .alreadyThere
        }
        boxes[name] = Box(account: account, publicKey: publicKey)
        return .published
    }

    func files(of name: String) -> [UUID: (sealed: Data, received: Date)] { boxes[name]?.files ?? [:] }

    func remove(_ ids: Set<UUID>, from name: String) -> Int {
        let count = ids.filter { boxes[name]?.files[$0] != nil }.count
        for id in ids { boxes[name]?.files[id] = nil }
        return count
    }

    /// Stands in for a server that hands out a key of its own for a name, to read or forge its mail.
    private var swappedKeys: [String: Data] = [:]
    func swapKey(of name: String, for key: Data) { swappedKeys[name] = key }

    func key(of name: String) throws -> Data? {
        if isOffline { throw MailServerError.offline }
        return swappedKeys[name] ?? boxes[box(for: name)]?.publicKey
    }

    /// Puts any file at all in a box, as a stolen sign-in or the server itself could.
    func plant(_ sealed: Data, in name: String, id: UUID, at date: Date) {
        boxes[name]?.files[id] = (sealed, date)
    }

    /// Wraps what someone sealed in the standard outer seal with a line naming whoever it likes, as the
    /// server itself could.
    func mint(_ inner: Data, to name: String, claiming sender: String, id: UUID, at date: Date) throws {
        guard let box = boxes[name] else { return }
        let facts = #"{"version":1,"received":"\#(Self.iso(date))","spam":null,"from":"\#(sender)","to":"\#(name)"}"#
        plant(try Self.outerSeal(Data(facts.utf8) + Data([0x0A]) + inner, to: box.publicKey, mailbox: box.account, message: id), in: name, id: id, at: date)
    }

    func deliver(from sender: String, to name: String, id: UUID, sealed: Data, at date: Date) throws -> MailDeliveryAnswer {
        if isOffline { throw MailServerError.offline }
        let owner = box(for: name)
        guard var box = boxes[owner] else { return .noSuchAddress }
        guard box.files[id] == nil else { return .delivered }
        let facts = #"{"version":1,"received":"\#(Self.iso(date))","spam":null,"from":"\#(claimedSender ?? sender)","to":"\#(name)"}"#
        box.files[id] = (try Self.outerSeal(Data(facts.utf8) + Data([0x0A]) + sealed, to: box.publicKey, mailbox: box.account, message: id), date)
        boxes[owner] = box
        deliveries += 1
        return .delivered
    }

    func keep(_ name: String, id: UUID, sealed: Data, at date: Date) throws {
        if isOffline { throw MailServerError.offline }
        if refusesKeep { throw MailServerError.unavailable }
        guard boxes[name] != nil else { throw MailServerError.unavailable }
        boxes[name]?.files[id] = (sealed, date)
    }

    /// The server's own sealing, as `server/mail/mail.mjs` does it.
    static func outerSeal(_ plaintext: Data, to publicKey: Data, mailbox: UUID, message: UUID) throws -> Data {
        let info = Data("totality/mail/v1".utf8)
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        let ids = withUnsafeBytes(of: mailbox.uuid) { Data($0) } + withUnsafeBytes(of: message.uuid) { Data($0) }
        return Data([1]) + sender.encapsulatedKey + (try sender.seal(plaintext, authenticating: info + ids))
    }

    /// What anyone holding a public key can make: the direct format with the right AAD, in HPKE base
    /// mode, so it names a sender without proving it.
    static func baseModeDirect(_ letter: Data, to publicKey: Data, from sender: String, recipient name: String, message: UUID) throws -> Data {
        let info = Data("totality/mail-direct/v2".utf8)
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        var hpke = try HPKE.Sender(recipientKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        let aad = info + Data(sender.utf8) + Data([0]) + Data(name.utf8) + Data([0]) + withUnsafeBytes(of: message.uuid) { Data($0) }
        return Data([1]) + hpke.encapsulatedKey + (try hpke.seal(letter, authenticating: aad))
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// One signed-in account's view of the post office. The account always comes from the sign-in.
private struct Counter: MailServer {
    let office: PostOffice
    let name: String
    let account: UUID
    let date: Date

    func publish(publicKey: Data) async throws -> MailKeyPublication {
        try await office.publish(name, account: account, publicKey: publicKey)
    }

    func list() async throws -> MailServerList {
        let entries = await office.files(of: name).map { MailServerEntry(id: $0.key, size: $0.value.sealed.count, received: $0.value.received) }
        return MailServerList(messages: entries, used: entries.reduce(0) { $0 + $1.size }, limit: 1_073_741_824)
    }

    func message(_ id: UUID) async throws -> Data {
        guard let file = await office.files(of: name)[id] else { throw MailServerError.unavailable }
        return file.sealed
    }

    func delete(_ ids: Set<UUID>) async throws -> Int { await office.remove(ids, from: name) }
    func recipientKey(_ name: String) async throws -> Data? { try await office.key(of: name) }

    func deliver(to recipient: String, id: UUID, sealed: Data) async throws -> MailDeliveryAnswer {
        try await office.deliver(from: name, to: recipient, id: id, sealed: sealed, at: date)
    }

    func keep(id: UUID, sealed: Data) async throws { try await office.keep(name, id: id, sealed: sealed, at: date) }
}

/// One person on one device: their key, their vault, and their store.
private struct Person {
    let name: String
    let account: UUID
    let root: ContentRootKey
    let disk: MailMemoryStore
    let vault: MailVault
    let store: ServerMailStore

    var address: MailAddress { MailAddress(address: "\(name)@usetotality.com") }
}

@Suite struct MailSendTests {
    private let date = Date(timeIntervalSince1970: 1_793_870_000)

    private func person(_ name: String, at office: PostOffice, canPublish: Bool = true) async throws -> Person {
        let account = UUID()
        let root = try ContentRootKey.generate()
        let disk = MailMemoryStore()
        let vault = MailVault(store: disk, rootKey: root, account: account.uuidString.lowercased())
        let counter = Counter(office: office, name: name, account: account, date: date)
        let store = try ServerMailStore(
            account: account.uuidString.lowercased(), rootKey: root, vault: vault, server: counter,
            canPublish: { canPublish }, username: { name }, now: { date }
        )
        if canPublish { _ = try await store.open { _ in } }
        return Person(name: name, account: account, root: root, disk: disk, vault: vault, store: store)
    }

    private func inbox(of person: Person) async throws -> [MailMessage] {
        try await person.store.open { _ in }.mailbox.messages.filter { $0.marks.folder == .inbox }
    }

    // MARK: Between two accounts

    @Test("User 1 writes to user 2, who reads it, proved, from user 1, and replies in the same thread")
    func twoUsers() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        let draft = MailDraft(
            to: [MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")],
            bcc: [MailAddress(address: "mckay+archive@usetotality.com")],
            subject: "Lost Lake on Saturday",
            body: "The permit came through. Meet at the trailhead at 7, and bring layers: it's 4°C up there at dawn.",
            attachments: [MailDraftAttachment(name: "permit.txt", mimeType: "text/plain", data: Data("Permit LL-4471, 4 hikers".utf8))]
        )
        try await mckay.store.save(draft)

        let result = try await mckay.store.send(draft)
        #expect(result.deliveredToEveryone)
        #expect(result.keptCopy)
        #expect(result.remaining == nil)
        #expect(try await mckay.vault.drafts().isEmpty, "A sent draft is gone")

        let received = try #require(try await inbox(of: dana).first { $0.subject == "Lost Lake on Saturday" })
        #expect(received.from.address == "mckay@usetotality.com")
        #expect(received.route == .betweenAccounts)
        #expect(received.proof == .proved)
        #expect(received.sentBy?.address == "mckay@usetotality.com")
        #expect(received.marks.isUnread)
        #expect(received.bcc.isEmpty, "Bcc never reaches anyone")
        #expect(received.body == .plain(draft.body))
        #expect(MailWording.route(for: received) == "Sealed by the sender's device. Totality's servers carry it but can't open it.")
        #expect(MailWording.warning(for: received) == nil)
        let permit = try #require(received.attachments.first)
        #expect(permit.name == "permit.txt")
        #expect(try await dana.store.data(of: permit.id) == Data("Permit LL-4471, 4 hikers".utf8))

        // The Bcc reached mckay's own address too, and his Sent copy keeps who it went to.
        let mailbox = try await mckay.store.open { _ in }.mailbox
        let sent = try #require(mailbox.messages.first { $0.id == result.sent })
        #expect(sent.marks.folder == .sent)
        #expect(!sent.marks.isUnread)
        #expect(sent.route == .betweenAccounts)
        #expect(sent.bcc.map(\.address) == ["mckay+archive@usetotality.com"])
        #expect(MailWording.route(for: sent) == "Sealed by your device. Totality's servers can't read it.")
        #expect(await office.files(of: "mckay")[sent.id]?.sealed.first == MailSentKey.version, "The Sent copy is in its own format")
        #expect(mailbox.conversations(in: .folder(.sent)).count == 1)
        #expect(mailbox.messages.contains { $0.marks.folder == .inbox && $0.subject == "Lost Lake on Saturday" })

        // Dana replies, and it lands in mckay's thread.
        let reply = MailDraft.reply(to: received, me: "dana@usetotality.com")
        var answer = reply
        answer.body = "Count me in. I'll drive." + reply.body
        #expect(try await dana.store.send(answer).deliveredToEveryone)
        let back = try #require(try await inbox(of: mckay).first { $0.subject == "Re: Lost Lake on Saturday" })
        #expect(back.proof == .proved)
        #expect(back.conversationID == sent.conversationID)
    }

    @Test("Mail to a reserved name opens for the account it's delivered to")
    func reservedName() async throws {
        let office = PostOffice()
        let dana = try await person("dana", at: office)
        let mckay = try await person("mckay", at: office)
        await office.alias("postmaster", to: "mckay")
        let draft = MailDraft(
            to: [MailAddress(address: "postmaster@usetotality.com")],
            subject: "Bounce from the Lost Lake list",
            body: "Two of last week's trip reminders came back from a closed address. Can you take a look?"
        )
        let result = try await dana.store.send(draft)
        #expect(result.deliveredToEveryone)
        let received = try #require(try await inbox(of: mckay).first { $0.subject == "Bounce from the Lost Lake list" })
        #expect(received.proof == .proved)
        #expect(received.from.address == "dana@usetotality.com")
    }

    @Test("A From line naming someone other than the sender isn't proved, and says who really sent it")
    func forgedFrom() async throws {
        let office = PostOffice()
        let mckay = try MailKey(root: try await person("mckay", at: office).root)
        let dana = try await person("dana", at: office)
        // mckay's device writes a message claiming to be from sam, sealed honestly as from mckay.
        for (id, from) in [(UUID(), "Sam Ortiz <sam@usetotality.com>"), (UUID(), "mckay@usetotality.com, sam@usetotality.com")] {
            let raw = Data("From: \(from)\r\nTo: dana@usetotality.com\r\nSubject: Change of plan \(id)\r\n\r\nSend the permit fee to me instead.\r\n".utf8)
            let sealed = try mckay.sealDirect(raw, to: try #require(try await office.key(of: "dana")), from: "mckay", recipient: "dana", message: id)
            _ = try await office.deliver(from: "mckay", to: "dana", id: id, sealed: sealed, at: date)
        }
        // A +tag and a capital letter are still mckay.
        let tagged = UUID()
        let raw = Data("From: McKay <McKay+Hikes@usetotality.com>\r\nTo: dana@usetotality.com\r\nSubject: Tagged\r\n\r\nStill me.\r\n".utf8)
        let sealed = try mckay.sealDirect(raw, to: try #require(try await office.key(of: "dana")), from: "mckay", recipient: "dana", message: tagged)
        _ = try await office.deliver(from: "mckay", to: "dana", id: tagged, sealed: sealed, at: date)

        let messages = try await inbox(of: dana)
        let forged = messages.filter { $0.subject.hasPrefix("Change of plan") }
        #expect(forged.count == 2)
        for message in forged {
            #expect(message.proof == .unproved)
            #expect(message.route == .betweenAccounts)
            #expect(message.sentBy?.address == "mckay@usetotality.com")
        }
        let single = try #require(forged.first { $0.from.address == "sam@usetotality.com" })
        #expect(MailWording.warning(for: single) == "This message says it's from sam@usetotality.com, but it was sent by mckay@usetotality.com. Be careful with its links and attachments.")
        #expect(messages.first { $0.subject == "Tagged" }?.proof == .proved)
    }

    @Test("A server that names the wrong sender gets a message that won't open")
    func serverCantRelabel() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        await office.set(claimedSender: "sam")
        _ = try await mckay.store.send(MailDraft(to: [dana.address], subject: "Saturday", body: "Bring the permit."))
        let messages = try await dana.store.open { _ in }.mailbox.messages
        #expect(messages.count == 1)
        #expect(messages.allSatisfy { $0.isUnreadable })
    }

    @Test("Mail sealed for one person won't open for another, even if the server moves it")
    func cantBeMoved() async throws {
        let office = PostOffice()
        let mckay = try MailKey(root: try await person("mckay", at: office).root)
        let dana = try await person("dana", at: office)
        let id = UUID()
        let raw = Data("From: mckay@usetotality.com\r\nTo: priya@usetotality.com\r\nSubject: For Priya\r\n\r\nPrivate.\r\n".utf8)
        // Sealed to dana's key but naming priya as the recipient, as if the server had redirected it.
        let sealed = try mckay.sealDirect(raw, to: try #require(try await office.key(of: "dana")), from: "mckay", recipient: "priya", message: id)
        _ = try await office.deliver(from: "mckay", to: "dana", id: id, sealed: sealed, at: date)
        let moved = try await dana.store.open { _ in }.mailbox.messages
        #expect(moved.count == 1 && moved.allSatisfy { $0.isUnreadable })
    }

    // MARK: Forged mail

    private func standardFacts(_ date: Date, extra: String) -> Data {
        Data(#"{"version":1,"received":"\#(PostOffice.iso(date))","spam":null,\#(extra)}"#.utf8) + Data([0x0A])
    }

    @Test("A standard seal claiming to be a Sent copy lands in the Inbox, not in Sent")
    func plantedSentCopyIsntSent() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let id = UUID()
        let mckayKey = try #require(try await office.key(of: "mckay"))
        let raw = standardFacts(date, extra: #""sent":true"#)
            + Data("From: mckay@usetotality.com\r\nTo: dana@usetotality.com\r\nSubject: Wire it today\r\n\r\nI already sent the account number.\r\n".utf8)
        // Anyone can make this: it's sealed to mckay's public key, under his own mailbox ID.
        await office.plant(try PostOffice.outerSeal(raw, to: mckayKey, mailbox: mckay.account, message: id), in: "mckay", id: id, at: date)
        let message = try #require(try await mckay.store.open { _ in }.mailbox.messages.first { $0.id == id })
        #expect(message.marks.folder == .inbox)
        #expect(message.marks.isUnread)
        #expect(message.route == .outside)
        #expect(message.proof == .unproved)
    }

    @Test("A standard seal from a third party naming a Totality sender isn't proved")
    func thirdPartyClaimingASenderIsntProved() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        _ = try await person("dana", at: office)
        let mckayKey = try #require(try await office.key(of: "mckay"))
        let letter = Data("From: dana@usetotality.com\r\nTo: mckay@usetotality.com\r\nSubject: New bank details\r\n\r\nUse the new account.\r\n".utf8)
        // The thief can't seal as dana, only to mckay: base mode, or auth mode with a key of their own.
        let thief = try MailKey(root: try ContentRootKey.generate())
        let base = UUID(), own = UUID()
        let baseInner = try PostOffice.baseModeDirect(letter, to: mckayKey, from: "dana", recipient: "mckay", message: base)
        let ownInner = try thief.sealDirect(letter, to: mckayKey, from: "dana", recipient: "mckay", message: own)
        for (id, inner) in [(base, baseInner), (own, ownInner)] {
            let raw = standardFacts(date, extra: #""from":"dana","to":"mckay""#) + inner
            await office.plant(try PostOffice.outerSeal(raw, to: mckayKey, mailbox: mckay.account, message: id), in: "mckay", id: id, at: date)
        }
        let messages = try await mckay.store.open { _ in }.mailbox.messages
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.isUnreadable })
    }

    @Test("A Sent copy sealed under another content key won't open")
    func sentCopyFromAnotherKeyWontOpen() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let id = UUID()
        let raw = standardFacts(date, extra: #""sent":true"#) + Data("To: dana@usetotality.com\r\nSubject: Planted\r\n\r\nNot mine.\r\n".utf8)
        let planted = try MailSentKey(root: try ContentRootKey.generate()).seal(raw, account: mckay.account, message: id)
        await office.plant(planted, in: "mckay", id: id, at: date)
        let message = try #require(try await mckay.store.open { _ in }.mailbox.messages.first { $0.id == id })
        #expect(message.isUnreadable)
        #expect(message.marks.folder != .sent)
    }

    @Test("Mail the server mints in someone's name isn't proved")
    func serverMintedMailIsntProved() async throws {
        let office = PostOffice()
        _ = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        let danaKey = try #require(try await office.key(of: "dana"))
        let letter = Data("From: mckay@usetotality.com\r\nTo: dana@usetotality.com\r\nSubject: Permit fee\r\n\r\nPay it to this account instead.\r\n".utf8)
        let server = try MailKey(root: try ContentRootKey.generate())
        let base = UUID(), wrongKey = UUID()
        let baseInner = try PostOffice.baseModeDirect(letter, to: danaKey, from: "mckay", recipient: "dana", message: base)
        try await office.mint(baseInner, to: "dana", claiming: "mckay", id: base, at: date)
        try await office.mint(
            try server.sealDirect(letter, to: danaKey, from: "mckay", recipient: "dana", message: wrongKey), to: "dana", claiming: "mckay", id: wrongKey, at: date
        )
        let messages = try await dana.store.open { _ in }.mailbox.messages
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.isUnreadable })
        #expect(!messages.contains { $0.proof == .proved && !$0.isUnreadable })
    }

    @Test("A recipient whose key changed since the first message is refused and reported")
    func changedKeyOnSendIsRefused() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        #expect(try await mckay.store.send(MailDraft(to: [dana.address], subject: "Saturday", body: "Meet at 7.")).deliveredToEveryone)
        let pinned = try #require(try await mckay.vault.pins().key(for: "dana"))
        let danaKey = try await office.key(of: "dana")
        #expect(pinned == danaKey)

        // The server now hands out its own key for dana, to read what's sent to her.
        let server = try MailKey(root: try ContentRootKey.generate())
        await office.swapKey(of: "dana", for: try server.publicKey())
        let draft = MailDraft(to: [dana.address], subject: "Sunday", body: "The gate code is 4471.")
        let before = await office.deliveries
        let result = try await mckay.store.send(draft)
        #expect(result.recipients == [.init(address: dana.address, outcome: .keyChanged)])
        #expect(result.sent == nil)
        #expect(result.remaining == draft)
        #expect(await office.deliveries == before)
        #expect(try await mckay.vault.pins().key(for: "dana") == pinned, "The pin is never replaced")
        #expect(MailWording.outcome(.keyChanged).contains("This person's key changed"))
    }

    @Test("A sender whose key changed since the first message isn't proved, and says so")
    func changedKeyOnReceiveWarns() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        #expect(try await mckay.store.send(MailDraft(to: [dana.address], subject: "Saturday", body: "Meet at 7.")).deliveredToEveryone)
        #expect(try await inbox(of: dana).first?.proof == .proved)
        #expect(try await dana.vault.pins().key(for: "mckay") != nil, "Pinned on first success")

        // The server swaps mckay's key for its own and mints a message from him with it.
        let server = try MailKey(root: try ContentRootKey.generate())
        await office.swapKey(of: "mckay", for: try server.publicKey())
        let id = UUID()
        let danaKey = try #require(try await office.key(of: "dana"))
        let letter = Data("From: mckay@usetotality.com\r\nTo: dana@usetotality.com\r\nSubject: Change of plan\r\n\r\nSend the permit fee to this account.\r\n".utf8)
        try await office.mint(try server.sealDirect(letter, to: danaKey, from: "mckay", recipient: "dana", message: id), to: "dana", claiming: "mckay", id: id, at: date)

        let changed = try #require(try await inbox(of: dana).first { $0.id == id })
        #expect(!changed.isUnreadable)
        #expect(changed.proof == .unproved)
        #expect(changed.senderKeyChanged)
        let warning = try #require(MailWording.warning(for: changed))
        #expect(warning.contains("key has changed"))
        #expect(MailWording.route(for: changed) == "Totality couldn't confirm who sealed this.", "Never says the sender's device sealed it")
        #expect(warning.contains("mckay@usetotality.com"))

        // Mail mckay really sealed, with the key that was pinned, is unproved too while the server
        // hands out another: the pin opens it, but the server's answer doesn't agree.
        #expect(try await mckay.store.send(MailDraft(to: [dana.address], subject: "Really me", body: "Ignore that.")).deliveredToEveryone)
        let real = try #require(try await inbox(of: dana).first { $0.subject == "Really me" })
        #expect(real.proof == .unproved)
        #expect(real.senderKeyChanged)
    }

    @Test("Pins sync to the person's other devices, and the screens can't drop them")
    func pinsSync() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        _ = try await mckay.store.send(MailDraft(to: [dana.address], subject: "Saturday", body: "Meet at 7."))
        let pins = try await mckay.vault.pins()
        let danaKey = try await office.key(of: "dana")
        #expect(pins.key(for: "dana") == danaKey)

        // Settings saved from the screens never touch the pins.
        try await mckay.store.save(MailSettings(signature: "McKay"))
        #expect(try await mckay.vault.pins() == pins)
        #expect(try await mckay.vault.settings()?.signature == "McKay")

        // The sealed pins, apart from the settings, carry them to another device.
        let id = MailVault.keysID(account: mckay.account.uuidString.lowercased())
        let object = try #require(try await mckay.vault.verifiedObject(id))
        #expect(object.kind == .mailKeys)
        #expect(object.body == nil)
        let mac = MailVault(store: MailMemoryStore(), rootKey: mckay.root, account: mckay.account.uuidString.lowercased())
        try await mac.store(object, ifLocalHash: nil)
        #expect(try await mac.pins() == pins)
        #expect(try await mac.settings() == nil, "Pins arriving don't make settings that could beat the person's")
    }

    @Test("A name pinned to two keys keeps the first, and nothing from or to it is proved")
    func disputedNameIsntProved() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        #expect(try await mckay.store.send(MailDraft(to: [dana.address], subject: "Saturday", body: "Meet at 7.")).deliveredToEveryone)
        #expect(try await inbox(of: dana).first?.proof == .proved)
        let first = try #require(try await dana.vault.pins().key(for: "mckay"))

        // Dana's other device was handed another key for mckay, later, and its pins arrive by sync.
        let account = dana.account.uuidString.lowercased()
        let other = MailVault(store: MailMemoryStore(), rootKey: dana.root, account: account)
        try await other.pin("mckay", key: try MailKey(root: try ContentRootKey.generate()).publicKey(), at: date.addingTimeInterval(60))
        let id = MailVault.keysID(account: account)
        let incoming = try #require(try await other.verifiedObject(id))
        try await dana.vault.store(incoming, ifLocalHash: try await dana.vault.sealedHash(of: id))
        let pins = try await dana.vault.pins()
        #expect(pins.key(for: "mckay") == first, "The first pin stays")
        #expect(pins.isDisputed("mckay"))

        #expect(try await mckay.store.send(MailDraft(to: [dana.address], subject: "Sunday", body: "Bring water.")).deliveredToEveryone)
        let sunday = try #require(try await inbox(of: dana).first { $0.subject == "Sunday" })
        #expect(sunday.proof == .unproved)
        #expect(MailWording.route(for: sunday) != MailWording.betweenAccountsReceived)
        let reply = try await dana.store.send(MailDraft(to: [MailAddress(address: "mckay@usetotality.com")], subject: "Re: Sunday", body: "Will do."))
        #expect(reply.recipients.map(\.outcome) == [.keyChanged])
    }

    @Test("Mail already kept stops being proved when synced pins show its key wasn't the first")
    func laterPinsUnproveKeptMail() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        #expect(try await mckay.store.send(MailDraft(to: [dana.address], subject: "Saturday", body: "Meet at 7.")).deliveredToEveryone)
        let saturday = try #require(try await inbox(of: dana).first { $0.subject == "Saturday" })
        #expect(saturday.proof == .proved)

        // Dana's other device pinned a different key for mckay first, and its pins only now arrive.
        let account = dana.account.uuidString.lowercased()
        let other = MailVault(store: MailMemoryStore(), rootKey: dana.root, account: account)
        try await other.pin("mckay", key: try MailKey(root: try ContentRootKey.generate()).publicKey(), at: date.addingTimeInterval(-60))
        let id = MailVault.keysID(account: account)
        let incoming = try #require(try await other.verifiedObject(id))
        try await dana.vault.store(incoming, ifLocalHash: try await dana.vault.sealedHash(of: id))
        #expect(try await dana.vault.pins().isDisputed("mckay"))

        let again = try #require(try await inbox(of: dana).first { $0.subject == "Saturday" })
        #expect(again.proof == .unproved)
        #expect(again.senderKeyChanged)
        #expect(MailWording.route(for: again) != MailWording.betweenAccountsReceived)
    }

    @Test("Sending and opening at once don't lose each other's pins")
    func sendAndOpenKeepBothPins() async throws {
        for _ in 0..<5 {
            let office = PostOffice()
            let mckay = try await person("mckay", at: office)
            let dana = try await person("dana", at: office)
            let sam = try await person("sam", at: office)
            #expect(try await sam.store.send(MailDraft(to: [mckay.address], subject: "Trailhead", body: "Parking is full by 8.")).deliveredToEveryone)

            async let sent = mckay.store.send(MailDraft(to: [dana.address], subject: "Saturday", body: "Meet at 7."))
            async let opened = mckay.store.open { _ in }
            let (result, _) = try await (sent, opened)
            #expect(result.deliveredToEveryone)

            let pins = try await mckay.vault.pins()
            let danaKey = try await office.key(of: "dana")
            let samKey = try await office.key(of: "sam")
            #expect(pins.key(for: "dana") == danaKey)
            #expect(pins.key(for: "sam") == samKey)
        }
    }

    @Test("Pins kept in settings before they moved out are moved over, not lost")
    func legacyPinsMoveOver() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let account = mckay.account.uuidString.lowercased()
        let danaKey = Data(repeating: 7, count: 32)
        // Settings as an older build sealed them, with the pins inside.
        struct OldSettings: Encodable {
            let folders: [MailOwnFolder] = []
            let blockedSenders: [String] = []
            let alwaysLoadImages: [String] = []
            let signature = "McKay"
            let knownKeys: [String: Data]
        }
        struct OldRecord: Encodable {
            let account: String
            let settings: OldSettings
            let updatedAt: Date
        }
        let id = MailVault.settingsID(account: account)
        let record = OldRecord(account: account, settings: OldSettings(knownKeys: ["dana": danaKey]), updatedAt: date)
        let sealed = try ContentCipher.seal(
            JSONEncoder().encode(record), key: mckay.root.objectKey(for: id, purpose: .metadata), objectID: id
        )
        let disk = MailMemoryStore()
        try disk.write(sealed, as: id.uuidString.lowercased() + ".mail.settings")
        let vault = MailVault(store: disk, rootKey: mckay.root, account: account)
        #expect(try await vault.settings()?.signature == "McKay")
        #expect(try await vault.sealedObjectIDs().contains(MailVault.keysID(account: account)), "Moved over, so they sync")
        #expect(try await vault.pins().key(for: "dana") == danaKey)
    }

    // MARK: Who it goes to

    @Test("More than ten recipients is refused before anything goes out")
    func tenAtMost() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        _ = try await person("dana", at: office)
        let eleven = (1...10).map { MailAddress(address: "hiker\($0)@usetotality.com") } + [MailAddress(address: "dana@usetotality.com")]
        let draft = MailDraft(to: Array(eleven.prefix(6)), cc: Array(eleven[6..<9]), bcc: Array(eleven[9...]), subject: "Trail crew", body: "Saturday, 7am.")
        await #expect(throws: MailSendError.tooManyRecipients(11)) { try await mckay.store.send(draft) }
        #expect(await office.deliveries == 0)
        await #expect(throws: MailSendError.noRecipients) { try await mckay.store.send(MailDraft(subject: "Notes to self")) }
    }

    @Test("Outside and unknown addresses are reported one by one, and the draft keeps only them")
    func outsideIsReported() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let dana = try await person("dana", at: office)
        let sam = MailAddress(name: "Sam Ortiz", address: "sam@ortizbuilds.example")
        let ghost = MailAddress(address: "nobody_here@usetotality.com")
        let draft = MailDraft(to: [dana.address, sam], cc: [ghost], subject: "Saturday", body: "Meet at 7.")
        try await mckay.store.save(draft)

        let result = try await mckay.store.send(draft)
        #expect(result.recipients == [
            .init(address: dana.address, outcome: .delivered),
            .init(address: sam, outcome: .outsideNotYet),
            .init(address: ghost, outcome: .noSuchAddress),
        ])
        #expect(!result.deliveredToEveryone)
        #expect(result.sent != nil)
        let remaining = try #require(result.remaining)
        #expect(remaining.to == [sam])
        #expect(remaining.cc == [ghost])
        #expect(try await mckay.vault.drafts() == [remaining])
        #expect(try await inbox(of: dana).count == 1)
        #expect(await office.files(of: "sam").isEmpty)
    }

    @Test("Nobody reachable means nothing in Sent, and the draft stays whole")
    func nobodyReached() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        _ = try await person("dana", at: office)
        await office.set(offline: true)
        let draft = MailDraft(to: [MailAddress(address: "dana@usetotality.com"), MailAddress(address: "sam@ortizbuilds.example")], subject: "Saturday", body: "Meet at 7.")
        let result = try await mckay.store.send(draft)
        #expect(result.recipients.map(\.outcome) == [.offline, .outsideNotYet])
        #expect(result.sent == nil)
        #expect(result.remaining == draft)
        #expect(try await mckay.vault.drafts() == [draft])
    }

    @Test("A Sent copy the server didn't keep stays in Sent on the device, and reaches the server on the next open")
    func unkeptCopyIsRetried() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        _ = try await person("dana", at: office)
        await office.set(refusesKeep: true)
        let draft = MailDraft(to: [MailAddress(address: "dana@usetotality.com")], subject: "Lost Lake", body: "Meet at 7.")

        let result = try await mckay.store.send(draft)
        #expect(result.deliveredToEveryone)
        #expect(!result.keptCopy)
        let id = try #require(result.sent)
        #expect(await office.files(of: "mckay")[id] == nil)
        #expect(try await mckay.vault.unkept() == [id])

        // Still refused: it isn't pruned, though the server doesn't list it.
        var mailbox = try await mckay.store.open { _ in }.mailbox
        #expect(mailbox.messages.first { $0.id == id }?.marks.folder == .sent)
        #expect(try await mckay.vault.unkept() == [id])

        // A later device that knows nothing of it opens what the server kept, so the server must have it.
        await office.set(refusesKeep: false)
        mailbox = try await mckay.store.open { _ in }.mailbox
        #expect(mailbox.messages.first { $0.id == id }?.subject == "Lost Lake")
        #expect(await office.files(of: "mckay")[id] != nil)
        #expect(try await mckay.vault.unkept().isEmpty)

        // And it opens from the server's copy alone.
        let fresh = MailVault(store: MailMemoryStore(), rootKey: mckay.root, account: mckay.account.uuidString.lowercased())
        let counter = Counter(office: office, name: "mckay", account: mckay.account, date: date)
        let other = try ServerMailStore(
            account: mckay.account.uuidString.lowercased(), rootKey: mckay.root, vault: fresh, server: counter,
            canPublish: { true }, username: { "mckay" }, now: { date }
        )
        let elsewhere = try await other.open { _ in }.mailbox
        #expect(elsewhere.messages.first { $0.id == id }?.marks.folder == .sent)
    }

    @Test("Nothing sends before the device's key has joined the backup")
    func waitsForTheBackup() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office, canPublish: false)
        await #expect(throws: MailStoreError.waitingForBackup) {
            try await mckay.store.send(MailDraft(to: [MailAddress(address: "dana@usetotality.com")], subject: "Hi", body: "Hello."))
        }
    }

    // MARK: Drafts

    @Test("Drafts stay sealed on disk, and sync whole to another device")
    func draftsAreSealed() async throws {
        let office = PostOffice()
        let mckay = try await person("mckay", at: office)
        let draft = MailDraft(
            to: [MailAddress(name: "Dana Whitfield", address: "dana@usetotality.com")], subject: "Lost Lake permit",
            body: "Parking is cash only at the ranger station.",
            attachments: [MailDraftAttachment(name: "ranger-station-map.png", mimeType: "image/png", data: Data("PNG ranger station".utf8))]
        )
        try await mckay.store.save(draft)
        #expect(try await mckay.store.open { _ in }.mailbox.drafts == [draft])

        for name in try mckay.disk.names() {
            let bytes = try #require(try mckay.disk.read(name))
            let text = String(decoding: bytes, as: UTF8.self)
            for secret in ["dana", "Lost Lake", "cash only", "ranger-station", "PNG ranger"] {
                #expect(!text.contains(secret), "\(name) holds \(secret)")
            }
            #expect(!name.contains(draft.id.uuidString.lowercased()), "The file isn't named for the draft")
        }

        let ids = try await mckay.vault.sealedObjectIDs()
        let id = try #require(ids.first)
        let object = try #require(try await mckay.vault.verifiedObject(id))
        #expect(object.kind == .mailDraft)
        #expect(object.body != nil)
        let mac = MailVault(store: MailMemoryStore(), rootKey: mckay.root, account: mckay.account.uuidString.lowercased())
        try await mac.store(object, ifLocalHash: nil)
        #expect(try await mac.drafts() == [draft])

        // Another account's vault on the same key won't take it.
        let other = MailVault(store: MailMemoryStore(), rootKey: mckay.root, account: UUID().uuidString.lowercased())
        await #expect(throws: CryptoError.self) { try await other.store(object, ifLocalHash: nil) }

        try await mckay.store.discard(draft: draft.id)
        #expect(try await mckay.vault.drafts().isEmpty)
        #expect(try await mckay.vault.deletedObjectIDs() == [object.id])
    }

    @Test("A draft's files can't be swapped for another draft's")
    func draftBodiesStayWithTheirWords() async throws {
        let root = try ContentRootKey.generate()
        let account = UUID().uuidString.lowercased()
        let vault = MailVault(store: MailMemoryStore(), rootKey: root, account: account)
        let first = MailDraft(to: [MailAddress(address: "dana@usetotality.com")], subject: "Permit", attachments: [MailDraftAttachment(name: "permit.txt", mimeType: "text/plain", data: Data("LL-4471".utf8))])
        let second = MailDraft(to: [MailAddress(address: "dana@usetotality.com")], subject: "Map", attachments: [MailDraftAttachment(name: "map.txt", mimeType: "text/plain", data: Data("North fork".utf8))])
        try await vault.save(first)
        try await vault.save(second)
        let a = try #require(try await vault.sealedObject(MailVault.draftID(first.id, account: account)))
        let b = try #require(try await vault.sealedObject(MailVault.draftID(second.id, account: account)))
        let swapped = SealedObject(id: a.id, kind: .mailDraft, meta: a.meta, body: b.body)
        let elsewhere = MailVault(store: MailMemoryStore(), rootKey: root, account: account)
        await #expect(throws: CryptoError.self) { try await elsewhere.store(swapped, ifLocalHash: nil) }
        let noBody = SealedObject(id: a.id, kind: .mailDraft, meta: a.meta, body: nil)
        await #expect(throws: CryptoError.self) { try await elsewhere.store(noBody, ifLocalHash: nil) }
    }

    // MARK: The model

    @MainActor @Test func theModelKeepsDraftsAndSends() async throws {
        let store = SampleMailStore(now: date, pause: .zero)
        let model = MailModel(store: store, now: { date })
        await model.load()
        var draft = MailDraft(to: [MailAddress(address: "dana@usetotality.com")], subject: "Saturday")
        await model.save(draft)
        #expect(model.mailbox.drafts == [draft])
        draft.body = "Meet at 7."
        draft.cc = [MailAddress(address: "sam@ortizbuilds.example")]
        await model.save(draft)
        #expect(model.mailbox.drafts == [draft])

        let result = try await model.send(draft)
        #expect(result.recipients.map(\.outcome) == [.delivered, .outsideNotYet])
        #expect(model.mailbox.drafts.map(\.cc) == [[MailAddress(address: "sam@ortizbuilds.example")]])
        #expect(model.mailbox.drafts.first?.to.isEmpty == true)
        #expect(model.mailbox.messages.contains { $0.marks.folder == .sent && $0.subject == "Saturday" })

        await model.save(MailDraft())
        #expect(model.mailbox.drafts.count == 1, "An empty draft isn't kept")
    }
}

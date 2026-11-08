import Foundation
import Testing
import TotalityCore
@testable import TotalityMail

private let clientID = "204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0.apps.googleusercontent.com"
private let alice = "8d3f6a1e-2b4c-4e5f-9a7b-0c1d2e3f4a5b"
private let bob = "3c7b1d9e-5f2a-4b6c-8d0e-1a2b3c4d5e6f"
private let today = Date(timeIntervalSince1970: 1_794_000_000)

/// A real-looking message, with Google's or Apple's checks at the top when given.
private func mail(_ subject: String, from: String = "Rosa Delgado <rosa@delgado-studio.com>", checks: String? = nil, body: String = "The drawings for the kitchen are attached. Can we meet Thursday?") -> String {
    var lines: [String] = []
    if let checks { lines.append("Authentication-Results: \(checks)") }
    lines += [
        "From: \(from)",
        "To: McKay Clemens <mckay.clemens@gmail.com>",
        "Subject: \(subject)",
        "Date: Fri, 06 Nov 2026 16:20:00 +0000",
        "Message-ID: <\(abs(subject.hashValue))@delgado-studio.com>",
        "Content-Type: text/plain; charset=utf-8",
        "",
        body,
    ]
    return lines.joined(separator: "\r\n") + "\r\n"
}

private struct NoMailServer: MailServer {
    func publish(publicKey: Data) async throws -> MailKeyPublication { throw MailServerError.unavailable }
    func list() async throws -> MailServerList { throw MailServerError.unavailable }
    func message(_ id: UUID) async throws -> Data { throw MailServerError.unavailable }
    func delete(_ ids: Set<UUID>) async throws -> Int { Issue.record("deleted on Totality's server"); throw MailServerError.unavailable }
    func recipientKey(_ name: String) async throws -> Data? { throw MailServerError.unavailable }
    func deliver(to name: String, id: UUID, sealed: Data) async throws -> MailDeliveryAnswer { throw MailServerError.unavailable }
    func keep(id: UUID, sealed: Data) async throws { throw MailServerError.unavailable }
    func sendOutside(_ message: MailOutsideMessage) async throws -> MailOutsideAnswer { throw MailServerError.unavailable }
}

/// iCloud's IMAP server, with an Inbox the test fills, and the folders messages can be moved to.
final class ICloudInbox: OutsideWireMaker, @unchecked Sendable {
    struct Message { var uid: UInt32; var raw: String; var seen: Bool; var flagged = false }
    private let lock = NSLock()
    /// Each folder's UIDVALIDITY and messages.
    private var folders: [String: (validity: UInt32, messages: [Message])] = [
        "INBOX": (1_730_000_000, []), "Archive": (1_730_000_100, []), "Junk": (1_730_000_200, []), "Deleted Messages": (1_730_000_300, []),
    ]
    private var nextUID: UInt32 = 9000
    var acceptsPassword = true
    /// Says where moved mail went, as iCloud does. Off, it's like a server without UIDPLUS.
    var saysCopyUID = true
    private(set) var commands: [String] = []

    /// The Inbox, newest first, as the test fills it.
    var messages: [(uid: UInt32, raw: String, seen: Bool)] {
        get { lock.withLock { folders["INBOX"]!.messages.map { ($0.uid, $0.raw, $0.seen) } } }
        set { lock.withLock { folders["INBOX"]!.messages = newValue.map { Message(uid: $0.uid, raw: $0.raw, seen: $0.seen) } } }
    }

    func folder(_ name: String) -> [Message] { lock.withLock { folders[name]?.messages ?? [] } }

    func change(_ uid: UInt32, seen: Bool? = nil, flagged: Bool? = nil) {
        lock.withLock {
            guard let index = folders["INBOX"]!.messages.firstIndex(where: { $0.uid == uid }) else { return }
            if let seen { folders["INBOX"]!.messages[index].seen = seen }
            if let flagged { folders["INBOX"]!.messages[index].flagged = flagged }
        }
    }

    /// Moved at iCloud, by the person in another app.
    func moveAway(_ uid: UInt32, to name: String) {
        lock.withLock {
            guard let index = folders["INBOX"]!.messages.firstIndex(where: { $0.uid == uid }) else { return }
            var message = folders["INBOX"]!.messages.remove(at: index)
            message.uid = nextUID; nextUID += 1
            folders[name]!.messages.insert(message, at: 0)
        }
    }

    static func uids(_ set: Substring) -> Set<UInt32> {
        var found = Set<UInt32>()
        for part in set.split(separator: ",") {
            let ends = part.split(separator: ":").compactMap { UInt32($0) }
            if ends.count == 2 { found.formUnion(ends[0]...ends[1]) } else if let one = ends.first { found.insert(one) }
        }
        return found
    }

    func open(_ endpoint: OutsideEndpoint) -> any OutsideWire {
        #expect(endpoint == OutsideProvider.icloud.reading)
        let accepts = acceptsPassword
        let selected = Locked<String?>(nil)
        return ScriptedWire(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN MOVE UIDPLUS] ready\r\n") { [weak self] line in
            guard let self else { return nil }
            return self.lock.withLock { self.answer(line, accepts: accepts, selected: selected) }
        }
    }

    private func answer(_ line: String, accepts: Bool, selected: Locked<String?>) -> String? {
        commands.append(line)
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let tag = parts[0], rest = parts.count > 2 ? parts[2] : ""
        func unquote(_ text: String) -> String { text.hasPrefix("\"") ? String(text.dropFirst().dropLast()) : text }
        switch parts[1] {
        case "AUTHENTICATE": return accepts ? "\(tag) OK signed in\r\n" : "\(tag) NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"
        case "EXAMINE", "SELECT":
            let name = unquote(rest)
            guard let folder = folders[name] else { return "\(tag) NO no such folder\r\n" }
            selected.update { $0 = name }
            return "* \(folder.messages.count) EXISTS\r\n* OK [UIDVALIDITY \(folder.validity)] UIDs valid\r\n\(tag) OK \(parts[1]) completed\r\n"
        case "LIST":
            return "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"\r\n"
                + "* LIST (\\HasNoChildren \\Junk) \"/\" \"Junk\"\r\n* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Messages\"\r\n\(tag) OK LIST completed\r\n"
        case "UID":
            guard let name = selected.value, var folder = folders[name] else { return "\(tag) BAD nothing selected\r\n" }
            if rest.hasPrefix("SEARCH SINCE ") {
                return "* SEARCH \(folder.messages.map { String($0.uid) }.joined(separator: " "))\r\n\(tag) OK SEARCH completed\r\n"
            }
            let words = rest.split(separator: " ", maxSplits: 2)
            guard words.count >= 2 else { return "\(tag) BAD what\r\n" }
            let wanted = Self.uids(words[1])
            switch words[0] {
            case "FETCH":
                var answer = ""
                for (index, message) in folder.messages.enumerated() where wanted.contains(message.uid) {
                    let flags = [message.seen ? "\\Seen" : nil, message.flagged ? "\\Flagged" : nil].compactMap { $0 }.joined(separator: " ")
                    if rest.hasSuffix("(UID FLAGS)") {
                        answer += "* \(index + 1) FETCH (UID \(message.uid) FLAGS (\(flags)))\r\n"
                    } else {
                        answer += "* \(index + 1) FETCH (UID \(message.uid) FLAGS (\(flags)) INTERNALDATE \"06-Nov-2026 16:20:00 +0000\" BODY[] {\(message.raw.utf8.count)}\r\n\(message.raw))\r\n"
                    }
                }
                return answer + "\(tag) OK FETCH completed\r\n"
            case "STORE":
                let change = String(words[2])
                for index in folder.messages.indices where wanted.contains(folder.messages[index].uid) {
                    let on = change.hasPrefix("+")
                    if change.contains("\\Seen") { folder.messages[index].seen = on }
                    if change.contains("\\Flagged") { folder.messages[index].flagged = on }
                }
                folders[name] = folder
                return "\(tag) OK STORE completed\r\n"
            case "MOVE":
                let target = unquote(String(words[2]))
                guard folders[target] != nil else { return "\(tag) NO no such folder\r\n" }
                var copied: [String] = [], made: [String] = []
                for message in folder.messages where wanted.contains(message.uid) {
                    var moved = message
                    moved.uid = nextUID; nextUID += 1
                    folders[target]!.messages.insert(moved, at: 0)
                    copied.append(String(message.uid)); made.append(String(moved.uid))
                }
                folder.messages.removeAll { wanted.contains($0.uid) }
                folders[name] = folder
                guard !copied.isEmpty else { return "\(tag) OK MOVE completed\r\n" }
                let said = saysCopyUID ? "* OK [COPYUID \(folders[target]!.validity) \(copied.joined(separator: ",")) \(made.joined(separator: ","))] Moved\r\n" : ""
                return said + "* 1 EXPUNGE\r\n\(tag) OK MOVE completed\r\n"
            default: return "\(tag) BAD what\r\n"
            }
        case "LOGOUT": return "* BYE\r\n\(tag) OK bye\r\n"
        default: return "\(tag) BAD what\r\n"
        }
    }

    var sent: [String] { lock.withLock { commands } }
}

@Suite struct OutsideReadingTests {
    private func store(
        google fake: FakeGoogle = FakeGoogle(), icloud: ICloudInbox = ICloudInbox(), keys: MailMemoryKeys = MailMemoryKeys(),
        account: String = alice, blobs: MailMemoryStore = MailMemoryStore(), root: ContentRootKey? = nil
    ) throws -> (ServerMailStore, MailVault) {
        let root = try root ?? ContentRootKey.generate()
        let vault = MailVault(store: blobs, rootKey: root, account: account, secrets: keys)
        let store = try ServerMailStore(
            account: account, rootKey: root, vault: vault, server: NoMailServer(), canPublish: { false }, username: { "mckay" },
            now: { today }, outsideCheck: OutsideSignInCheck(maker: icloud), google: GoogleOAuth(clientID: clientID, http: fake, pause: .zero)
        )
        return (store, vault)
    }

    private func addGmail(_ store: ServerMailStore, _ fake: FakeGoogle) async throws -> OutsideAccount {
        let request = try await store.googleSignIn(for: nil, sending: false)
        return try await store.addGoogle(request, callback: fake.page(request.url, request.callbackScheme))
    }

    @Test func gmailsInboxArrivesLabelledAndSealedOnTheDevice() async throws {
        let fake = FakeGoogle()
        fake.inbox = [
            ("18f3a2b4c5d6e7f8", mail("Kitchen drawings", checks: "mx.google.com; dkim=pass header.i=@delgado-studio.com; spf=pass smtp.mailfrom=rosa@delgado-studio.com; dmarc=pass (p=QUARANTINE) header.from=delgado-studio.com"), true, today.addingTimeInterval(-3600)),
            ("18f3a2b4c5d6e7f9", mail("Invoice 2041", from: "Harbor Electric <billing@harborelectric.com>"), false, today.addingTimeInterval(-7200)),
        ]
        let (store, vault) = try store(google: fake)
        let added = try await addGmail(store, fake)
        let progress = Locked<[OutsideDownload]>([])
        let result = try #require(await store.downloadOutside { download in progress.update { $0.append(download) } })
        #expect(progress.value.last == OutsideDownload(address: "mckay.clemens@gmail.com", done: 2))
        #expect(result.problems.isEmpty)
        let outside = result.mailbox.messages.filter { $0.outsideAccount != nil }
        #expect(outside.count == 2)
        let kitchen = try #require(outside.first { $0.subject == "Kitchen drawings" })
        #expect(kitchen.outsideAccount == OutsideAccountLabel(id: added.id, provider: .gmail, address: "mckay.clemens@gmail.com"))
        #expect(kitchen.marks.isUnread && kitchen.marks.folder == .inbox)
        // Google's own checks at the top prove the sender; without them nothing is proved.
        #expect(kitchen.proof == .proved)
        #expect(outside.first { $0.subject == "Invoice 2041" }?.proof == .unproved)
        #expect(outside.first { $0.subject == "Invoice 2041" }?.marks.isUnread == false)
        #expect(MailWording.route(for: kitchen) == OutsideWording.kept(by: .gmail))
        #expect(try await vault.fetched().count == 2)
        // The next open downloads only what's new.
        fake.inbox.insert(("18f3a2b4c5d6e800", mail("Thursday works"), true, today), at: 0)
        _ = await store.downloadOutside { _ in }
        #expect(fake.fetched == ["18f3a2b4c5d6e7f8", "18f3a2b4c5d6e7f9", "18f3a2b4c5d6e800"])
        #expect(added.provider == .gmail)
    }

    @Test func gmailsTabsAndLabelsShowAsTheirOwnPlaces() async throws {
        let fake = FakeGoogle()
        fake.inbox = [
            ("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today.addingTimeInterval(-3600)),
            ("18f3a2b4c5d6e7f9", mail("Maya tagged you in a photo", from: "Instagram <no-reply@mail.instagram.com>"), true, today.addingTimeInterval(-7200)),
            ("18f3a2b4c5d6e7fa", mail("Your order has shipped", from: "REI <orders@rei.com>"), false, today.addingTimeInterval(-9000)),
            ("18f3a2b4c5d6e7fb", mail("Q4 planning notes", from: "Dana Ortiz <dana@northwind.co>"), false, today.addingTimeInterval(-86_400)),
        ]
        fake.labelsOf = ["18f3a2b4c5d6e7f9": ["CATEGORY_SOCIAL"], "18f3a2b4c5d6e7fa": ["CATEGORY_UPDATES"], "18f3a2b4c5d6e7fb": ["Label_7"]]
        fake.archived = ["18f3a2b4c5d6e7fb"]
        fake.userLabels = [("Label_7", "Productivity"), ("Label_9", "Receipts")]
        let (store, _) = try store(google: fake)
        let added = try await addGmail(store, fake)
        let mailbox = try #require(await store.downloadOutside { _ in }).mailbox
        func subjects(_ place: MailPlace) -> Set<String> {
            Set(mailbox.conversations(in: place).flatMap(\.messages).map(\.subject))
        }
        // The Inbox is Primary, as in Gmail.
        #expect(subjects(.folder(.inbox)) == ["Kitchen drawings"])
        #expect(subjects(.outside(added.id, "CATEGORY_SOCIAL")) == ["Maya tagged you in a photo"])
        #expect(subjects(.outside(added.id, "CATEGORY_UPDATES")) == ["Your order has shipped"])
        // Under a label but out of the Inbox: archived, and in its label.
        #expect(subjects(.outside(added.id, "Label_7")) == ["Q4 planning notes"])
        #expect(subjects(.folder(.archive)) == ["Q4 planning notes"])
        // Tabs that hold nothing don't show; the person's labels always do.
        let places = try #require(mailbox.outsidePlaces.first)
        #expect(places.account.address == "mckay.clemens@gmail.com")
        #expect(places.labels.map(\.name) == ["Social", "Updates", "Productivity", "Receipts"])
        #expect(mailbox.name(of: .outside(added.id, "Label_7")) == "Productivity")
        // Moved to Social at Gmail later: the next open moves it here, without downloading it again.
        fake.labelsOf["18f3a2b4c5d6e7f8"] = ["CATEGORY_SOCIAL"]
        let after = try #require(await store.downloadOutside { _ in }).mailbox
        #expect(after.conversations(in: .folder(.inbox)).isEmpty)
        #expect(after.conversations(in: .outside(added.id, "CATEGORY_SOCIAL")).count == 2)
        #expect(fake.fetched.count == 4)
    }

    @Test func gmailSayingTooFastIsWaitedOutAndOneBadLabelIsSkipped() async throws {
        let fake = FakeGoogle()
        fake.inbox = [
            ("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today),
            ("18f3a2b4c5d6e7fb", mail("Q4 planning notes"), false, today.addingTimeInterval(-60)),
        ]
        fake.labelsOf = ["18f3a2b4c5d6e7fb": ["Label_7"]]
        fake.userLabels = [("Label_7", "Productivity"), ("Label_9", "Receipts")]
        fake.tooFast = 3
        fake.refusedLabel = "Label_9"
        let (store, _) = try store(google: fake)
        let added = try await addGmail(store, fake)
        let result = try #require(await store.downloadOutside { _ in })
        #expect(result.problems.isEmpty)
        #expect(result.mailbox.conversations(in: .outside(added.id, "Label_7")).count == 1)
        #expect(result.mailbox.conversations(in: .folder(.inbox)).count == 2)
    }

    @Test func gmailTurningTheInboxDownSaysWhy() async throws {
        let fake = FakeGoogle()
        fake.refusedLabel = "INBOX"
        let (store, _) = try store(google: fake)
        _ = try await addGmail(store, fake)
        let result = try #require(await store.downloadOutside { _ in })
        #expect(result.problems == ["mckay.clemens@gmail.com: Gmail said: Label not reachable."])
    }

    // MARK: Changes going both ways

    private func addICloud(_ store: ServerMailStore) async throws -> OutsideAccount {
        try await store.addOutside(OutsideSignIn(provider: .icloud, address: "mckay.clemens@icloud.com", appPassword: "hjkl-qwer-tyui-asdf")!)
    }

    private func message(_ mailbox: Mailbox?, _ subject: String) throws -> MailMessage {
        try #require(mailbox?.messages.first { $0.subject == subject })
    }

    @Test func readStarAndArchiveInTotalityReachGmail() async throws {
        let fake = FakeGoogle()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        let (store, _) = try store(google: fake)
        _ = try await addGmail(store, fake)
        var kitchen = try message(await store.downloadOutside { _ in }?.mailbox, "Kitchen drawings")
        kitchen.marks.isUnread = false
        kitchen.marks.isStarred = true
        kitchen.marks.folder = .archive
        try await store.save([kitchen.id: kitchen.marks])
        #expect(fake.changes == ["modify 18f3a2b4c5d6e7f8 +STARRED -UNREAD -INBOX -SPAM"])
        #expect(fake.labels(of: "18f3a2b4c5d6e7f8") == ["STARRED"])
        // The next open agrees with Gmail, so nothing goes again and nothing comes back.
        let after = try message(await store.downloadOutside { _ in }?.mailbox, "Kitchen drawings")
        #expect(fake.changes.count == 1)
        #expect(after.marks.folder == .archive && !after.marks.isUnread && after.marks.isStarred)
        // Back to the Inbox.
        try await store.save([kitchen.id: MailMarks(folder: .inbox, isUnread: false, isStarred: true)])
        #expect(fake.changes.last == "modify 18f3a2b4c5d6e7f8 +INBOX -SPAM")
    }

    @Test func changesMadeInGmailComeIntoTotality() async throws {
        let fake = FakeGoogle()
        fake.inbox = [
            ("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today),
            ("18f3a2b4c5d6e7f9", mail("Invoice 2041", from: "Harbor Electric <billing@harborelectric.com>"), true, today.addingTimeInterval(-60)),
            ("18f3a2b4c5d6e7fa", mail("You won a cruise", from: "Prize Desk <win@prize.example>"), true, today.addingTimeInterval(-120)),
        ]
        let (store, _) = try store(google: fake)
        _ = try await addGmail(store, fake)
        _ = await store.downloadOutside { _ in }
        fake.unreadNow["18f3a2b4c5d6e7f8"] = false
        fake.starred.insert("18f3a2b4c5d6e7f8")
        fake.archived.insert("18f3a2b4c5d6e7f8")
        fake.trashed.insert("18f3a2b4c5d6e7f9")
        fake.spam.insert("18f3a2b4c5d6e7fa")
        let mailbox = await store.downloadOutside { _ in }?.mailbox
        let kitchen = try message(mailbox, "Kitchen drawings")
        #expect(kitchen.marks.folder == .archive && !kitchen.marks.isUnread && kitchen.marks.isStarred)
        let invoice = try message(mailbox, "Invoice 2041")
        #expect(invoice.marks.folder == .trash && invoice.marks.trashedAt == today && invoice.marks.trashedFrom == .inbox)
        #expect(try message(mailbox, "You won a cruise").marks.folder == .spam)
        // None of it goes back to Gmail.
        #expect(fake.changes.isEmpty)
    }

    @Test func whenBothChangeTheSameThingTotallysChangeWins() async throws {
        let fake = FakeGoogle()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        let (store, vault) = try store(google: fake)
        let added = try await addGmail(store, fake)
        let kitchen = try message(await store.downloadOutside { _ in }?.mailbox, "Kitchen drawings")
        // Changes made offline here: Gmail isn't reached when it's saved.
        try await vault.save(added, credential: .google(GoogleGrant(refreshToken: "1//refresh-1", canSend: false, canChange: false)))
        try await store.save([kitchen.id: MailMarks(folder: .inbox, isUnread: false, isStarred: false)])
        #expect(fake.changes.isEmpty)
        // At Gmail, meanwhile: read stays unread there but it's starred and archived.
        fake.starred.insert("18f3a2b4c5d6e7f8")
        fake.archived.insert("18f3a2b4c5d6e7f8")
        try await vault.save(added, credential: .google(GoogleGrant(refreshToken: "1//refresh-1", canSend: false)))
        let after = try message(await store.downloadOutside { _ in }?.mailbox, "Kitchen drawings")
        // Read here goes there; starred and archived there come here.
        #expect(fake.changes == ["modify 18f3a2b4c5d6e7f8 -UNREAD"])
        #expect(!after.marks.isUnread && after.marks.isStarred && after.marks.folder == .archive)
    }

    @Test func aGmailThatOnlyReadsKeepsItsChangesUntilAllowed() async throws {
        let fake = FakeGoogle()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        let (store, vault) = try store(google: fake)
        var added = try await addGmail(store, fake)
        try await vault.save(added, credential: .google(GoogleGrant(refreshToken: "1//refresh-old", canSend: false, canChange: false)))
        let kitchen = try message(await store.downloadOutside { _ in }?.mailbox, "Kitchen drawings")
        try await store.save([kitchen.id: MailMarks(folder: .trash, isUnread: false, trashedAt: today, trashedFrom: .inbox)])
        _ = await store.downloadOutside { _ in }
        #expect(fake.changes.isEmpty)
        // Gmail still says unread and in the Inbox, and Totality keeps what was done here.
        #expect(try message(await store.downloadOutside { _ in }?.mailbox, "Kitchen drawings").marks.folder == .trash)
        added = try #require(try await store.outsideAccounts().first)
        let request = try await store.googleSignIn(for: added.id, sending: false)
        try await store.allowGoogleChanges(added.id, request, callback: fake.page(request.url, request.callbackScheme))
        _ = await store.downloadOutside { _ in }
        #expect(fake.changes == ["trash 18f3a2b4c5d6e7f8", "modify 18f3a2b4c5d6e7f8 -UNREAD"])
    }

    @Test func deletingForeverMovesGmailsCopyToItsTrashOnly() async throws {
        let fake = FakeGoogle()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        let (store, vault) = try store(google: fake)
        _ = try await addGmail(store, fake)
        let id = try message(await store.downloadOutside { _ in }?.mailbox, "Kitchen drawings").id
        try await store.erase([id])
        #expect(fake.changes == ["trash 18f3a2b4c5d6e7f8"])
        _ = await store.downloadOutside { _ in }
        #expect(fake.changes.count == 1)
        #expect(try await vault.fetched().isEmpty)
    }

    @Test func readFlaggedAndMovedInTotalityReachICloud() async throws {
        let icloud = ICloudInbox()
        icloud.messages = [(4211, mail("Rent for December"), false), (4210, mail("Photos from the lake"), false)]
        let (store, _) = try store(icloud: icloud)
        _ = try await addICloud(store)
        let mailbox = await store.downloadOutside { _ in }?.mailbox
        let rent = try message(mailbox, "Rent for December"), photos = try message(mailbox, "Photos from the lake")
        try await store.save([
            rent.id: MailMarks(folder: .inbox, isUnread: false, isStarred: true),
            photos.id: MailMarks(folder: .archive, isUnread: true),
        ])
        let commands = icloud.sent.map { $0.split(separator: " ").dropFirst().joined(separator: " ") }
        #expect(commands.contains("UID STORE 4211 +FLAGS.SILENT (\\Seen)"))
        #expect(commands.contains("UID STORE 4211 +FLAGS.SILENT (\\Flagged)"))
        #expect(commands.contains("UID MOVE 4210 \"Archive\""))
        #expect(icloud.folder("Archive").map(\.raw) == [mail("Photos from the lake")])
        #expect(icloud.messages.map(\.uid) == [4211])
        // Back to the Inbox: it gets a new UID there, and isn't downloaded twice.
        try await store.save([photos.id: MailMarks(folder: .inbox, isUnread: true)])
        #expect(icloud.messages.count == 2)
        let after = await store.downloadOutside { _ in }?.mailbox
        #expect(after?.messages.filter { $0.subject == "Photos from the lake" }.count == 1)
        #expect(try message(after, "Photos from the lake").marks.folder == .inbox)
        // Deleted forever here: to iCloud's Deleted Messages.
        try await store.erase([rent.id])
        #expect(icloud.folder("Deleted Messages").count == 1)
    }

    @Test func changesMadeInICloudComeIntoTotality() async throws {
        let icloud = ICloudInbox()
        icloud.messages = [(4211, mail("Rent for December"), false), (4210, mail("Photos from the lake"), false)]
        let (store, _) = try store(icloud: icloud)
        _ = try await addICloud(store)
        _ = await store.downloadOutside { _ in }
        icloud.change(4211, seen: true, flagged: true)
        icloud.moveAway(4210, to: "Archive")
        let mailbox = await store.downloadOutside { _ in }?.mailbox
        let rent = try message(mailbox, "Rent for December")
        #expect(!rent.marks.isUnread && rent.marks.isStarred && rent.marks.folder == .inbox)
        #expect(try message(mailbox, "Photos from the lake").marks.folder == .archive)
        #expect(!icloud.sent.contains { $0.contains("STORE") || $0.contains("MOVE") })
    }

    @Test func iCloudMailMovedWithoutANewUIDIsLeftAlone() async throws {
        let icloud = ICloudInbox()
        icloud.saysCopyUID = false
        icloud.messages = [(4210, mail("Photos from the lake"), false)]
        let (store, _) = try store(icloud: icloud)
        _ = try await addICloud(store)
        let photos = try message(await store.downloadOutside { _ in }?.mailbox, "Photos from the lake")
        try await store.save([photos.id: MailMarks(folder: .archive, isUnread: true)])
        #expect(icloud.folder("Archive").count == 1)
        let moves = icloud.sent.filter { $0.contains("MOVE") }.count
        try await store.save([photos.id: MailMarks(folder: .inbox, isUnread: false)])
        _ = await store.downloadOutside { _ in }
        #expect(icloud.sent.filter { $0.contains("MOVE") || $0.contains("STORE") }.count == moves)
        #expect(try message(await store.downloadOutside { _ in }?.mailbox, "Photos from the lake").marks.folder == .inbox)
    }

    @Test func eachFieldGoesOneWay() {
        let base = OutsideRemoteState(place: .inbox, isUnread: true, isStarred: false)
        let mine = OutsideRemoteState(place: .inbox, isUnread: false, isStarred: false)
        let outcome = OutsideReconcile.outcome(base: base, mine: mine, seen: OutsideSeen(place: .archive, isUnread: true, isStarred: true))
        #expect(outcome.push == OutsideRemoteState(place: .archive, isUnread: false, isStarred: true))
        #expect(outcome.agreedIfPushFails == OutsideRemoteState(place: .archive, isUnread: true, isStarred: true))
        #expect(OutsideReconcile.outcome(base: base, mine: nil, seen: .unknown) == .init(push: nil, pull: nil, agreed: base, agreedIfPushFails: base))
        #expect(IMAPConnection.uidSet([7, 3, 4, 5, 9, 10]) == "3:5,7,9:10")
        let line = Data("* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Messages\"".utf8)
        #expect(IMAPConnection.listed(line)?.name == "Deleted Messages" && IMAPConnection.listed(line)?.flags.contains("\\trash") == true)
        #expect(IMAPConnection.listed(Data("* LIST () \"/\" \"Bad\r\nName\"".utf8)) == nil)
    }

    @Test func aCloudflareCheckInsideGmailProvesNothing() async throws {
        let fake = FakeGoogle()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Wire the deposit today", from: "Bank <alerts@bank.example>", checks: "mx.cloudflare.net; dmarc=pass header.from=bank.example"), true, today)]
        let (store, _) = try store(google: fake)
        _ = try await addGmail(store, fake)
        let result = try #require(await store.downloadOutside { _ in })
        #expect(result.mailbox.messages.first?.proof == .unproved)
    }

    @Test func iCloudReadsTheInboxReadOnlyWithoutMarkingAnythingRead() async throws {
        let icloud = ICloudInbox()
        icloud.messages = [
            (4211, mail("Rent for December", from: "Dana Whitfield <dana.whitfield@icloud.com>", checks: "dmarc.icloud.com; dmarc=pass header.from=icloud.com"), false),
            (4210, mail("Photos from the lake", from: "Sam Okafor <sam.okafor@me.com>"), true),
        ]
        let (store, _) = try store(icloud: icloud)
        let added = try await store.addOutside(OutsideSignIn(provider: .icloud, address: "mckay.clemens@icloud.com", appPassword: "hjkl-qwer-tyui-asdf")!)
        let result = try #require(await store.downloadOutside { _ in })
        #expect(result.problems.isEmpty)
        let outside = result.mailbox.messages.filter { $0.outsideAccount?.address == added.address }
        #expect(outside.count == 2)
        #expect(outside.first { $0.subject == "Rent for December" }?.marks.isUnread == true)
        #expect(outside.first { $0.subject == "Photos from the lake" }?.marks.isUnread == false)
        #expect(outside.first { $0.subject == "Rent for December" }?.proof == .proved)
        let commands = icloud.sent.map { $0.split(separator: " ").dropFirst().joined(separator: " ") }
        #expect(commands.contains("EXAMINE INBOX"))
        #expect(commands.contains("UID SEARCH SINCE 08-Aug-2026"))
        #expect(commands.contains { $0.hasPrefix("UID FETCH ") && $0.hasSuffix("(UID FLAGS INTERNALDATE BODY.PEEK[])") })
        #expect(!commands.contains { $0.hasPrefix("SELECT") || $0.contains("STORE") })
        // Nothing new, so the second pass fetches nothing.
        _ = await store.downloadOutside { _ in }
        #expect(icloud.sent.filter { $0.contains("BODY.PEEK[]") }.count == 1)
    }

    @Test func oneAccountsProblemSaysWhichAndTheOthersStillDownload() async throws {
        let fake = FakeGoogle(), icloud = ICloudInbox()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        icloud.messages = [(4211, mail("Rent for December"), false)]
        let (store, _) = try store(google: fake, icloud: icloud)
        _ = try await store.addOutside(OutsideSignIn(provider: .icloud, address: "mckay.clemens@icloud.com", appPassword: "hjkl-qwer-tyui-asdf")!)
        _ = try await addGmail(store, fake)
        icloud.acceptsPassword = false
        let result = try #require(await store.downloadOutside { _ in })
        #expect(result.problems == ["mckay.clemens@icloud.com: iCloud didn't accept that address and app password. Check both, or make a new app password."])
        #expect(result.mailbox.messages.map(\.subject) == ["Kitchen drawings"])
        fake.refusesRefresh = true
        let later = try #require(await store.downloadOutside { _ in })
        #expect(later.problems.contains("mckay.clemens@gmail.com: Gmail's sign-in no longer works. Remove the account and add it again."))
        // What was downloaded still opens.
        #expect(later.mailbox.messages.map(\.subject) == ["Kitchen drawings"])
    }

    @Test func deletingDownloadedMailKeepsItGoneAndNeverTouchesTotallysServer() async throws {
        let fake = FakeGoogle()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        let (store, vault) = try store(google: fake)
        _ = try await addGmail(store, fake)
        let id = try #require(await store.downloadOutside { _ in }?.mailbox.messages.first?.id)
        try await store.erase([id])
        #expect(try await vault.fetched().isEmpty)
        let again = try #require(await store.downloadOutside { _ in })
        #expect(again.mailbox.messages.isEmpty)
        #expect(fake.fetched == ["18f3a2b4c5d6e7f8"])
    }

    @Test func removingAnAccountTakesItsDownloadedMailWithIt() async throws {
        let fake = FakeGoogle()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        let (store, vault) = try store(google: fake)
        let added = try await addGmail(store, fake)
        _ = await store.downloadOutside { _ in }
        try await store.removeOutside(added.id)
        #expect(try await vault.fetched().isEmpty)
        #expect(await store.downloadOutside { _ in } == nil)
    }

    @Test func attachmentsOpenFromDownloadedMail() async throws {
        let fake = FakeGoogle()
        let raw = [
            "From: Rosa Delgado <rosa@delgado-studio.com>", "To: mckay.clemens@gmail.com", "Subject: Kitchen drawings",
            "Date: Fri, 06 Nov 2026 16:20:00 +0000", "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"b1\"", "",
            "--b1", "Content-Type: text/plain; charset=utf-8", "", "Drawings attached.",
            "--b1", "Content-Type: text/plain; name=\"measurements.txt\"", "Content-Disposition: attachment; filename=\"measurements.txt\"", "",
            "Counter: 112 in", "--b1--", "",
        ].joined(separator: "\r\n")
        fake.inbox = [("18f3a2b4c5d6e7f8", raw, true, today)]
        let (store, _) = try store(google: fake)
        _ = try await addGmail(store, fake)
        let message = try #require(await store.downloadOutside { _ in }?.mailbox.messages.first)
        let attachment = try #require(message.attachments.first)
        #expect(attachment.name == "measurements.txt")
        #expect(String(decoding: try await store.data(of: attachment.id), as: UTF8.self).contains("Counter: 112 in"))
    }

    @Test func anotherAccountOnTheSameDeviceSeesNoneOfIt() async throws {
        let fake = FakeGoogle(), keys = MailMemoryKeys(), blobs = MailMemoryStore(), root = try ContentRootKey.generate()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        let (mine, _) = try store(google: fake, keys: keys, blobs: blobs, root: root)
        _ = try await addGmail(mine, fake)
        _ = await mine.downloadOutside { _ in }
        let (theirs, theirVault) = try store(google: fake, keys: keys, account: bob, blobs: blobs, root: root)
        #expect(await theirs.downloadOutside { _ in } == nil)
        #expect(try await theirVault.fetched().isEmpty)
    }

    @Test func imapAnswersAreReadWhateverOrderTheyComeIn() throws {
        let body = "Subject: Hi\r\n\r\nSee you at 6) tonight {3}\r\n"
        let line = Data("* 3 FETCH (BODY[] {\(body.utf8.count)}\r\n\(body) UID 77 INTERNALDATE \"6-Nov-2026 09:05:00 -0800\" FLAGS (\\Flagged))".utf8)
        let fetched = try #require(IMAPConnection.fetched(line))
        #expect(fetched.uid == 77 && fetched.isUnread)
        #expect(String(decoding: fetched.raw, as: UTF8.self) == body)
        #expect(fetched.received == ISO8601DateFormatter().date(from: "2026-11-06T17:05:00Z"))
        #expect(IMAPConnection.fetched(Data("* 3 FETCH (UID 77 FLAGS (\\Seen))".utf8)) == nil)
        #expect(IMAPConnection.fetched(Data("* 3 FETCH (UID 77 BODY[] {999}\r\nshort)".utf8)) == nil)
    }

    @Test func onlyGmailsOwnIDsGoIntoAPath() {
        #expect(GoogleOAuth.isGmailID("18f3a2b4c5d6e7f8"))
        #expect(!GoogleOAuth.isGmailID("../../drafts"))
        #expect(!GoogleOAuth.isGmailID("18f3?format=full"))
        #expect(!GoogleOAuth.isGmailID(""))
    }
}

/// Totality's server, unreachable.
private struct OfflineMailServer: MailServer {
    func publish(publicKey: Data) async throws -> MailKeyPublication { throw MailServerError.offline }
    func list() async throws -> MailServerList { throw MailServerError.offline }
    func message(_ id: UUID) async throws -> Data { throw MailServerError.offline }
    func delete(_ ids: Set<UUID>) async throws -> Int { throw MailServerError.offline }
    func recipientKey(_ name: String) async throws -> Data? { throw MailServerError.offline }
    func deliver(to name: String, id: UUID, sealed: Data) async throws -> MailDeliveryAnswer { throw MailServerError.offline }
    func keep(id: UUID, sealed: Data) async throws { throw MailServerError.offline }
    func sendOutside(_ message: MailOutsideMessage) async throws -> MailOutsideAnswer { throw MailServerError.offline }
}

@MainActor
@Suite struct OutsideReadingModelTests {
    @Test func outsideMailJoinsTheInboxEvenWhileTotallysServerIsOffline() async throws {
        let fake = FakeGoogle()
        fake.inbox = [("18f3a2b4c5d6e7f8", mail("Kitchen drawings"), true, today)]
        let root = try ContentRootKey.generate()
        let vault = MailVault(store: MailMemoryStore(), rootKey: root, account: alice, secrets: MailMemoryKeys())
        let store = try ServerMailStore(
            account: alice, rootKey: root, vault: vault, server: OfflineMailServer(), canPublish: { true }, username: { "mckay" },
            now: { today }, google: GoogleOAuth(clientID: clientID, http: fake)
        )
        let request = try await store.googleSignIn(for: nil, sending: false)
        _ = try await store.addGoogle(request, callback: fake.page(request.url, request.callbackScheme))
        let model = MailModel(store: store)
        await model.load()
        #expect(model.mailbox.messages.contains { $0.subject == "Kitchen drawings" && $0.outsideAccount?.provider == .gmail })
        #expect(model.isOffline && model.outsideProblems.isEmpty && model.outsideDownload == nil)
    }
}

/// A value several tasks can change.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

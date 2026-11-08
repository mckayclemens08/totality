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

/// iCloud's IMAP server, with an Inbox the test fills.
private final class ICloudInbox: OutsideWireMaker, @unchecked Sendable {
    private let lock = NSLock()
    var messages: [(uid: UInt32, raw: String, seen: Bool)] = []
    var acceptsPassword = true
    private(set) var commands: [String] = []

    func open(_ endpoint: OutsideEndpoint) -> any OutsideWire {
        #expect(endpoint == OutsideProvider.icloud.reading)
        let messages = self.messages, accepts = acceptsPassword
        return ScriptedWire(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] ready\r\n") { [weak self] line in
            self?.lock.withLock { self?.commands.append(line) }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            let tag = parts[0], rest = parts.count > 2 ? parts[2] : ""
            switch parts[1] {
            case "AUTHENTICATE": return accepts ? "\(tag) OK signed in\r\n" : "\(tag) NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"
            case "EXAMINE": return "* \(messages.count) EXISTS\r\n* OK [UIDVALIDITY 1730000000] UIDs valid\r\n\(tag) OK [READ-ONLY] EXAMINE completed\r\n"
            case "UID" where rest.hasPrefix("SEARCH SINCE "):
                return "* SEARCH \(messages.map { String($0.uid) }.joined(separator: " "))\r\n\(tag) OK SEARCH completed\r\n"
            case "UID" where rest.hasPrefix("FETCH "):
                let wanted = Set(rest.dropFirst(6).prefix { $0 != " " }.split(separator: ",").compactMap { UInt32($0) })
                var answer = ""
                for (index, message) in messages.enumerated() where wanted.contains(message.uid) {
                    let flags = message.seen ? "\\Seen" : ""
                    answer += "* \(index + 1) FETCH (UID \(message.uid) FLAGS (\(flags)) INTERNALDATE \"06-Nov-2026 16:20:00 +0000\" BODY[] {\(message.raw.utf8.count)}\r\n\(message.raw))\r\n"
                }
                return answer + "\(tag) OK FETCH completed\r\n"
            case "LOGOUT": return "* BYE\r\n\(tag) OK bye\r\n"
            default: return "\(tag) BAD what\r\n"
            }
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
            now: { today }, outsideCheck: OutsideSignInCheck(maker: icloud), google: GoogleOAuth(clientID: clientID, http: fake)
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
        #expect(icloud.sent.filter { $0.contains("UID FETCH") }.count == 1)
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

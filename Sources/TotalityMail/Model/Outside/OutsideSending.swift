import Foundation

// Sending from an outside account, through its own provider. Only ever from the person's press on Send,
// after the composer's Undo window, and only from an account whose Send switch is on.

extension GoogleOAuth {
    static let sendURL = URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=media")!

    /// Hands the message to Gmail, which sends it and keeps it in Sent. Returns Gmail's ID for it.
    /// Bcc is in the message for Gmail to read and take out, as Gmail does for its own sends.
    func send(_ raw: Data, accessToken: String) async throws -> String {
        var request = URLRequest(url: Self.sendURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("message/rfc822", forHTTPHeaderField: "Content-Type")
        request.httpBody = raw
        struct Sent: Decodable { let id: String }
        guard let sent = try? JSONDecoder().decode(Sent.self, from: try await gmailAnswer(request)), Self.isGmailID(sent.id) else {
            throw OutsideMailProblem.unexpected
        }
        return sent.id
    }
}

extension SMTPConnection {
    /// How one SMTP send went: who the server took, and whether the message itself was accepted.
    struct Sent: Equatable {
        var taken: [String] = []
        var refused: [String] = []
        /// The message went in and the server said yes.
        var accepted = false
        /// The connection dropped after the message went in, so it may have gone.
        var unsure = false
    }

    /// An address that can go in an SMTP command as it is: ASCII, no spaces, nothing that ends the line.
    static func isPlainAddress(_ address: String) -> Bool {
        (3...254).contains(address.count) && address.contains("@")
            && address.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) && $0 != "<" && $0 != ">" }
    }

    /// One message to every recipient the server takes. The message is dot-stuffed on the way.
    func send(_ raw: Data, from: String, to recipients: [String]) async throws -> Sent {
        guard Self.isPlainAddress(from) else { throw OutsideMailProblem.unexpected }
        var sent = Sent()
        let mail = try await command("MAIL FROM:<\(from)>")
        guard mail.code == 250 else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(mail.lines.joined(separator: " "))) }
        for recipient in recipients {
            guard Self.isPlainAddress(recipient) else { sent.refused.append(recipient); continue }
            let reply = try await command("RCPT TO:<\(recipient)>")
            if reply.code == 250 || reply.code == 251 { sent.taken.append(recipient) } else { sent.refused.append(recipient) }
        }
        guard !sent.taken.isEmpty else {
            _ = try? await command("RSET")
            return sent
        }
        let data = try await command("DATA")
        guard data.code == 354 else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(data.lines.joined(separator: " "))) }
        try await reader.wire.write(Self.dotStuffed(raw))
        do {
            let end = try await reply()
            guard end.code == 250 else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(end.lines.joined(separator: " "))) }
            sent.accepted = true
        } catch let problem as OutsideMailProblem where problem != .unexpected && !Self.isRefusal(problem) {
            sent.unsure = true
        }
        return sent
    }

    private static func isRefusal(_ problem: OutsideMailProblem) -> Bool {
        if case .refused = problem { true } else { false }
    }

    /// A line that starts with a dot gets a second one, and the message ends with a line of one dot.
    static func dotStuffed(_ raw: Data) -> Data {
        var out = Data()
        out.reserveCapacity(raw.count + 64)
        var atLineStart = true
        for byte in raw {
            if atLineStart, byte == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(byte)
            atLineStart = byte == 0x0A
        }
        if !out.isEmpty, !(out.suffix(2) == Data("\r\n".utf8)) { out.append(Data("\r\n".utf8)) }
        out.append(Data(".\r\n".utf8))
        return out
    }
}

extension IMAPConnection {
    /// The folder iCloud keeps sent mail in, by its special-use flag or its usual name.
    func sentMailbox() async throws -> String? {
        let tag = takeTag()
        try await reader.send("\(tag) LIST \"\" \"*\"")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { return nil }
        let listed = untagged.compactMap(Self.listed)
        if let flagged = listed.first(where: { $0.flags.contains("\\sent") }) { return flagged.name }
        return ["Sent Messages", "Sent"].first { name in listed.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    }

    /// Adds a message to a folder as read, the way a mail app keeps what it sent.
    func append(_ raw: Data, to mailbox: String) async throws {
        guard Self.isMailboxName(mailbox) else { throw OutsideMailProblem.unexpected }
        let tag = takeTag()
        try await reader.send("\(tag) APPEND \(Self.quoted(mailbox)) (\\Seen) {\(raw.count)}")
        while true {
            let line = String(decoding: try await reader.line(), as: UTF8.self)
            if line.hasPrefix("+") { break }
            if let answer = Self.answer(line, tag: tag) {
                throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text))
            }
        }
        try await reader.wire.write(raw + Data("\r\n".utf8))
        let (_, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
    }
}

/// Sends from an outside account and says how it went for each recipient.
struct OutsideSender: Sendable {
    let maker: any OutsideWireMaker
    let google: GoogleOAuth?

    struct Result: Sendable {
        var outcomes: [String: MailSendResult.Outcome]
        /// The provider's ID for the sent copy, when it keeps one Totality can name.
        var providerID: String?
    }

    /// `raw` keeps Bcc for Gmail, which takes it out itself; for SMTP the Bcc people only go on the
    /// envelope, and `sentCopy` (with Bcc) is what goes in iCloud's Sent.
    func send(
        _ account: OutsideAccount, credential: OutsideCredential, raw: Data, sentCopy: Data, recipients: [String]
    ) async -> Result {
        func everyone(_ outcome: MailSendResult.Outcome) -> Result {
            Result(outcomes: Dictionary(recipients.map { ($0.lowercased(), outcome) }, uniquingKeysWith: { first, _ in first }))
        }
        switch credential {
        case .google(let grant):
            guard grant.canSend, let google else { return everyone(.failed) }
            do {
                let token = try await google.accessToken(for: grant)
                let id = try await google.send(raw, accessToken: token)
                var result = everyone(.sentOutside)
                result.providerID = id
                return result
            } catch {
                return everyone(Self.outcome(error, maybeSent: false))
            }
        case .appPassword(let password):
            guard let signIn = OutsideSignIn(provider: account.provider, address: account.address, appPassword: password) else {
                return everyone(.failed)
            }
            let connection: SMTPConnection
            do {
                connection = try await SMTPConnection.signIn(signIn, with: maker)
            } catch {
                return everyone(Self.outcome(error, maybeSent: false))
            }
            let sent: SMTPConnection.Sent
            do {
                sent = try await connection.send(sentCopy.removingBcc, from: account.address, to: recipients)
            } catch {
                await connection.signOut()
                return everyone(Self.outcome(error, maybeSent: false))
            }
            await connection.signOut()
            var outcomes: [String: MailSendResult.Outcome] = [:]
            let went: MailSendResult.Outcome = sent.accepted ? .sentOutside : sent.unsure ? .mayHaveSent : .refused
            for recipient in sent.taken { outcomes[recipient.lowercased()] = went }
            for recipient in sent.refused { outcomes[recipient.lowercased()] = .refused }
            // iCloud doesn't keep what's sent by SMTP, so it goes in its Sent folder as a mail app would.
            if sent.accepted || sent.unsure, let imap = try? await IMAPConnection.signIn(signIn, with: maker) {
                if let folder = try? await imap.sentMailbox() { try? await imap.append(sentCopy, to: folder) }
                await imap.signOut()
            }
            return Result(outcomes: outcomes, providerID: nil)
        }
    }

    static func outcome(_ error: any Error, maybeSent: Bool) -> MailSendResult.Outcome {
        switch OutsideMailProblem.from(error) {
        case .offline: .offline
        case .unreachable: maybeSent ? .mayHaveSent : .busy
        case .refused: .refused
        default: .failed
        }
    }
}

extension Data {
    /// The same message without its Bcc header, for SMTP, where Bcc people are only on the envelope.
    var removingBcc: Data {
        guard let end = firstRange(of: Data("\r\n\r\n".utf8)) else { return self }
        let head = String(decoding: self[startIndex..<end.lowerBound], as: UTF8.self)
        var lines: [String] = []
        var skipping = false
        for line in head.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("bcc:") { skipping = true; continue }
            if skipping, line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
            skipping = false
            lines.append(line)
        }
        return Data(lines.joined(separator: "\r\n").utf8) + self[end.lowerBound...]
    }
}

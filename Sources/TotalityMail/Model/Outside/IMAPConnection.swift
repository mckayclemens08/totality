import Foundation

/// The reading side of an iCloud account: IMAP over TLS. Signing in and out is how an account is checked
/// before it's saved; `OutsideReading` adds reading the Inbox.
final class IMAPConnection {
    let reader: WireReader
    private var nextTag = 1

    private init(_ wire: any OutsideWire) { reader = WireReader(wire) }

    /// A tagged answer: OK, NO, or BAD, with any response code and the text after it.
    struct Answer: Equatable {
        enum Status: String { case ok = "OK", no = "NO", bad = "BAD" }
        let status: Status
        let code: String?
        let text: String
    }

    /// Opens the provider's IMAP server and signs in. Throws a problem, never the password.
    static func signIn(_ signIn: OutsideSignIn, with maker: any OutsideWireMaker) async throws -> IMAPConnection {
        guard let endpoint = signIn.provider.reading else { throw OutsideMailProblem.unexpected }
        precondition(endpoint.security == .tls, "IMAP is only ever spoken over TLS from the start")
        let connection = IMAPConnection(maker.open(endpoint))
        do {
            let greeting = String(decoding: try await connection.reader.line(), as: UTF8.self)
            guard greeting.hasPrefix("* OK") else {
                throw greeting.hasPrefix("* BYE") ? OutsideMailProblem.unreachable : OutsideMailProblem.unexpected
            }
            let answer = try await connection.authenticate(signIn)
            guard answer.status == .ok else { throw Self.problem(signingIn: answer) }
            return connection
        } catch {
            connection.reader.wire.close()
            throw OutsideMailProblem.from(error)
        }
    }

    /// SASL PLAIN with the initial response on the same line, which both providers take. A server that
    /// asks for it again is cancelled. Either way it's base64, so nothing in it can end the line.
    private func authenticate(_ signIn: OutsideSignIn) async throws -> Answer {
        let tag = takeTag()
        try await reader.send("\(tag) AUTHENTICATE PLAIN \(signIn.plain)")
        var cancelled = false
        while true {
            let line = String(decoding: try await reader.line(), as: UTF8.self)
            if line.hasPrefix("+") {
                // Asked again after the response was already sent: cancel once, and never loop.
                guard !cancelled else { throw OutsideMailProblem.unexpected }
                cancelled = true
                try await reader.send("*")
                continue
            }
            if let answer = Self.answer(line, tag: tag) { return answer }
        }
    }

    func signOut() async {
        let tag = takeTag()
        try? await reader.send("\(tag) LOGOUT")
        _ = try? await readUntilTagged(tag)
        reader.wire.close()
    }

    /// Reads untagged lines, with any literals they carry, until the command's own answer.
    func readUntilTagged(_ tag: String) async throws -> (untagged: [Data], answer: Answer) {
        var untagged: [Data] = []
        while true {
            var line = try await reader.line()
            while let count = Self.literalLength(ending: line) {
                guard count <= 50 * 1024 * 1024 else { throw OutsideMailProblem.unexpected }
                line.append(Data("\r\n".utf8))
                line.append(try await reader.bytes(count))
                line.append(try await reader.line())
            }
            if let answer = Self.answer(String(decoding: line, as: UTF8.self), tag: tag) { return (untagged, answer) }
            untagged.append(line)
        }
    }

    func takeTag() -> String {
        defer { nextTag += 1 }
        return "t\(nextTag)"
    }

    /// `{12}` or `{12+}` at the end of a line means twelve bytes follow it.
    static func literalLength(ending line: Data) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    static func answer(_ line: String, tag: String) -> Answer? {
        guard line.hasPrefix(tag + " ") else { return nil }
        let rest = line.dropFirst(tag.count + 1)
        let word = rest.prefix { $0 != " " }
        guard let status = Answer.Status(rawValue: word.uppercased()) else { return nil }
        var text = rest.dropFirst(word.count).drop { $0 == " " }
        var code: String?
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            code = String(text[text.index(after: text.startIndex)..<close])
            text = text[text.index(after: close)...].drop { $0 == " " }
        }
        return Answer(status: status, code: code, text: String(text))
    }

    static func problem(signingIn answer: Answer) -> OutsideMailProblem {
        let code = answer.code?.uppercased() ?? ""
        let said = answer.text.lowercased()
        if said.contains("application-specific password") || said.contains("app password") { return .needsAppPassword }
        if code.hasPrefix("AUTHENTICATIONFAILED") || code.hasPrefix("AUTHORIZATIONFAILED") || code.isEmpty && answer.status == .no {
            return .wrongPassword
        }
        if code.hasPrefix("UNAVAILABLE") { return .unreachable }
        return .refused(OutsideMailProblem.providerSaid(answer.text))
    }
}

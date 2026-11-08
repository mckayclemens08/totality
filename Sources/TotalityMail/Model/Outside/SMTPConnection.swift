import Foundation

/// The sending side of an outside account: SMTP submission, switched to TLS before signing in. This first
/// part only signs in and out, to check an account before its Send switch turns on. Sending comes in
/// issue 43, step 4.
final class SMTPConnection {
    private let reader: WireReader

    private init(_ wire: any OutsideWire) { reader = WireReader(wire) }

    struct Reply: Equatable {
        let code: Int
        let lines: [String]
    }

    /// The name this device gives the server. A bare address, so the server learns nothing about the device.
    static let greetingName = "[127.0.0.1]"

    static func signIn(_ signIn: OutsideSignIn, with maker: any OutsideWireMaker) async throws -> SMTPConnection {
        guard let endpoint = signIn.provider.sending else { throw OutsideMailProblem.unexpected }
        precondition(endpoint.security == .startTLS, "submission is only spoken after STARTTLS")
        let connection = SMTPConnection(maker.open(endpoint))
        do {
            guard try await connection.reply().code == 220 else { throw OutsideMailProblem.unreachable }
            let plain = try await connection.command("EHLO \(greetingName)")
            guard plain.code == 250, Self.offers(plain, "STARTTLS") else { throw OutsideMailProblem.insecure }
            guard try await connection.command("STARTTLS").code == 220 else { throw OutsideMailProblem.insecure }
            // Anything already waiting was sent before encryption, so it could be an attacker's. Stop.
            guard !connection.reader.hasUnread else { throw OutsideMailProblem.insecure }
            connection.reader.wire.startTLS()
            let secure = try await connection.command("EHLO \(greetingName)")
            guard secure.code == 250, Self.authMethods(secure).contains("PLAIN") else { throw OutsideMailProblem.unexpected }
            let answer = try await connection.command("AUTH PLAIN \(signIn.plain)")
            guard answer.code == 235 else { throw Self.problem(signingIn: answer) }
            return connection
        } catch {
            connection.reader.wire.close()
            throw OutsideMailProblem.from(error)
        }
    }

    func signOut() async {
        _ = try? await command("QUIT")
        reader.wire.close()
    }

    func command(_ line: String) async throws -> Reply {
        try await reader.send(line)
        return try await reply()
    }

    /// One reply, which may run over several lines: `250-` carries on, `250 ` ends it.
    func reply() async throws -> Reply {
        var lines: [String] = []
        var code: Int?
        while lines.count < 100 {
            let line = String(decoding: try await reader.line(), as: UTF8.self)
            let digits = line.prefix(3)
            guard digits.count == 3, let value = Int(digits), code == nil || code == value else { throw OutsideMailProblem.unexpected }
            code = value
            let rest = line.dropFirst(3)
            lines.append(String(rest.dropFirst()))
            if rest.isEmpty || rest.hasPrefix(" ") { return Reply(code: value, lines: lines) }
            guard rest.hasPrefix("-") else { throw OutsideMailProblem.unexpected }
        }
        throw OutsideMailProblem.unexpected
    }

    static func offers(_ reply: Reply, _ keyword: String) -> Bool {
        reply.lines.contains { $0.uppercased() == keyword || $0.uppercased().hasPrefix(keyword + " ") }
    }

    static func authMethods(_ reply: Reply) -> Set<String> {
        guard let line = reply.lines.first(where: { $0.uppercased().hasPrefix("AUTH ") }) else { return [] }
        return Set(line.uppercased().split(separator: " ").dropFirst().map(String.init))
    }

    static func problem(signingIn reply: Reply) -> OutsideMailProblem {
        let said = reply.lines.joined(separator: " ")
        if said.contains("5.7.9") || said.lowercased().contains("application-specific password") { return .needsAppPassword }
        switch reply.code {
        case 535: return .wrongPassword
        case 454, 421: return .unreachable
        default: return .refused(OutsideMailProblem.providerSaid(said))
        }
    }
}

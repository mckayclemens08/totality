import Foundation
import Testing
@testable import TotalityMail

/// Plays a provider's server: answers each line the client sends with whatever the script says, and
/// remembers everything, including when TLS started.
final class ScriptedWire: OutsideWire, @unchecked Sendable {
    enum Event: Equatable { case sent(String), tls }

    private let lock = NSLock()
    private var pending: Data
    private var partial = Data()
    private var log: [Event] = []
    private(set) var closed = false
    private let answer: @Sendable (String) -> String?

    init(greeting: String, answer: @escaping @Sendable (String) -> String?) {
        pending = Data(greeting.utf8)
        self.answer = answer
    }

    var events: [Event] { lock.withLock { log } }
    var sent: [String] { events.compactMap { if case .sent(let line) = $0 { line } else { nil } } }

    func read() async throws -> Data {
        lock.withLock {
            defer { pending = Data() }
            return pending
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            partial.append(data)
            while let end = partial.firstRange(of: Data("\r\n".utf8)) {
                let line = String(decoding: partial[partial.startIndex..<end.lowerBound], as: UTF8.self)
                partial.removeSubrange(partial.startIndex..<end.upperBound)
                log.append(.sent(line))
                if let reply = answer(line) { pending.append(Data(reply.utf8)) }
            }
        }
    }

    func startTLS() { lock.withLock { log.append(.tls) } }
    func close() { lock.withLock { closed = true } }
}

struct ScriptedMaker: OutsideWireMaker {
    let wire: ScriptedWire
    let expected: OutsideEndpoint
    func open(_ endpoint: OutsideEndpoint) -> any OutsideWire {
        precondition(endpoint == expected)
        return wire
    }
}

private let signIn = OutsideSignIn(provider: .gmail, address: "mckay.clemens@gmail.com", appPassword: "abcd efgh ijkl mnop")!

private func imap(_ answer: @escaping @Sendable (String) -> String?, greeting: String = "* OK Gimap ready\r\n") -> (ScriptedWire, OutsideSignInCheck) {
    let wire = ScriptedWire(greeting: greeting, answer: answer)
    return (wire, OutsideSignInCheck(maker: ScriptedMaker(wire: wire, expected: OutsideProvider.gmail.reading)))
}

private func smtp(_ answer: @escaping @Sendable (String) -> String?, greeting: String = "220 smtp.gmail.com ESMTP ready\r\n") -> (ScriptedWire, OutsideSignInCheck) {
    let wire = ScriptedWire(greeting: greeting, answer: answer)
    return (wire, OutsideSignInCheck(maker: ScriptedMaker(wire: wire, expected: OutsideProvider.gmail.sending)))
}

/// Answers a Gmail-like submission server would give, with the sign-in's answer chosen by the test.
@Sendable private func gmailSubmission(auth: String) -> @Sendable (String) -> String? {
    { line in
        switch line {
        case "EHLO [127.0.0.1]": "250-smtp.gmail.com at your service\r\n250-SIZE 35882577\r\n250-STARTTLS\r\n250-AUTH LOGIN PLAIN XOAUTH2\r\n250 SMTPUTF8\r\n"
        case "STARTTLS": "220 2.0.0 Ready to start TLS\r\n"
        case "QUIT": "221 2.0.0 closing connection\r\n"
        default: line.hasPrefix("AUTH PLAIN ") ? auth : "500 what\r\n"
        }
    }
}

@Suite struct OutsideProviderTests {
    @Test func everyProviderUsesItsPublishedServersWithTLS() {
        #expect(OutsideProvider.icloud.reading == OutsideProvider.icloud.reading)
        #expect(OutsideProvider.icloud.reading.host == "imap.mail.me.com")
        #expect(OutsideProvider.icloud.sending.host == "smtp.mail.me.com")
        #expect(OutsideProvider.gmail.reading.host == "imap.gmail.com")
        #expect(OutsideProvider.gmail.sending.host == "smtp.gmail.com")
        for provider in OutsideProvider.allCases {
            #expect(provider.reading.port == 993 && provider.reading.security == .tls)
            #expect(provider.sending.port == 587 && provider.sending.security == .startTLS)
            #expect(provider.appPasswordHelp.scheme == "https")
        }
    }

    @Test func outlookIsNotOfferedYet() {
        #expect(OutsideProvider.allCases == [.icloud, .gmail])
    }

    @Test func theAppPasswordNeverPrints() {
        let text = [String(describing: signIn), String(reflecting: signIn), "\(signIn)", String(describing: Mirror(reflecting: signIn).children.map(\.value))]
        for shown in text {
            #expect(!shown.contains("abcd"))
            #expect(!shown.contains("efgh"))
        }
        #expect(String(describing: signIn).contains("mckay.clemens@gmail.com"))
    }

    @Test func spacesInTheAppPasswordAreDropped() {
        #expect(signIn.appPassword == "abcdefghijklmnop")
        let decoded = Data(base64Encoded: signIn.plain).map { String(decoding: $0, as: UTF8.self) }
        #expect(decoded == "\0mckay.clemens@gmail.com\0abcdefghijklmnop")
    }

    @Test func anAddressOrPasswordThatCantBeRightIsRefused() {
        #expect(OutsideSignIn(provider: .icloud, address: "mckay", appPassword: "abcd-efgh-ijkl-mnop") == nil)
        #expect(OutsideSignIn(provider: .icloud, address: "mckay@icloud.com\r\nRCPT TO:<x@y.com>", appPassword: "abcd") == nil)
        #expect(OutsideSignIn(provider: .icloud, address: "mc kay@icloud.com", appPassword: "abcd") == nil)
        #expect(OutsideSignIn(provider: .icloud, address: "mckay@icloud.com", appPassword: "   ") == nil)
        #expect(OutsideSignIn(provider: .icloud, address: "mckay@icloud.com", appPassword: "abcd\u{0}efgh") == nil)
        #expect(OutsideSignIn(provider: .icloud, address: " mckay@icloud.com ", appPassword: "abcd-efgh-ijkl-mnop")?.address == "mckay@icloud.com")
    }
}

@Suite struct OutsideIMAPTests {
    @Test func signsInWithPlainAndSignsOut() async {
        let (wire, check) = imap { line in
            if line.hasPrefix("t1 AUTHENTICATE PLAIN ") { return "* CAPABILITY IMAP4rev1 IDLE\r\nt1 OK mckay.clemens@gmail.com authenticated (Success)\r\n" }
            if line == "t2 LOGOUT" { return "* BYE LOGOUT Requested\r\nt2 OK 73 good day (Success)\r\n" }
            return nil
        }
        #expect(await check.checkReading(signIn) == nil)
        #expect(wire.sent == ["t1 AUTHENTICATE PLAIN \(signIn.plain)", "t2 LOGOUT"])
        #expect(wire.closed)
    }

    @Test func aWrongAppPasswordSaysSo() async {
        let (wire, check) = imap { _ in "t1 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n" }
        #expect(await check.checkReading(signIn) == .wrongPassword)
        #expect(wire.closed)
    }

    @Test func theAccountPasswordInsteadOfAnAppPasswordSaysSo() async {
        let (_, check) = imap { _ in "t1 NO [ALERT] Application-specific password required: https://support.google.com/accounts/answer/185833 (Failure)\r\n" }
        #expect(await check.checkReading(signIn) == .needsAppPassword)
    }

    @Test func anotherRefusalKeepsOnlyTheProvidersSafeWords() async {
        let (_, check) = imap { _ in "t1 NO [ALERT] Please log in via your web\u{07} browser\r\n" }
        #expect(await check.checkReading(signIn) == .refused("Please log in via your web browser"))
    }

    @Test func aServerThatSaysGoodbyeFirstIsUnreachable() async {
        let (wire, check) = imap({ _ in nil }, greeting: "* BYE too many connections\r\n")
        #expect(await check.checkReading(signIn) == .unreachable)
        #expect(wire.sent.isEmpty)
    }

    @Test func aServerThatStopsTalkingIsUnexpected() async {
        let (_, check) = imap { _ in nil }
        #expect(await check.checkReading(signIn) == .unexpected)
    }

    @Test func aServerThatAsksAgainIsCancelledNotLooped() async {
        let (wire, check) = imap { line in
            if line.hasPrefix("t1 AUTHENTICATE") { return "+ \r\n" }
            if line == "*" { return "t1 BAD Authentication cancelled\r\n" }
            return nil
        }
        #expect(await check.checkReading(signIn) == .refused("Authentication cancelled"))
        #expect(wire.sent.count == 2)
    }

    @Test func taggedAnswersAndLiteralsParse() {
        #expect(IMAPConnection.answer("t3 OK [READ-WRITE] SELECT completed", tag: "t3") == .init(status: .ok, code: "READ-WRITE", text: "SELECT completed"))
        #expect(IMAPConnection.answer("t3 no nope", tag: "t3") == .init(status: .no, code: nil, text: "nope"))
        #expect(IMAPConnection.answer("t30 OK done", tag: "t3") == nil)
        #expect(IMAPConnection.answer("* OK still going", tag: "t3") == nil)
        #expect(IMAPConnection.literalLength(ending: Data("* 1 FETCH (BODY[] {342}".utf8)) == 342)
        #expect(IMAPConnection.literalLength(ending: Data("a {12+}".utf8)) == 12)
        #expect(IMAPConnection.literalLength(ending: Data("a {}".utf8)) == nil)
        #expect(IMAPConnection.literalLength(ending: Data("a {1x}".utf8)) == nil)
        #expect(IMAPConnection.literalLength(ending: Data("a {9999999999}".utf8)) == nil)
    }
}

@Suite struct OutsideSMTPTests {
    @Test func switchesToTLSBeforeSigningIn() async {
        let (wire, check) = smtp(gmailSubmission(auth: "235 2.7.0 Accepted\r\n"))
        #expect(await check.checkSending(signIn) == nil)
        #expect(wire.events == [
            .sent("EHLO [127.0.0.1]"), .sent("STARTTLS"), .tls,
            .sent("EHLO [127.0.0.1]"), .sent("AUTH PLAIN \(signIn.plain)"), .sent("QUIT"),
        ])
        #expect(wire.closed)
    }

    @Test func aServerWithoutSTARTTLSNeverGetsThePassword() async {
        let (wire, check) = smtp { line in line.hasPrefix("EHLO") ? "250-smtp.example\r\n250 AUTH PLAIN LOGIN\r\n" : "235 ok\r\n" }
        #expect(await check.checkSending(signIn) == .insecure)
        #expect(!wire.sent.contains { $0.hasPrefix("AUTH") })
    }

    @Test func linesSlippedInBeforeTLSStopEverything() async {
        let (wire, check) = smtp { line in
            switch line {
            case "EHLO [127.0.0.1]": "250-smtp.gmail.com\r\n250 STARTTLS\r\n"
            case "STARTTLS": "220 Ready to start TLS\r\n250-injected\r\n250 AUTH PLAIN\r\n"
            default: "235 ok\r\n"
            }
        }
        #expect(await check.checkSending(signIn) == .insecure)
        #expect(!wire.events.contains(.tls))
        #expect(!wire.sent.contains { $0.hasPrefix("AUTH") })
    }

    @Test func aWrongAppPasswordSaysSo() async {
        let (_, check) = smtp(gmailSubmission(auth: "535-5.7.8 Username and Password not accepted.\r\n535 5.7.8 https://support.google.com/mail/?p=BadCredentials\r\n"))
        #expect(await check.checkSending(signIn) == .wrongPassword)
    }

    @Test func theAccountPasswordInsteadOfAnAppPasswordSaysSo() async {
        let (_, check) = smtp(gmailSubmission(auth: "534-5.7.9 Application-specific password required.\r\n534 5.7.9 https://support.google.com/mail/?p=InvalidSecondFactor\r\n"))
        #expect(await check.checkSending(signIn) == .needsAppPassword)
    }

    @Test func aBusyServerIsUnreachable() async {
        let (wire, check) = smtp({ _ in nil }, greeting: "421 4.7.0 Try again later\r\n")
        #expect(await check.checkSending(signIn) == .unreachable)
        #expect(wire.sent.isEmpty)
    }

    @Test func multiLineRepliesHaveToAgree() async {
        let (_, check) = smtp { line in line.hasPrefix("EHLO") ? "250-smtp.gmail.com\r\n251 STARTTLS\r\n" : nil }
        #expect(await check.checkSending(signIn) == .unexpected)
    }
}

@Suite struct OutsideProblemTests {
    @Test func networkErrorsMapToWhatAPersonCanDo() {
        #expect(OutsideMailProblem.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(OutsideMailProblem.from(URLError(.serverCertificateUntrusted)) == .insecure)
        #expect(OutsideMailProblem.from(URLError(.secureConnectionFailed)) == .insecure)
        #expect(OutsideMailProblem.from(URLError(.timedOut)) == .unreachable)
        #expect(OutsideMailProblem.from(URLError(.cannotFindHost)) == .unreachable)
    }

    @Test func providerWordsAreShortAndOneLine() {
        #expect(OutsideMailProblem.providerSaid("a\r\nb\tc") == "abc")
        #expect(OutsideMailProblem.providerSaid(String(repeating: "x", count: 500)).count == 200)
    }
}

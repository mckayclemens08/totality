import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A message read out of its seal. The attachment bytes stand apart, keyed by attachment, because the
/// store keeps them separately from the message.
public struct ParsedMail: Sendable {
    public let message: MailMessage
    public let attachments: [UUID: Data]
}

/// Reads what a sealed file holds: one line of JSON with what the server knew, then the message exactly
/// as it arrived. Mail is written by strangers, so nothing here throws, crashes, or trusts what a header
/// says about itself. Whatever can't be read becomes the unreadable message, and nothing is ever logged.
public enum MailParser {
    /// How deep parts may nest and how many there may be. Real mail is far below both, and a message
    /// built to go deeper is still shown up to here.
    static let maxDepth = 24
    static let maxParts = 1_000
    /// Inline images go into the page as `data:` URLs up to here. Past it they stay attachments.
    static let maxInlineBytes = 8 * 1_024 * 1_024

    /// `id` is the server's name for the message, which is also what the seal authenticated. `now` is
    /// the date only when the server's own line can't be read.
    public static func parse(_ opened: Data, id: UUID, now: Date = Date()) -> ParsedMail {
        let bytes = [UInt8](opened)
        guard let newline = bytes.firstIndex(of: 0x0A),
              let facts = try? JSONDecoder().decode(Facts.self, from: Data(bytes[..<newline])),
              facts.version == 1
        else {
            return ParsedMail(message: .unreadable(id: id, date: now, marks: MailMarks(isUnread: true)), attachments: [:])
        }
        let received = isoDate(facts.received) ?? now
        // A flagged verdict goes to Spam the way Report Spam would leave it.
        let marks = MailMarks(folder: facts.spam?.flagged == true ? .spam : .inbox, isUnread: true)
        let raw = withoutCarriageReturns(bytes[(newline + 1)...])
        guard let top = Part(raw[...], requireHeaders: true) else {
            return ParsedMail(message: .unreadable(id: id, date: received, marks: marks), attachments: [:])
        }
        return read(top, id: id, received: received, marks: marks)
    }

    private struct Facts: Decodable {
        struct Verdict: Decodable {
            let flagged: Bool
        }

        let version: Int
        let received: String
        let spam: Verdict?
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func read(_ top: Part, id: UUID, received: Date, marks: MailMarks) -> ParsedMail {
        let headers = top.headers
        let fromFields = headers.all("from")
        let from = fromFields.flatMap(addresses)
        let to = headers.all("to").flatMap(addresses)
        let cc = headers.all("cc").flatMap(addresses)
        let subject = oneLine(words(headers.first("subject") ?? ""))
        let date = headers.first("date").flatMap(date) ?? received

        var budget = maxParts
        let tree = Node(top, depth: 0, budget: &budget)
        var found = Found()
        found.collect(tree)
        let (body, kept) = found.body()

        var attachments: [MailAttachment] = []
        var data: [UUID: Data] = [:]
        for (index, leaf) in kept.enumerated() {
            let attachmentID = uuid("totality/mail/attachment", "\(id.uuidString)/\(index)")
            let name = attachmentName(leaf, number: index + 1)
            attachments.append(MailAttachment(id: attachmentID, name: name, mimeType: mimeType(leaf, name: name), size: Int64(leaf.data.count)))
            data[attachmentID] = Data(leaf.data)
        }

        let message = MailMessage(
            id: id, conversationID: conversation(headers, id: id, subject: subject, people: from + to + cc),
            from: from.first ?? MailAddress(address: ""), to: to, cc: cc, subject: subject, date: date, body: body,
            attachments: attachments,
            // Everything in a sealed file came in from outside through Cloudflare. Mail between accounts
            // will travel another way, and the path it took is what decides this, never an address.
            route: .outside,
            proof: proof(headers, from: from, fromFields: fromFields.count), marks: marks
        )
        return ParsedMail(message: message, attachments: data)
    }

    // MARK: - Bytes

    /// Lines end in a bare LF from here on. Base64 and quoted-printable don't mind, and SMTP can't carry
    /// raw binary without encoding it, so no part's bytes are changed by this.
    static func withoutCarriageReturns(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == 0x0D, index + 1 < bytes.endIndex, bytes[index + 1] == 0x0A {
                index += 1
                continue
            }
            out.append(byte)
            index += 1
        }
        return out
    }

    /// Skips anything outside the alphabet, so line breaks and stray characters can't stop it. Padding
    /// starts afresh, because some senders join separately encoded pieces.
    static func base64(_ input: some Sequence<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.underestimatedCount * 3 / 4)
        var held: UInt32 = 0
        var bits = 0
        for byte in input {
            let value: UInt32
            switch byte {
            case 65...90: value = UInt32(byte - 65)
            case 97...122: value = UInt32(byte - 71)
            case 48...57: value = UInt32(byte + 4)
            case 43, 45: value = 62
            case 47, 95: value = 63
            case 61:
                held = 0
                bits = 0
                continue
            default: continue
            }
            held = ((held << 6) | value) & 0xFFFF
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((held >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    /// In a header, an underscore is a space. An `=` that starts nothing stays as it is.
    static func quotedPrintable(_ input: ArraySlice<UInt8>, header: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var index = input.startIndex
        let end = input.endIndex
        while index < end {
            let byte = input[index]
            if byte == 0x3D {
                if index + 2 < end, let high = hex(input[index + 1]), let low = hex(input[index + 2]) {
                    out.append(high << 4 | low)
                    index += 3
                    continue
                }
                // A soft line break, which may have spaces before its newline.
                var next = index + 1
                while next < end, input[next] == 0x20 || input[next] == 0x09 { next += 1 }
                if next == end || input[next] == 0x0A {
                    index = min(next + 1, end)
                    continue
                }
                out.append(byte)
            } else if header, byte == 0x5F {
                out.append(0x20)
            } else {
                out.append(byte)
            }
            index += 1
        }
        return out
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    // MARK: - Text

    /// Never fails. The label is tried first, then UTF-8, then Windows-1252, then Latin-1, which takes
    /// any bytes at all. Latin-1 labels read as Windows-1252, as browsers do, because senders mix them up.
    static func text(_ bytes: some Collection<UInt8>, charset: String?) -> String {
        let data = Data(bytes)
        let label = (charset ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        var tries: [String.Encoding] = []
        switch label {
        case "", "us-ascii", "ascii", "us", "ansi_x3.4-1968":
            tries = [.utf8]
        case "utf-8", "utf8":
            tries = [.utf8]
        case "iso-8859-1", "iso8859-1", "latin1", "iso_8859-1", "l1", "windows-1252", "cp1252":
            tries = [.windowsCP1252]
        default:
            let named = CFStringConvertIANACharSetNameToEncoding(label as CFString)
            if named != kCFStringEncodingInvalidId {
                tries = [String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(named))]
            }
        }
        for encoding in tries + [.utf8, .windowsCP1252] {
            if let decoded = String(data: data, encoding: encoding) { return decoded }
        }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047 encoded words. Words next to each other join with the space between them dropped, and
    /// their bytes join before decoding, because senders split a character across two words.
    static func words(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var out = ""
        var pending: (charset: String, bytes: [UInt8])?
        var rest = value[...]
        func flush() {
            if let held = pending { out += text(held.bytes, charset: held.charset) }
            pending = nil
        }
        while let match = rest.firstMatch(of: /=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/) {
            let before = rest[rest.startIndex..<match.range.lowerBound]
            if pending == nil || !before.allSatisfy(\.isWhitespace) {
                flush()
                out += before
            }
            let charset = String(match.1.split(separator: "*").first ?? "").lowercased()
            let encoded = Array(match.3.utf8)
            let bytes = match.2.lowercased() == "b" ? base64(encoded) : quotedPrintable(encoded[...], header: true)
            if pending?.charset == charset {
                pending?.bytes += bytes
            } else {
                flush()
                pending = (charset, bytes)
            }
            rest = rest[match.range.upperBound...]
        }
        flush()
        return out + rest
    }

    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Headers

    struct Headers {
        /// Names are lowercased. Values are unfolded and still encoded.
        var fields: [(name: String, value: String)] = []

        func first(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        func all(_ name: String) -> [String] { fields.filter { $0.name == name }.map(\.value) }

        init(_ bytes: ArraySlice<UInt8>) {
            for line in MailParser.text(bytes, charset: "utf-8").split(separator: "\n", omittingEmptySubsequences: false) {
                if let first = line.first, first == " " || first == "\t" {
                    if !fields.isEmpty { fields[fields.count - 1].value += line }
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { continue }
                fields.append((name, String(line[line.index(after: colon)...])))
            }
            for index in fields.indices {
                fields[index].value = fields[index].value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// A part split into its headers and its still-encoded body.
    struct Part {
        let headers: Headers
        let body: ArraySlice<UInt8>

        /// Only the whole message has to start with a header. A part that doesn't is all body.
        init?(_ bytes: ArraySlice<UInt8>, requireHeaders: Bool = false) {
            var bytes = bytes
            // An mbox separator line isn't a header.
            if bytes.starts(with: Array("From ".utf8)), let newline = bytes.firstIndex(of: 0x0A) {
                bytes = bytes[(newline + 1)...]
            }
            guard Self.startsWithHeader(bytes) else {
                if requireHeaders { return nil }
                headers = Headers(ArraySlice())
                body = bytes.first == 0x0A ? bytes.dropFirst() : bytes
                return
            }
            var index = bytes.startIndex
            var split: Int?
            while index + 1 < bytes.endIndex {
                if bytes[index] == 0x0A, bytes[index + 1] == 0x0A {
                    split = index
                    break
                }
                index += 1
            }
            if let split {
                headers = Headers(bytes[..<split])
                body = bytes[(split + 2)...]
            } else {
                headers = Headers(bytes)
                body = ArraySlice()
            }
            if requireHeaders, headers.fields.isEmpty { return nil }
        }

        private static func startsWithHeader(_ bytes: ArraySlice<UInt8>) -> Bool {
            var sawName = false
            for byte in bytes.prefix(1_000) {
                switch byte {
                case 0x3A: return sawName
                case 33...126: sawName = true
                default: return false
                }
            }
            return false
        }
    }

    /// `type/subtype` lowercased, and its parameters with RFC 2231 and RFC 2047 undone.
    static func field(_ value: String?) -> (value: String, parameters: [String: String]) {
        guard let value else { return ("", [:]) }
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var depth = 0
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where quoted:
                current.append(character)
                escaped = true
            case "\"" where depth == 0:
                quoted.toggle()
                current.append(character)
            case "(" where !quoted:
                depth += 1
            case ")" where !quoted && depth > 0:
                depth -= 1
            case ";" where !quoted && depth == 0:
                pieces.append(current)
                current = ""
            default:
                if depth == 0 { current.append(character) }
            }
        }
        pieces.append(current)
        let head = pieces.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()

        var plain: [String: String] = [:]
        var sections: [String: [(number: Int, encoded: Bool, value: String)]] = [:]
        for piece in pieces {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.count >= 2 {
                raw = unquoted(raw)
            }
            guard !name.isEmpty else { continue }
            if let star = name.firstIndex(of: "*") {
                let base = String(name[..<star])
                let marks = name[name.index(after: star)...]
                let encoded = name.hasSuffix("*")
                let number = Int(marks.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
                sections[base, default: []].append((number, encoded, raw))
            } else if plain[name] == nil {
                plain[name] = words(raw)
            }
        }
        for (base, parts) in sections {
            var bytes: [UInt8] = []
            var charset = "utf-8"
            for (index, part) in parts.sorted(by: { $0.number < $1.number }).enumerated() {
                var piece = Substring(part.value)
                if part.encoded, index == 0 {
                    let quote = piece.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if quote.count == 3 {
                        if !quote[0].isEmpty { charset = String(quote[0]) }
                        piece = quote[2]
                    }
                }
                bytes += part.encoded ? percentDecoded(piece) : Array(piece.utf8)
            }
            plain[base] = text(bytes, charset: charset)
        }
        return (head, plain)
    }

    private static func unquoted(_ value: String) -> String {
        var out = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped || character != "\\" {
                out.append(character)
                escaped = false
            } else {
                escaped = true
            }
        }
        return out
    }

    private static func percentDecoded(_ value: Substring) -> [UInt8] {
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    // MARK: - Addresses

    /// Display names, quoted names, comments, groups, and bare addresses. A group's name is dropped and
    /// its members kept. Names are decoded after splitting, so an encoded comma can't split a list.
    static func addresses(_ value: String) -> [MailAddress] {
        var found: [MailAddress] = []
        var phrase = ""
        var angle: String?
        var comment = ""
        let characters = Array(value)
        var index = 0

        func finish() {
            if let angle {
                var address = angle
                if let colon = address.lastIndex(of: ":") { address = String(address[address.index(after: colon)...]) }
                address = address.filter { !$0.isWhitespace }
                let name = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !address.isEmpty { found.append(MailAddress(name: displayName(name.isEmpty ? comment : name, address), address: address)) }
            } else {
                let bare = phrase.filter { !$0.isWhitespace }
                if bare.contains("@") { found.append(MailAddress(name: displayName(comment, bare), address: bare)) }
            }
            phrase = ""
            angle = nil
            comment = ""
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\"":
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count { index += 1 }
                    phrase.append(characters[index])
                    index += 1
                }
            case "(":
                var depth = 1
                var text = ""
                index += 1
                while index < characters.count, depth > 0 {
                    let inner = characters[index]
                    if inner == "\\", index + 1 < characters.count {
                        index += 1
                        text.append(characters[index])
                    } else if inner == "(" {
                        depth += 1
                        text.append(inner)
                    } else if inner == ")" {
                        depth -= 1
                        if depth > 0 { text.append(inner) }
                    } else {
                        text.append(inner)
                    }
                    index += 1
                }
                if comment.isEmpty { comment = text }
                continue
            case "<":
                var inner = ""
                index += 1
                while index < characters.count, characters[index] != ">" {
                    inner.append(characters[index])
                    index += 1
                }
                angle = inner
            case ":" where angle == nil:
                phrase = ""
                comment = ""
            case ",", ";":
                finish()
            default:
                if angle == nil { phrase.append(character) }
            }
            index += 1
        }
        finish()
        return found
    }

    private static func displayName(_ raw: String, _ address: String) -> String {
        var name = oneLine(words(raw))
        if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") { name = String(name.dropFirst().dropLast()) }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.lowercased() == address.lowercased() ? "" : name
    }

    // MARK: - Dates

    /// RFC 5322 dates, with the obsolete forms: two-digit years, named zones, and comments.
    static func date(_ value: String) -> Date? {
        var cleaned = ""
        var depth = 0
        for character in value {
            if character == "(" { depth += 1; continue }
            if character == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { cleaned.append(character == "," ? " " : character) }
        }
        cleaned = cleaned.replacing(/\s*:\s*/, with: ":")
        var tokens = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = tokens.first, first.first?.isLetter == true, month(first) == nil { tokens.removeFirst() }
        guard tokens.count >= 4, let day = Int(tokens[0]), let month = month(tokens[1]), var year = Int(tokens[2]) else { return nil }
        if tokens[2].count <= 2 { year += year < 50 ? 2000 : 1900 } else if tokens[2].count == 3 { year += 1900 }
        let time = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(time.count), (1...31).contains(day), (1900...9999).contains(year),
              (0...23).contains(time[0]), (0...59).contains(time[1]), time.count == 2 || (0...60).contains(time[2])
        else { return nil }
        let offset = tokens.count > 4 ? zone(tokens[4]) : 0
        guard let offset else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day, hour: time[0], minute: time[1], second: min(59, time.count == 3 ? time[2] : 0))
        guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == day else { return nil }
        return date.addingTimeInterval(-TimeInterval(offset))
    }

    private static func month(_ token: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: String(token.lowercased().prefix(3))).map { $0 + 1 }
    }

    /// Seconds east of UTC. Military letters were defined backwards in RFC 822, so RFC 5322 reads them
    /// as UTC, and so does this.
    private static func zone(_ token: String) -> Int? {
        if let sign = token.first, sign == "+" || sign == "-" {
            let digits = token.dropFirst()
            guard digits.count == 4, let value = Int(digits) else { return nil }
            let seconds = (value / 100) * 3_600 + (value % 100) * 60
            return sign == "-" ? -seconds : seconds
        }
        let named = ["ut": 0, "utc": 0, "gmt": 0, "z": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5, "mst": -7, "mdt": -6, "pst": -8, "pdt": -7]
        return (named[token.lowercased()] ?? 0) * 3_600
    }

    // MARK: - Threads

    /// The first message of a thread names it. Every reply carries that name first in References, or
    /// failing that the message it answers. Mail without either is grouped by subject and people.
    static func conversation(_ headers: Headers, id: UUID, subject: String, people: [MailAddress]) -> UUID {
        for name in ["references", "in-reply-to", "message-id"] {
            if let root = headers.first(name).flatMap({ messageIDs($0).first }) {
                return uuid("totality/mail/thread", root)
            }
        }
        let topic = normalisedSubject(subject)
        guard !topic.isEmpty else { return id }
        let everyone = Set(people.map(\.key)).sorted().joined(separator: ",")
        return uuid("totality/mail/subject", topic + "\n" + everyone)
    }

    static func messageIDs(_ value: String) -> [String] {
        let bracketed = value.matches(of: /<([^<>\s]+)>/).map { String($0.1) }
        if !bracketed.isEmpty { return bracketed }
        return value.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.contains("@") }
    }

    static func normalisedSubject(_ subject: String) -> String {
        var topic = subject.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let prefix = topic.prefixMatch(of: /^\s*(re|fwd?|aw|wg|sv|vs|antw)(\[\d+\])?\s*:\s*/) {
            topic = String(topic[prefix.range.upperBound...])
        }
        return topic.trimmingCharacters(in: .whitespaces)
    }

    /// The same text always gives the same ID, on every device.
    static func uuid(_ purpose: String, _ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((purpose + "\u{0}" + value).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Proof

    static let cloudflare = "mx.cloudflare.net"

    /// Cloudflare writes its results above everything the sender wrote, so only the topmost results header
    /// counts, and only if it names Cloudflare. A sender can write any `Authentication-Results` they like,
    /// Cloudflare's name included, but never above Cloudflare's own. A From with more than one address
    /// or more than one From line is never proved, because the checks only looked at one of them.
    static func proof(_ headers: Headers, from: [MailAddress], fromFields: Int) -> MailProof {
        guard fromFields == 1, from.count == 1, let sender = from.first?.domain, !sender.isEmpty,
              let top = headers.fields.first(where: { $0.name == "authentication-results" || $0.name == "arc-authentication-results" }),
              let results = results(top.value), results.server == cloudflare
        else { return .unproved }

        func aligned(_ domain: String?) -> Bool {
            guard var domain = domain?.lowercased(), !domain.isEmpty else { return false }
            if let at = domain.lastIndex(of: "@") { domain = String(domain[domain.index(after: at)...]) }
            return domain == sender || sender.hasSuffix("." + domain) || domain.hasSuffix("." + sender)
        }

        if let dmarc = results.methods.first(where: { $0.method == "dmarc" }), dmarc.result != "none" {
            let named = dmarc.properties["header.from"]
            return dmarc.result == "pass" && (named == nil || aligned(named)) ? .proved : .unproved
        }
        // No DMARC policy, so a check that passed for the sender's own domain is what vouches for it.
        let dkim = results.methods.contains { $0.method == "dkim" && $0.result == "pass" && aligned($0.properties["header.d"] ?? $0.properties["header.i"]) }
        let spf = results.methods.contains { $0.method == "spf" && $0.result == "pass" && aligned($0.properties["smtp.mailfrom"]) }
        return dkim || spf ? .proved : .unproved
    }

    struct Results {
        var server: String
        var methods: [(method: String, result: String, properties: [String: String])]
    }

    static func results(_ value: String) -> Results? {
        var cleaned = ""
        var depth = 0
        for character in value {
            if character == "(" { depth += 1; continue }
            if character == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { cleaned.append(character) }
        }
        var pieces = cleaned.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let first = pieces.first, first.lowercased().hasPrefix("i=") { pieces.removeFirst() }
        guard let server = pieces.first?.split(whereSeparator: \.isWhitespace).first else { return nil }
        var found = Results(server: server.lowercased(), methods: [])
        for piece in pieces.dropFirst() {
            let tokens = piece.split(whereSeparator: \.isWhitespace)
            guard let head = tokens.first, let equals = head.firstIndex(of: "=") else { continue }
            let method = head[..<equals].split(separator: "/").first.map { $0.lowercased() } ?? ""
            let result = head[head.index(after: equals)...].lowercased()
            var properties: [String: String] = [:]
            for token in tokens.dropFirst() {
                guard let mark = token.firstIndex(of: "=") else { continue }
                properties[token[..<mark].lowercased()] = String(token[token.index(after: mark)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            found.methods.append((method, result, properties))
        }
        return found
    }

    // MARK: - Parts

    struct Leaf {
        let headers: Headers
        let type: String
        let parameters: [String: String]
        let disposition: String
        let dispositionParameters: [String: String]
        let data: [UInt8]

        var contentID: String? {
            headers.first("content-id").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")) }.flatMap { $0.isEmpty ? nil : $0 }
        }

        var filename: String? { dispositionParameters["filename"] ?? parameters["name"] }

        var isText: Bool { type == "text/plain" || type == "text/html" }
        var isBody: Bool { isText && disposition != "attachment" && filename == nil }
        var string: String { MailParser.text(data, charset: parameters["charset"]) }
    }

    indirect enum Node {
        case leaf(Leaf)
        case multipart(String, [Node], start: String?)

        init(_ part: Part, depth: Int, budget: inout Int, assumed: String = "text/plain") {
            let (named, parameters) = MailParser.field(part.headers.first("content-type"))
            // A type that isn't type/subtype counts as plain text, as RFC 2045 says.
            let type = named.contains("/") ? named : assumed
            if type.hasPrefix("multipart/"), depth < MailParser.maxDepth, let boundary = parameters["boundary"], !boundary.isEmpty,
               let pieces = MailParser.pieces(part.body, boundary: boundary) {
                var children: [Node] = []
                for piece in pieces where budget > 0 {
                    budget -= 1
                    guard let child = Part(piece) else { continue }
                    children.append(Node(child, depth: depth + 1, budget: &budget, assumed: type == "multipart/digest" ? "message/rfc822" : "text/plain"))
                }
                self = .multipart(type, children, start: parameters["start"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
                return
            }
            let encoding = MailParser.field(part.headers.first("content-transfer-encoding")).value
            let data: [UInt8] = switch encoding {
            case "base64": MailParser.base64(part.body)
            case "quoted-printable": MailParser.quotedPrintable(part.body)
            default: Array(part.body)
            }
            let (disposition, dispositionParameters) = MailParser.field(part.headers.first("content-disposition"))
            self = .leaf(Leaf(
                headers: part.headers, type: type.hasPrefix("multipart/") ? "text/plain" : type, parameters: parameters,
                disposition: disposition, dispositionParameters: dispositionParameters, data: data
            ))
        }
    }

    /// The parts between boundary lines. The newline before a boundary belongs to the boundary. A
    /// missing closing boundary ends the last part at the end of the message, not in an error.
    static func pieces(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>]? {
        let marker = Array(("--" + boundary).utf8)
        var pieces: [ArraySlice<UInt8>] = []
        var start: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(of: 0x0A) ?? body.endIndex
            if body[lineStart] == 0x2D, body[lineStart..<lineEnd].starts(with: marker) {
                let tail = body[(lineStart + marker.count)..<lineEnd]
                let closing = tail.starts(with: [0x2D, 0x2D])
                let rest = closing ? tail.dropFirst(2) : tail
                if rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if let start { pieces.append(body[start..<max(start, lineStart - 1)]) }
                    if closing { return pieces }
                    start = min(lineEnd + 1, body.endIndex)
                }
            }
            lineStart = lineEnd + 1
        }
        guard let start else { return nil }
        pieces.append(body[start..<body.endIndex])
        return pieces
    }

    /// Walks the tree for what to show and what to keep apart.
    struct Found {
        enum Segment {
            case plain(String)
            case html(String, text: String)
        }

        var segments: [Segment] = []
        var attachments: [Leaf] = []
        var inline: [Leaf] = []

        var hasHTML: Bool { segments.contains { if case .html = $0 { true } else { false } } }

        mutating func collect(_ node: Node) {
            switch node {
            case .leaf(let leaf):
                if leaf.isBody {
                    let string = leaf.string
                    segments.append(leaf.type == "text/html" ? .html(string, text: MailParser.plainText(fromHTML: string)) : .plain(string))
                } else {
                    attachments.append(leaf)
                }
            case .multipart("multipart/alternative", let children, _):
                // The last part is the sender's best. HTML wins, and the plain version is kept as its text.
                var html: Found?
                var plain: Found?
                for child in children {
                    var found = Found()
                    found.collect(child)
                    if found.hasHTML { html = found } else if !found.segments.isEmpty { plain = found } else { attachments += found.attachments }
                }
                guard var chosen = html ?? plain else { return }
                if html != nil, let plain {
                    let text = plain.segments.map(\.text).joined(separator: "\n\n")
                    chosen.segments = [.html(chosen.html, text: text)]
                }
                segments += chosen.segments
                attachments += chosen.attachments
                inline += chosen.inline
            case .multipart("multipart/related", let children, let start):
                let root = children.firstIndex { child in
                    if case .leaf(let leaf) = child { leaf.contentID == start } else { false }
                } ?? 0
                for (index, child) in children.enumerated() {
                    if index != root, case .leaf(let leaf) = child, leaf.contentID != nil {
                        inline.append(leaf)
                    } else {
                        collect(child)
                    }
                }
            case .multipart(_, let children, _):
                for child in children { collect(child) }
            }
        }

        var html: String {
            segments.map { segment in
                switch segment {
                case .html(let html, _): html
                case .plain(let text): #"<div style="white-space:pre-wrap">"# + MailParser.escaped(text) + "</div>"
                }
            }.joined(separator: "\n")
        }

        /// The body, and every part that stays an attachment. Inline images the page names go into it as
        /// `data:` URLs, which its policy allows. The rest stay attachments.
        func body() -> (MailBody, [Leaf]) {
            let text = segments.map(\.text).joined(separator: "\n\n")
            guard hasHTML else { return (.plain(text), attachments + inline) }
            var page = html
            var kept = attachments
            var room = MailParser.maxInlineBytes
            for leaf in inline {
                let kinds = ["image/png", "image/jpeg", "image/gif", "image/webp"]
                guard let id = leaf.contentID, kinds.contains(leaf.type), leaf.data.count <= room, page.contains("cid:" + id) else {
                    kept.append(leaf)
                    continue
                }
                room -= leaf.data.count
                page = page.replacingOccurrences(of: "cid:" + id, with: "data:\(leaf.type);base64," + Data(leaf.data).base64EncodedString())
            }
            return (.html(page, text: text), kept)
        }
    }

    // MARK: - Attachments

    /// Only the last part of a name counts, so a name can't point anywhere on the device.
    static func attachmentName(_ leaf: Leaf, number: Int) -> String {
        let given = leaf.filename.map { name in
            String(name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
                .filter { !($0.unicodeScalars.first.map(CharacterSet.controlCharacters.contains) ?? false) }
                .trimmingCharacters(in: .whitespaces)
        } ?? ""
        if !given.isEmpty, given != ".", given != ".." { return given }
        if leaf.type == "message/rfc822" {
            let inner = Part(leaf.data[...]).flatMap { $0.headers.first("subject") }.map { oneLine(words($0)) } ?? ""
            return (inner.isEmpty ? "Forwarded message" : inner.replacingOccurrences(of: "/", with: "-")) + ".eml"
        }
        let suffix = UTType(mimeType: leaf.type)?.preferredFilenameExtension.map { "." + $0 } ?? ""
        return "Attachment \(number)\(suffix)"
    }

    /// Senders label plenty of files as raw bytes, so the name's extension is asked then.
    static func mimeType(_ leaf: Leaf, name: String) -> String {
        guard leaf.type == "application/octet-stream" || !leaf.type.contains("/") else { return leaf.type }
        let suffix = (name as NSString).pathExtension
        return UTType(filenameExtension: suffix)?.preferredMIMEType ?? leaf.type
    }

    // MARK: - HTML

    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    /// What an HTML message says, for search, previews, and when the page can't be shown. Styles, scripts,
    /// and the head say nothing, and blocks become lines.
    static func plainText(fromHTML html: String) -> String {
        let scalars = Array(html.unicodeScalars)
        let count = scalars.count
        let blocks: Set<String> = [
            "p", "div", "br", "tr", "li", "ul", "ol", "table", "blockquote", "hr", "section", "article", "header", "footer",
            "h1", "h2", "h3", "h4", "h5", "h6", "pre",
        ]
        var out = String.UnicodeScalarView()

        func starts(_ word: String, at index: Int) -> Bool {
            let wanted = Array(word.unicodeScalars)
            guard index + wanted.count <= count else { return false }
            for offset in wanted.indices where scalars[index + offset].properties.lowercaseMapping != String(wanted[offset]) {
                return false
            }
            return true
        }

        func find(_ word: String, from index: Int) -> Int? {
            var index = index
            while index < count {
                if scalars[index] == "<", starts(word, at: index) { return index }
                index += 1
            }
            return nil
        }

        var index = 0
        while index < count {
            let scalar = scalars[index]
            if scalar == "<" {
                if starts("<!--", at: index) {
                    var end = index + 4
                    while end < count, !starts("-->", at: end) { end += 1 }
                    index = min(end + 3, count)
                    continue
                }
                var cursor = index + 1
                let closing = cursor < count && scalars[cursor] == "/"
                if closing { cursor += 1 }
                var name = ""
                while cursor < count, scalars[cursor].properties.isAlphabetic || ("0"..."9").contains(scalars[cursor]) {
                    name += scalars[cursor].properties.lowercaseMapping
                    cursor += 1
                }
                if name.isEmpty, !closing, cursor < count, scalars[cursor] != "!", scalars[cursor] != "?" {
                    out.append(scalar)
                    index += 1
                    continue
                }
                while cursor < count, scalars[cursor] != ">" { cursor += 1 }
                index = min(cursor + 1, count)
                if !closing, ["style", "script", "head", "title"].contains(name) {
                    if let end = find("</" + name, from: index) {
                        var close = end
                        while close < count, scalars[close] != ">" { close += 1 }
                        index = min(close + 1, count)
                    } else {
                        index = count
                    }
                }
                if blocks.contains(name) { out.append("\n") }
                continue
            }
            if scalar == "&" {
                var cursor = index + 1
                var entity = ""
                while cursor < count, cursor - index <= 32, scalars[cursor] != ";", scalars[cursor].properties.isAlphabetic || ("0"..."9").contains(scalars[cursor]) || scalars[cursor] == "#" {
                    entity.unicodeScalars.append(scalars[cursor])
                    cursor += 1
                }
                if cursor < count, scalars[cursor] == ";", let decoded = entityValue(entity) {
                    out.append(contentsOf: decoded.unicodeScalars)
                    index = cursor + 1
                    continue
                }
            }
            out.append(scalar.properties.isWhitespace ? " " : scalar)
            index += 1
        }

        var lines: [String] = []
        for line in String(out).split(separator: "\n", omittingEmptySubsequences: false) {
            let tidy = line.split(whereSeparator: { $0 == " " || $0 == "\u{A0}" }).joined(separator: " ")
            if tidy.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(tidy)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func entityValue(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "trade": "™",
            "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "bull": "•",
            "middot": "·", "euro": "€", "pound": "£", "zwnj": "", "zwj": "", "shy": "",
        ]
        return named[entity.lowercased()]
    }
}

private extension MailParser.Found.Segment {
    var text: String {
        switch self {
        case .plain(let text), .html(_, let text): text
        }
    }
}

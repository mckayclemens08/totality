import Foundation
import TotalityCore
import UniformTypeIdentifiers

/// Writes a draft as an RFC 5322 message: plain text in UTF-8, quoted-printable, with any attachments
/// alongside as base64. Lines end in CRLF, every header line stays under 998 bytes, and no value the
/// person typed can end a header early or start a new one.
public enum MailWriter {
    /// `message` names the message in its `Message-ID`, so a reply can point back at it. Bcc is written
    /// only into your own Sent copy (`keepingBcc`), never into what's delivered.
    public static func write(
        _ draft: MailDraft, from username: String, message: UUID, date: Date, keepingBcc: Bool = false, timeZone: TimeZone = .current
    ) -> Data {
        var headers: [String] = []
        headers.append("From: " + MailDomain.address(for: username))
        if !draft.to.isEmpty { headers.append(addressField("To", draft.to)) }
        if !draft.cc.isEmpty { headers.append(addressField("Cc", draft.cc)) }
        if keepingBcc, !draft.bcc.isEmpty { headers.append(addressField("Bcc", draft.bcc)) }
        headers.append("Subject: " + encoded(oneLine(draft.subject)))
        headers.append("Date: " + rfc5322Date(date, timeZone: timeZone))
        headers.append("Message-ID: " + messageID(message))
        if let origin = draft.origin, origin.kind == .reply, let answered = origin.messageID.flatMap(cleanID) {
            headers.append("In-Reply-To: <\(answered)>")
            let thread = (origin.references.compactMap(cleanID) + [answered]).reduce(into: [String]()) { list, id in
                if !list.contains(id) { list.append(id) }
            }
            headers.append("References: " + thread.map { "<\($0)>" }.joined(separator: "\r\n "))
        }
        headers.append("MIME-Version: 1.0")

        let text = quotedPrintable(draft.body)
        var out = headers.joined(separator: "\r\n") + "\r\n"
        if draft.attachments.isEmpty {
            out += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" + text + "\r\n"
            return Data(out.utf8)
        }
        let boundary = "totality-" + message.uuidString.lowercased()
        out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        out += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
        out += text + "\r\n"
        for attachment in draft.attachments {
            out += "--\(boundary)\r\n"
            out += "Content-Type: \(mimeType(attachment));\r\n" + parameter("name", attachment.name) + "\r\n"
            out += "Content-Disposition: attachment;\r\n" + parameter("filename", attachment.name) + "\r\n"
            out += "Content-Transfer-Encoding: base64\r\n\r\n"
            out += attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            out += "\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }

    public static func messageID(_ message: UUID) -> String {
        "<\(message.uuidString.lowercased())@\(MailDomain.name)>"
    }

    // MARK: Headers

    /// Line breaks and other controls would end a header and start another, so they become spaces.
    static func oneLine(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
    }

    /// Printable ASCII stays as it is. Anything else becomes RFC 2047 encoded words, split between
    /// characters, never inside one, and short enough that each fits on its own line.
    static func encoded(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }), value.utf8.count <= 900 { return value }
        var words: [Data] = []
        var chunk = Data()
        for character in value {
            let bytes = Data(String(character).utf8)
            if chunk.count + bytes.count > 45, !chunk.isEmpty {
                words.append(chunk)
                chunk = Data()
            }
            chunk += bytes
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\($0.base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    private static func addressField(_ name: String, _ list: [MailAddress]) -> String {
        "\(name): " + list.map(address).joined(separator: ",\r\n ")
    }

    static func address(_ address: MailAddress) -> String {
        let bare = oneLine(address.address).trimmingCharacters(in: .whitespaces)
        let name = oneLine(address.name).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.lowercased() != bare.lowercased() else { return bare }
        if name.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(bare)>"
        }
        return "\(encoded(name)) <\(bare)>"
    }

    static func cleanID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        guard !trimmed.isEmpty, trimmed.count <= 250,
              trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) && $0 != "<" && $0 != ">" })
        else { return nil }
        return trimmed
    }

    static func rfc5322Date(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// RFC 2231, so any name survives: plain when it's simple ASCII, or UTF-8 percent-encoded in
    /// sections short enough to keep every line well under the limit.
    static func parameter(_ name: String, _ value: String) -> String {
        let clean = oneLine(value)
        if !clean.isEmpty, clean.count <= 60,
           clean.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) && $0 != "\"" && $0 != "\\" }) {
            return " \(name)=\"\(clean)\""
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)
        var pieces: [String] = []
        var current = ""
        for byte in clean.utf8 {
            let token = allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
            if current.count + token.count > 60 {
                pieces.append(current)
                current = ""
            }
            current += token
        }
        pieces.append(current)
        if pieces.count == 1 { return " \(name)*=utf-8''\(pieces[0])" }
        return pieces.enumerated().map { index, piece in
            " \(name)*\(index)*=" + (index == 0 ? "utf-8''" : "") + piece
        }.joined(separator: ";\r\n")
    }

    static func mimeType(_ attachment: MailDraftAttachment) -> String {
        let given = attachment.mimeType.lowercased()
        let parts = given.split(separator: "/", omittingEmptySubsequences: false)
        let token = Set("abcdefghijklmnopqrstuvwxyz0123456789!#$&-^_.+".utf8)
        if parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(token.contains) }) { return given }
        return UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: Body

    /// Lines end in CRLF and stay within 76 characters, with soft breaks where a line runs longer.
    /// Spaces at the end of a line, a leading dot, and a leading "From " are encoded, so nothing on the
    /// way can change them.
    static func quotedPrintable(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line -> String in
            let bytes = Array(line.utf8)
            var out = ""
            var width = 0
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let literal: Bool
                switch byte {
                case 0x20, 0x09: literal = !isLast
                case 0x3D: literal = false
                case 0x2E where index == 0: literal = false
                case 0x46 where index == 0 && bytes.starts(with: Array("From ".utf8)): literal = false
                case 0x21...0x7E: literal = true
                default: literal = false
                }
                let token = literal ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                if width + token.count > 75 {
                    out += "=\r\n"
                    width = 0
                }
                out += token
                width += token.count
            }
            return out
        }.joined(separator: "\r\n")
    }
}

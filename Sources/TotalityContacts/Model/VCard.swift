import Foundation

/// A card as a vCard 3.0 file, for sharing through the share sheet (issue 205, section 2). A shared vCard is
/// a plain file that whoever gets it can read, so the person's own notes, labels and photo stay out unless
/// they choose to include them.
public enum VCard {
    public struct Options: Hashable, Sendable {
        public var notes: Bool
        public var labels: Bool
        public var photo: Bool

        public init(notes: Bool = false, labels: Bool = false, photo: Bool = false) {
            self.notes = notes
            self.labels = labels
            self.photo = photo
        }
    }

    public static func text(_ card: ContactCard, options: Options = Options()) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        lines.append("N:\(escape(card.familyName));\(escape(card.givenName));;;")
        lines.append("FN:\(escape(card.name))")
        if !card.nickname.isEmpty { lines.append("NICKNAME:\(escape(card.nickname))") }
        if !card.company.isEmpty { lines.append("ORG:\(escape(card.company))") }
        for phone in card.phones where !phone.isEmpty {
            lines.append("TEL;TYPE=\(type(phone.label)):\(escape(phone.value))")
        }
        for email in card.emails where !email.isEmpty {
            lines.append("EMAIL;TYPE=INTERNET,\(type(email.label)):\(escape(email.value))")
        }
        if let address = card.totalityAddress, !card.emailAddresses.contains(where: { $0.lowercased() == address }) {
            lines.append("EMAIL;TYPE=INTERNET:\(escape(address))")
        }
        for place in card.addresses where !place.isEmpty {
            let parts = ["", "", place.street, place.city, place.region, place.postcode, place.country].map(escape)
            lines.append("ADR;TYPE=\(type(place.label)):\(parts.joined(separator: ";"))")
        }
        if let birthday = card.birthday, birthday.isValid {
            let month = String(format: "%02d", birthday.month), day = String(format: "%02d", birthday.day)
            lines.append(birthday.year.map { "BDAY:\(String(format: "%04d", $0))-\(month)-\(day)" } ?? "BDAY:--\(month)-\(day)")
        }
        if let handle = card.username {
            lines.append("URL:https://usetotality.com/@\(handle)")
        }
        if options.labels, !card.labels.isEmpty {
            lines.append("CATEGORIES:\(card.labels.map(escape).joined(separator: ","))")
        }
        if options.notes, !card.notes.isEmpty { lines.append("NOTE:\(escape(card.notes))") }
        if options.photo, let photo = card.photo {
            lines.append("PHOTO;ENCODING=b;TYPE=JPEG:\(photo.base64EncodedString())")
        }
        lines.append("END:VCARD")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// A file name for the shared card, such as "Sam Okafor.vcf", with nothing a file system would refuse.
    public static func fileName(_ card: ContactCard) -> String {
        let refused = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let safe = String(card.name.unicodeScalars.map { refused.contains($0) ? Character("-") : Character($0) })
        return String(safe.trimmingCharacters(in: .whitespaces).prefix(60)) + ".vcf"
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    static func type(_ label: String) -> String {
        switch label.lowercased() {
        case "mobile", "cell", "iphone": "CELL"
        case "home": "HOME"
        case "work": "WORK"
        default: "OTHER"
        }
    }

    /// Lines longer than 75 bytes continue on the next line after a space, never splitting a character.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out = "", count = 0
        for character in line {
            let size = String(character).utf8.count
            if count + size > 75 {
                out += "\r\n "
                count = 1
            }
            out.append(character)
            count += size
        }
        return out
    }
}

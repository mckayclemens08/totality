import Foundation

/// A reference library: CSL JSON, the format Zotero, Pandoc and citation styles share. A `.bib` file is
/// converted to it on import, so every library is stored the same way, sealed like any Reader file.
public enum References {
    public static let mime = "application/vnd.citationstyles.csl+json"
    /// More than any thesis cites, and few enough that a hostile file can't make a page slow.
    static let maxItems = 20_000

    /// One reference, as the citation picker lists it.
    public struct Summary: Sendable, Equatable, Identifiable {
        public let id: String
        public let author: String
        public let year: String
        public let title: String
    }

    // MARK: Reading a file in

    /// The CSL JSON to store for an imported file, or nil if it isn't a reference library.
    static func library(from data: Data, filename: String) -> Data? {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "bib" || ext == "bibtex" {
            let items = BibTeX.items(String(decoding: data, as: UTF8.self))
            return items.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        }
        if ext == "json" || ext == "csljson" {
            guard let items = cslItems(data), !items.isEmpty else { return nil }
            return try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        }
        return nil
    }

    /// CSL JSON items, kept only if each has an id and a type. Anything else in the file is dropped.
    static func cslItems(_ data: Data) -> [[String: Any]]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list = (parsed as? [[String: Any]]) ?? ((parsed as? [String: Any]).map { [$0] } ?? [])
        let items = list.prefix(maxItems).compactMap { item -> [String: Any]? in
            guard let id = item["id"].map({ "\($0)" }), !id.isEmpty, item["type"] is String else { return nil }
            var clean = item
            clean["id"] = id
            return clean
        }
        return items.isEmpty ? nil : items
    }

    // MARK: Reading a library back

    public static func summaries(_ data: Data) -> [Summary] {
        (cslItems(data) ?? []).map(summary)
    }

    static func summary(_ item: [String: Any]) -> Summary {
        let people = (item["author"] as? [[String: Any]]) ?? (item["editor"] as? [[String: Any]]) ?? []
        let names = people.compactMap { ($0["family"] as? String) ?? ($0["literal"] as? String) }
        let author: String
        switch names.count {
        case 0: author = ""
        case 1: author = names[0]
        case 2: author = "\(names[0]) and \(names[1])"
        default: author = "\(names[0]) et al."
        }
        let parts = ((item["issued"] as? [String: Any])?["date-parts"] as? [[Any]])?.first?.first
        return Summary(
            id: item["id"] as? String ?? "",
            author: author,
            year: parts.map { "\($0)" } ?? "",
            title: item["title"] as? String ?? ""
        )
    }

    /// What search and Listen read for a library: one line per reference.
    static func readableText(_ data: Data) -> String {
        summaries(data).map { [$0.author, $0.year, $0.title].filter { !$0.isEmpty }.joined(separator: ", ") }.joined(separator: "\n")
    }
}

/// Reads BibTeX, the format most reference managers export, into CSL JSON items.
enum BibTeX {
    static func items(_ text: String) -> [[String: Any]] {
        var parser = Parser(Array(text.unicodeScalars))
        return parser.entries().prefix(References.maxItems).map(csl)
    }

    struct Entry {
        var type: String
        var key: String
        var fields: [String: String]
    }

    struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        var strings: [String: String] = [
            "jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May", "jun": "June",
            "jul": "July", "aug": "August", "sep": "September", "oct": "October", "nov": "November", "dec": "December",
        ]

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        mutating func entries() -> [Entry] {
            var found: [Entry] = []
            while index < scalars.count {
                guard scalars[index] == "@" else {
                    index += 1
                    continue
                }
                index += 1
                let type = word().lowercased()
                skipSpace()
                guard index < scalars.count, scalars[index] == "{" || scalars[index] == "(" else { continue }
                let close: Unicode.Scalar = scalars[index] == "{" ? "}" : ")"
                index += 1
                switch type {
                case "comment", "preamble":
                    skipBalanced(close)
                case "string":
                    let fields = self.fields(until: close)
                    for (name, value) in fields { strings[name] = value }
                default:
                    skipSpace()
                    let key = until([",", close]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if index < scalars.count, scalars[index] == "," { index += 1 }
                    let fields = self.fields(until: close)
                    if !key.isEmpty, !type.isEmpty { found.append(Entry(type: type, key: key, fields: fields)) }
                }
            }
            return found
        }

        private mutating func fields(until close: Unicode.Scalar) -> [String: String] {
            var fields: [String: String] = [:]
            while index < scalars.count {
                skipSpace()
                if index < scalars.count, scalars[index] == close {
                    index += 1
                    break
                }
                if index < scalars.count, scalars[index] == "," {
                    index += 1
                    continue
                }
                let name = word().lowercased()
                skipSpace()
                guard !name.isEmpty, index < scalars.count, scalars[index] == "=" else {
                    // Not a field: skip to the next comma or the end of the entry.
                    _ = until([",", close])
                    continue
                }
                index += 1
                fields[name] = value(close: close)
            }
            return fields
        }

        /// A value: braces, quotes, a number or a macro, joined by `#`.
        private mutating func value(close: Unicode.Scalar) -> String {
            var result = ""
            while index < scalars.count {
                skipSpace()
                guard index < scalars.count else { break }
                let character = scalars[index]
                if character == "{" {
                    index += 1
                    result += balanced(open: "{", close: "}")
                } else if character == "\"" {
                    index += 1
                    result += quoted()
                } else {
                    let raw = word()
                    if raw.isEmpty { break }
                    result += strings[raw.lowercased()] ?? raw
                }
                skipSpace()
                if index < scalars.count, scalars[index] == "#" {
                    index += 1
                    continue
                }
                break
            }
            return result
        }

        /// Text up to the matching close brace, keeping inner braces, which BibTeX uses to protect case.
        private mutating func balanced(open: Unicode.Scalar, close: Unicode.Scalar) -> String {
            var depth = 1
            var text = String.UnicodeScalarView()
            while index < scalars.count {
                let character = scalars[index]
                index += 1
                if character == "\\", index < scalars.count {
                    text.append(character)
                    text.append(scalars[index])
                    index += 1
                    continue
                }
                if character == open { depth += 1 }
                if character == close {
                    depth -= 1
                    if depth == 0 { break }
                }
                text.append(character)
            }
            return String(text)
        }

        private mutating func quoted() -> String {
            var depth = 0
            var text = String.UnicodeScalarView()
            while index < scalars.count {
                let character = scalars[index]
                index += 1
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
                if character == "\"", depth <= 0 { break }
                text.append(character)
            }
            return String(text)
        }

        private mutating func skipBalanced(_ close: Unicode.Scalar) {
            _ = balanced(open: close == "}" ? "{" : "(", close: close)
        }

        private mutating func word() -> String {
            var text = String.UnicodeScalarView()
            while index < scalars.count {
                let character = scalars[index]
                if CharacterSet.alphanumerics.contains(character) || "_-:./+".unicodeScalars.contains(character) {
                    text.append(character)
                    index += 1
                } else {
                    break
                }
            }
            return String(text)
        }

        private mutating func until(_ stops: Set<Unicode.Scalar>) -> String {
            var text = String.UnicodeScalarView()
            while index < scalars.count, !stops.contains(scalars[index]) {
                text.append(scalars[index])
                index += 1
            }
            return String(text)
        }

        private mutating func skipSpace() {
            while index < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) { index += 1 }
        }
    }

    // MARK: Converting to CSL

    static let types: [String: String] = [
        "article": "article-journal", "book": "book", "booklet": "book", "inbook": "chapter",
        "incollection": "chapter", "inproceedings": "paper-conference", "conference": "paper-conference",
        "manual": "report", "mastersthesis": "thesis", "phdthesis": "thesis", "thesis": "thesis",
        "techreport": "report", "report": "report", "unpublished": "manuscript", "online": "webpage",
        "electronic": "webpage", "www": "webpage", "misc": "document",
    ]

    static func csl(_ entry: Entry) -> [String: Any] {
        let fields = entry.fields.mapValues(latex)
        var item: [String: Any] = ["id": entry.key, "type": types[entry.type] ?? "document"]
        if let title = fields["title"] { item["title"] = title }
        if let container = fields["journal"] ?? fields["journaltitle"] ?? fields["booktitle"] { item["container-title"] = container }
        for (bib, key) in [("publisher", "publisher"), ("volume", "volume"), ("number", "issue"), ("edition", "edition"),
                           ("doi", "DOI"), ("url", "URL"), ("isbn", "ISBN"), ("issn", "ISSN"), ("note", "note"),
                           ("abstract", "abstract"), ("series", "collection-title")] {
            if let value = fields[bib], !value.isEmpty { item[key] = value }
        }
        if let place = fields["address"] ?? fields["location"] { item["publisher-place"] = place }
        if let institution = fields["school"] ?? fields["institution"], item["publisher"] == nil { item["publisher"] = institution }
        if entry.type == "phdthesis" { item["genre"] = "PhD thesis" }
        if entry.type == "mastersthesis" { item["genre"] = "Master's thesis" }
        if let pages = fields["pages"] { item["page"] = pages.replacingOccurrences(of: "--", with: "–") }
        if let author = entry.fields["author"] { item["author"] = names(author) }
        if let editor = entry.fields["editor"] { item["editor"] = names(editor) }
        if let date = fields["date"] ?? fields["year"] {
            let parts = date.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if let year = parts.first {
                var dateParts = [year]
                if parts.count > 1 { dateParts += parts.dropFirst().prefix(2) } else if let month = fields["month"].flatMap(monthNumber) { dateParts.append(month) }
                item["issued"] = ["date-parts": [dateParts]]
            }
        }
        return item
    }

    private static func monthNumber(_ month: String) -> Int? {
        if let number = Int(month), (1...12).contains(number) { return number }
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        return names.firstIndex { $0.hasPrefix(month.lowercased().prefix(3)) }.map { $0 + 1 }
    }

    /// "Last, First and First Last and {Organisation Name}" as CSL names.
    static func names(_ raw: String) -> [[String: String]] {
        splitNames(raw).map { name -> [String: String] in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") { return ["literal": latex(trimmed)] }
            let parts = splitTop(trimmed, on: ",")
            if parts.count >= 2 {
                return ["family": latex(parts[0]), "given": latex(parts.dropFirst().joined(separator: " "))]
            }
            let words = splitTop(trimmed, on: " ").filter { !$0.isEmpty }
            guard words.count > 1 else { return ["family": latex(trimmed)] }
            // A lower-case word like "van" or "de" starts the family name.
            let start = words.dropLast().firstIndex { $0.first?.isLowercase == true } ?? words.count - 1
            return ["family": latex(words[start...].joined(separator: " ")), "given": latex(words[..<start].joined(separator: " "))]
        }
        .filter { !($0["family"] ?? $0["literal"] ?? "").isEmpty }
    }

    private static func splitNames(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        let words = raw.replacingOccurrences(of: "\n", with: " ").split(separator: " ", omittingEmptySubsequences: false)
        for word in words {
            depth += word.filter { $0 == "{" }.count - word.filter { $0 == "}" }.count
            if depth == 0, word.lowercased() == "and" {
                result.append(current)
                current = ""
            } else {
                current += (current.isEmpty ? "" : " ") + word
            }
        }
        result.append(current)
        return result.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func splitTop(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == separator, depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private static let accents: [Character: [Character: String]] = [
        "'": ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý", "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú", "c": "ć", "n": "ń", "s": "ś", "z": "ź"],
        "`": ["a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù", "A": "À", "E": "È", "O": "Ò"],
        "\"": ["a": "ä", "e": "ë", "i": "ï", "o": "ö", "u": "ü", "y": "ÿ", "A": "Ä", "E": "Ë", "O": "Ö", "U": "Ü"],
        "^": ["a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û", "A": "Â", "E": "Ê", "O": "Ô"],
        "~": ["a": "ã", "n": "ñ", "o": "õ", "A": "Ã", "N": "Ñ", "O": "Õ"],
        "c": ["c": "ç", "C": "Ç", "s": "ş"],
        "v": ["c": "č", "s": "š", "z": "ž", "r": "ř", "e": "ě", "C": "Č", "S": "Š", "Z": "Ž"],
    ]

    private static let symbols: [String: String] = [
        "ss": "ß", "o": "ø", "O": "Ø", "ae": "æ", "AE": "Æ", "aa": "å", "AA": "Å", "l": "ł", "L": "Ł", "i": "ı",
    ]

    /// LaTeX to plain text: accents, escaped characters, dashes and ties, and case-protecting braces gone.
    static func latex(_ text: String) -> String {
        var result = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if let table = accents[next] {
                    var target = index + 2
                    if target < characters.count, characters[target] == " " { target += 1 }
                    var braced = false
                    if target < characters.count, characters[target] == "{" {
                        braced = true
                        target += 1
                    }
                    // `\'\i` puts the accent on a dotless i, which reads as a plain i.
                    var letter = target < characters.count ? characters[target] : " "
                    var after = target + 1
                    if letter == "\\", target + 1 < characters.count, "ij".contains(characters[target + 1]),
                       target + 2 >= characters.count || !characters[target + 2].isLetter {
                        letter = characters[target + 1]
                        after = target + 2
                        if after < characters.count, characters[after] == " " { after += 1 }
                    }
                    if let mapped = table[letter] {
                        result += mapped
                        index = after + (braced && after < characters.count && characters[after] == "}" ? 1 : 0)
                        continue
                    }
                }
                if "&%$#_{}".contains(next) {
                    result.append(next)
                    index += 2
                    continue
                }
                var end = index + 1
                while end < characters.count, characters[end].isLetter { end += 1 }
                let command = String(characters[(index + 1)..<end])
                if let symbol = symbols[command] {
                    result += symbol
                    index = end
                    if index < characters.count, characters[index] == " " { index += 1 }
                    continue
                }
                // Formatting commands like \emph or \textit keep their words.
                index = end
                if index < characters.count, characters[index] == " " { index += 1 }
                continue
            }
            if character == "{" || character == "}" {
                index += 1
                continue
            }
            if character == "~" {
                result.append("\u{00A0}")
                index += 1
                continue
            }
            result.append(character)
            index += 1
        }
        return result
            .replacingOccurrences(of: "---", with: "—")
            .replacingOccurrences(of: "--", with: "–")
            .replacingOccurrences(of: "``", with: "“")
            .replacingOccurrences(of: "''", with: "”")
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }
}

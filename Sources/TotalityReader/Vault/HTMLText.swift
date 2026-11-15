import Foundation

/// Reads the words out of an HTML file, for Listen, search and the plain text view. HTML from the web is
/// rarely valid XML, so this is a forgiving scanner, not a parser: it never builds a tree, never fetches
/// anything, and never runs anything. Its one job is to give the words a reader would see, in order,
/// with the same parts left out that the book page's read-along script leaves out.
enum HTMLText {
    static let mimes: Set<String> = ["text/html", "application/xhtml+xml"]

    private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote", "br", "tr", "td", "th", "section", "article", "pre", "ul", "ol", "table",
        "hr", "header", "footer", "main", "aside", "figure", "figcaption", "dd", "dt", "dl", "h1", "h2", "h3",
        "h4", "h5", "h6", "body",
    ]
    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    /// Their words aren't read. The read-along script skips the same ones.
    private static let skippedTags: Set<String> = ["head", "script", "style", "svg", "template", "nav", "noscript", "title"]
    /// Their contents are raw text, so a `<` inside them doesn't start a tag.
    private static let rawTags: Set<String> = ["script", "style", "title", "textarea", "noscript", "template"]

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "mdash": "\u{2014}",
        "ndash": "\u{2013}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}",
        "rdquo": "\u{201D}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "eacute": "\u{00E9}",
        "egrave": "\u{00E8}", "aacute": "\u{00E1}", "agrave": "\u{00E0}", "iacute": "\u{00ED}", "oacute": "\u{00F3}",
        "uacute": "\u{00FA}", "ntilde": "\u{00F1}", "ccedil": "\u{00E7}", "uuml": "\u{00FC}", "ouml": "\u{00F6}",
        "auml": "\u{00E4}", "szlig": "\u{00DF}", "middot": "\u{00B7}", "bull": "\u{2022}", "deg": "\u{00B0}",
        "pound": "\u{00A3}", "euro": "\u{20AC}", "times": "\u{00D7}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "shy": "",
    ]

    /// The words, as headings and paragraphs, and the file's title if it names one.
    static func read(_ data: Data) -> (title: String?, document: ReadableDocument) {
        var scanner = Scanner(Array(decoded(data).unicodeScalars))
        scanner.run()
        return (scanner.title, ReadableDocument(sections: [.init(blocks: scanner.blocks)]))
    }

    /// UTF-8 unless the file starts by saying otherwise with a byte order mark.
    private static func decoded(_ data: Data) -> String {
        let start = Array(data.prefix(3))
        if start.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) ?? "" }
        if start.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) ?? "" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Scanner {
        let input: [Unicode.Scalar]
        var index = 0
        var blocks: [ReadableDocument.Block] = []
        var title: String?
        private var current = ""
        private var skipDepth = 0
        private var headingDepth = 0
        private var total = 0

        init(_ input: [Unicode.Scalar]) {
            self.input = input
        }

        mutating func run() {
            while index < input.count, total <= SafeXML.maxCharacters {
                if input[index] == "<", let next = peek(1), next.properties.isAlphabetic || next == "/" || next == "!" || next == "?" {
                    tag()
                } else {
                    text()
                }
            }
            flush()
        }

        private func peek(_ ahead: Int) -> Unicode.Scalar? {
            index + ahead < input.count ? input[index + ahead] : nil
        }

        private mutating func text() {
            let start = index
            while index < input.count, !(input[index] == "<" && isTagStart(index)) { index += 1 }
            guard skipDepth == 0 else { return }
            let piece = HTMLText.decodeEntities(String(String.UnicodeScalarView(input[start..<index])))
            total += piece.utf16.count
            current += piece
        }

        private func isTagStart(_ at: Int) -> Bool {
            guard at + 1 < input.count else { return false }
            let next = input[at + 1]
            return next.properties.isAlphabetic || next == "/" || next == "!" || next == "?"
        }

        private mutating func tag() {
            // Comments, doctypes and processing instructions hold nothing to read.
            if starts(with: "<!--") {
                index = find("-->", from: index + 4).map { $0 + 3 } ?? input.count
                return
            }
            if input[index + 1] == "!" || input[index + 1] == "?" {
                index = find(">", from: index).map { $0 + 1 } ?? input.count
                return
            }
            let closing = input[index + 1] == "/"
            var cursor = index + (closing ? 2 : 1)
            var name = ""
            while cursor < input.count, input[cursor].properties.isAlphabetic || ("0"..."9").contains(input[cursor]) || input[cursor] == "-" || input[cursor] == ":" {
                name.unicodeScalars.append(input[cursor])
                cursor += 1
            }
            name = SafeXML.localName(name)
            // The end of the tag, past any quoted attribute that holds a `>`.
            var quote: Unicode.Scalar?
            var selfClosing = false
            while cursor < input.count {
                let scalar = input[cursor]
                if let open = quote {
                    if scalar == open { quote = nil }
                } else if scalar == "\"" || scalar == "'" {
                    quote = scalar
                } else if scalar == ">" {
                    selfClosing = cursor > 0 && input[cursor - 1] == "/"
                    break
                }
                cursor += 1
            }
            index = min(input.count, cursor + 1)
            if closing {
                end(name)
            } else {
                begin(name, selfClosing: selfClosing)
            }
        }

        private mutating func begin(_ name: String, selfClosing: Bool) {
            // A body means the head is over, closed or not.
            if name == "body", skipDepth > 0 { skipDepth = 0 }
            if HTMLText.blockTags.contains(name) { flush() }
            if HTMLText.headingTags.contains(name) { headingDepth += 1 }
            guard !selfClosing else {
                if HTMLText.headingTags.contains(name) { headingDepth = max(0, headingDepth - 1) }
                return
            }
            if name == "title", title == nil {
                let close = find("</", from: index) ?? input.count
                let words = HTMLText.decodeEntities(String(String.UnicodeScalarView(input[index..<close])))
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                title = words.isEmpty ? nil : String(words.prefix(SafeXML.maxTitleLength))
            }
            if HTMLText.rawTags.contains(name) {
                // Skip to its own end tag, whatever is inside.
                let close = findEndTag(name) ?? input.count
                if HTMLText.skippedTags.contains(name) || skipDepth > 0 {
                    index = close
                } else {
                    let words = HTMLText.decodeEntities(String(String.UnicodeScalarView(input[index..<close])))
                    total += words.utf16.count
                    current += words
                    index = close
                }
                return
            }
            if HTMLText.skippedTags.contains(name) { skipDepth += 1 }
        }

        private mutating func end(_ name: String) {
            if HTMLText.skippedTags.contains(name), !HTMLText.rawTags.contains(name) { skipDepth = max(0, skipDepth - 1) }
            if HTMLText.blockTags.contains(name) || HTMLText.headingTags.contains(name) { flush() }
            if HTMLText.headingTags.contains(name) { headingDepth = max(0, headingDepth - 1) }
        }

        private mutating func flush() {
            let text = current.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { blocks.append(.init(text: text, isHeading: headingDepth > 0)) }
            current = ""
        }

        private func starts(with marker: String) -> Bool {
            let scalars = Array(marker.unicodeScalars)
            guard index + scalars.count <= input.count else { return false }
            return Array(input[index..<(index + scalars.count)]) == scalars
        }

        private func find(_ marker: String, from start: Int) -> Int? {
            let scalars = Array(marker.unicodeScalars)
            var at = start
            while at + scalars.count <= input.count {
                if input[at] == scalars[0], Array(input[at..<(at + scalars.count)]) == scalars { return at }
                at += 1
            }
            return nil
        }

        /// Where `</name` starts, in any case.
        private func findEndTag(_ name: String) -> Int? {
            let wanted = Array(name.lowercased().unicodeScalars)
            var at = index
            while at + 2 + wanted.count <= input.count {
                if input[at] == "<", input[at + 1] == "/" {
                    let candidate = String(String.UnicodeScalarView(input[(at + 2)..<(at + 2 + wanted.count)])).lowercased()
                    if Array(candidate.unicodeScalars) == wanted { return at }
                }
                at += 1
            }
            return nil
        }
    }

    /// Named entities from a short list, and every numbered one. Anything else stays as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.prefix(12).firstIndex(of: ";") {
                let name = after[..<semicolon]
                if let value = character(for: name) {
                    result += value
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        result += rest
        return result
    }

    private static func character(for name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            // Nothing that isn't a character, and no control characters but the spaces.
            guard let value, let scalar = Unicode.Scalar(value), value >= 0x20 || value == 0x09 || value == 0x0A else { return nil }
            return String(scalar)
        }
        return entities[String(name)]
    }
}

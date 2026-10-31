import Foundation

/// A doc's contents: paragraphs of styled text. It's stored as a small subset of Markdown, so it stays
/// readable, comes out the same on every device, and carries no fonts or colours.
public struct DocText: Sendable, Equatable {
    public enum Style: String, Sendable, CaseIterable {
        case body, heading1, heading2, bullet, numbered

        public var isList: Bool {
            self == .bullet || self == .numbered
        }
    }

    public struct Run: Sendable, Equatable {
        public var text: String
        public var bold = false
        public var italic = false
        public var link: URL? = nil

        public init(_ text: String, bold: Bool = false, italic: Bool = false, link: URL? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.link = link
        }
    }

    public struct Paragraph: Sendable, Equatable {
        public var style: Style
        public var runs: [Run]

        public init(_ style: Style = .body, runs: [Run] = []) {
            self.style = style
            self.runs = Self.merged(runs)
        }

        public var text: String {
            runs.map(\.text).joined()
        }

        fileprivate func split(at offset: Int) -> (before: [Run], after: [Run]) {
            var before: [Run] = []
            var after: [Run] = []
            var remaining = offset
            for run in runs {
                let length = run.text.utf16.count
                if remaining >= length {
                    before.append(run)
                } else if remaining <= 0 {
                    after.append(run)
                } else {
                    let middle = String.Index(utf16Offset: remaining, in: run.text)
                    var (head, tail) = (run, run)
                    head.text = String(run.text[..<middle])
                    tail.text = String(run.text[middle...])
                    before.append(head)
                    after.append(tail)
                }
                remaining -= length
            }
            return (before, after)
        }

        /// Neighbouring runs that look the same become one, so equal text compares equal.
        private static func merged(_ runs: [Run]) -> [Run] {
            var result: [Run] = []
            for run in runs where !run.text.isEmpty {
                if let last = result.last, last.bold == run.bold, last.italic == run.italic, last.link == run.link {
                    result[result.count - 1].text += run.text
                } else {
                    result.append(run)
                }
            }
            return result
        }
    }

    public var paragraphs: [Paragraph]

    public init(paragraphs: [Paragraph] = [Paragraph()]) {
        self.paragraphs = paragraphs.isEmpty ? [Paragraph()] : paragraphs
    }

    /// A note from before docs had formatting. Nothing in it means anything but itself.
    public init(plain text: String) {
        self.init(paragraphs: Self.lines(text).map { Paragraph(runs: [Run($0)]) })
    }

    public init(markdown: String) {
        self.init(paragraphs: Self.lines(markdown).map(Self.paragraph))
    }

    /// What Listen speaks and search looks through.
    public var plainText: String {
        paragraphs.map(\.text).joined(separator: "\n")
    }

    public var markdown: String {
        var number = 0
        return paragraphs.map { paragraph in
            number = paragraph.style == .numbered ? number + 1 : 0
            let text = paragraph.runs.map(Self.markdown).joined()
            switch paragraph.style {
            case .body: return Self.escapingStart(text)
            case .heading1: return "# \(text)"
            case .heading2: return "## \(text)"
            case .bullet: return "- \(text)"
            case .numbered: return "\(number). \(text)"
            }
        }.joined(separator: "\n")
    }

    /// Only these open from a doc, so a link can't start anything but a browser or a mail app.
    public static func isOpenable(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    // MARK: Editing

    /// Breaks a paragraph at a character offset. The new one starts as `style`.
    public mutating func split(paragraph index: Int, at offset: Int, into style: Style) {
        let (before, after) = paragraphs[index].split(at: offset)
        paragraphs[index] = Paragraph(paragraphs[index].style, runs: before)
        paragraphs.insert(Paragraph(style, runs: after), at: index + 1)
    }

    // MARK: Writing

    private static let specials: Set<Character> = ["\\", "*", "[", "]"]

    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if specials.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func markdown(_ run: Run) -> String {
        // Spaces stay outside the markers, because a marker next to a space reads badly in the file.
        let trimmed = run.text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, run.bold || run.italic || run.link != nil else { return escaped(run.text) }
        let leading = String(run.text.prefix { $0 == " " })
        let trailing = trimmed.count + leading.count < run.text.count
            ? String(run.text.suffix(run.text.count - trimmed.count - leading.count)) : ""
        var text = escaped(trimmed)
        if run.bold && run.italic {
            text = "***\(text)***"
        } else if run.bold {
            text = "**\(text)**"
        } else if run.italic {
            text = "*\(text)*"
        }
        if let link = run.link { text = "[\(text)](\(link.absoluteString))" }
        return leading + text + trailing
    }

    /// A body line that happens to look like a heading or a list has to stay a body line.
    private static func escapingStart(_ text: String) -> String {
        if text.hasPrefix("#") || text.hasPrefix("- ") { return "\\" + text }
        if let dot = numberedPrefix(text) {
            return text.prefix(dot) + "\\" + text.dropFirst(dot)
        }
        return text
    }

    private static func numberedPrefix(_ line: String) -> Int? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return digits.count
    }

    // MARK: Reading

    private static func paragraph(_ line: String) -> Paragraph {
        if line.hasPrefix("## ") { return Paragraph(.heading2, runs: runs(String(line.dropFirst(3)))) }
        if line.hasPrefix("# ") { return Paragraph(.heading1, runs: runs(String(line.dropFirst(2)))) }
        if line.hasPrefix("- ") { return Paragraph(.bullet, runs: runs(String(line.dropFirst(2)))) }
        if let digits = numberedPrefix(line) { return Paragraph(.numbered, runs: runs(String(line.dropFirst(digits + 2)))) }
        return Paragraph(runs: runs(line))
    }

    private static func runs(_ text: String) -> [Run] {
        var parser = InlineParser(Array(text))
        return parser.parse()
    }

    private struct InlineParser {
        let characters: [Character]
        var index = 0
        var bold = false
        var italic = false
        var pending = ""
        var result: [Run] = []
        var link: URL?

        init(_ characters: [Character]) {
            self.characters = characters
        }

        mutating func parse() -> [Run] {
            while index < characters.count {
                let character = characters[index]
                if character == "\\", index + 1 < characters.count, DocText.isEscapable(characters[index + 1]) {
                    pending.append(characters[index + 1])
                    index += 2
                } else if character == "*" {
                    marker()
                } else if character == "[", let target = linkTarget() {
                    openLink(target)
                } else {
                    pending.append(character)
                    index += 1
                }
            }
            flush()
            return result
        }

        private mutating func flush() {
            if !pending.isEmpty { result.append(Run(pending, bold: bold, italic: italic, link: link)) }
            pending = ""
        }

        private func count(of character: Character, at start: Int) -> Int {
            var end = start
            while end < characters.count, characters[end] == character { end += 1 }
            return end - start
        }

        /// A lone star is just a star, so `2 * 3` in an imported file stays as written.
        private func hasCloser(length: Int, after start: Int) -> Bool {
            var position = start
            while position < characters.count {
                if characters[position] == "\\" {
                    position += 2
                } else if characters[position] == "*" {
                    let run = count(of: "*", at: position)
                    if run >= length { return true }
                    position += run
                } else {
                    position += 1
                }
            }
            return false
        }

        private mutating func marker() {
            let length = min(count(of: "*", at: index), 3)
            let isClosing = (length == 3 && bold && italic) || (length == 2 && bold) || (length == 1 && italic)
            guard isClosing || hasCloser(length: length, after: index + length) else {
                pending.append("*")
                index += 1
                return
            }
            flush()
            if length != 1 { bold.toggle() }
            if length != 2 { italic.toggle() }
            index += length
        }

        /// `[words](address)`: the address, and where the words end, if this really is a link.
        private func linkTarget() -> (close: Int, end: Int, url: URL)? {
            guard link == nil, let close = closingBracket() else { return nil }
            guard close + 1 < characters.count, characters[close + 1] == "(",
                  let end = characters[(close + 2)...].firstIndex(of: ")"),
                  let url = URL(string: String(characters[(close + 2)..<end])), DocText.isOpenable(url)
            else { return nil }
            return (close, end, url)
        }

        private func closingBracket() -> Int? {
            var position = index + 1
            while position < characters.count {
                if characters[position] == "\\" {
                    position += 2
                } else if characters[position] == "]" {
                    return position
                } else {
                    position += 1
                }
            }
            return nil
        }

        private mutating func openLink(_ target: (close: Int, end: Int, url: URL)) {
            flush()
            var inner = InlineParser(Array(characters[(index + 1)..<target.close]))
            inner.bold = bold
            inner.italic = italic
            inner.link = target.url
            result += inner.parse()
            index = target.end + 1
        }
    }

    fileprivate static func isEscapable(_ character: Character) -> Bool {
        specials.contains(character) || character == "#" || character == "-" || character == "."
    }
}

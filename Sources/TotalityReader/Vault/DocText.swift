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

    /// Longer than this isn't kept as a link, which also keeps a hostile line from being slow to read.
    public static let maxLinkLength = 2048

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
        let isSpace = { (character: Character) in character.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) }
        let leading = String(run.text.prefix(while: isSpace))
        guard leading.count < run.text.count, run.bold || run.italic || run.link != nil else { return escaped(run.text) }
        let trailing = String(run.text.reversed().prefix(while: isSpace).reversed())
        var text = escaped(String(run.text.dropFirst(leading.count).dropLast(trailing.count)))
        if run.bold && run.italic {
            text = "***\(text)***"
        } else if run.bold {
            text = "**\(text)**"
        } else if run.italic {
            text = "*\(text)*"
        }
        if let link = run.link {
            let address = link.absoluteString.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
            text = "[\(text)](\(address))"
        }
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
        /// Where each `(` closes, and every `]`, found once so that a line of nothing but `[a](` stays
        /// quick. Worked out per line, and escaped characters don't count.
        private var addressEnds: [Int: Int] = [:]
        private var brackets: [Int] = []
        private var nextBracket = 0

        init(_ characters: [Character]) {
            self.characters = characters
            var open: [Int] = []
            var position = 0
            while position < characters.count {
                switch characters[position] {
                case "\\": position += 1
                case "]": brackets.append(position)
                case "(": open.append(position)
                case ")": if let start = open.popLast() { addressEnds[start] = position }
                default: break
                }
                position += 1
            }
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

        /// Stops at four, because no marker needs to know more, and a line of nothing but stars stays quick.
        private func stars(at start: Int) -> Int {
            var end = start
            while end < characters.count, end - start < 4, characters[end] == "*" { end += 1 }
            return end - start
        }

        /// A lone star is just a star, so `2 * 3` in an imported file stays as written.
        private func hasCloser(length: Int, after start: Int) -> Bool {
            var position = start
            while position < characters.count {
                if characters[position] == "\\" {
                    position += 2
                } else if characters[position] == "*" {
                    let run = stars(at: position)
                    if run >= length { return true }
                    position += run
                } else {
                    position += 1
                }
            }
            return false
        }

        /// How many stars of a run end what's open. Whatever's left over is read next, so bold running
        /// straight into italic closes one and opens the other.
        private func closingLength(_ run: Int) -> Int {
            if bold && italic { return min(run, 3) }
            if bold { return run >= 2 ? 2 : 0 }
            if italic { return run == 2 ? 0 : 1 }
            return 0
        }

        private mutating func marker() {
            let run = stars(at: index)
            let closing = closingLength(run)
            let length = closing > 0 ? closing : min(run, 3)
            guard closing > 0 || hasCloser(length: length, after: index + length) else {
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
        private mutating func linkTarget() -> (close: Int, end: Int, url: URL)? {
            guard link == nil, let close = closingBracket() else { return nil }
            guard close + 1 < characters.count, characters[close + 1] == "(",
                  let end = addressEnds[close + 1], end - close - 2 <= DocText.maxLinkLength
            else { return nil }
            // A web address never holds a real backslash, so here it only ever marks a bracket.
            let address = String(characters[(close + 2)..<end]).replacingOccurrences(of: "\\", with: "")
            guard let url = URL(string: address), DocText.isOpenable(url) else { return nil }
            return (close, end, url)
        }

        private mutating func closingBracket() -> Int? {
            while nextBracket < brackets.count, brackets[nextBracket] <= index { nextBracket += 1 }
            return nextBracket < brackets.count ? brackets[nextBracket] : nil
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

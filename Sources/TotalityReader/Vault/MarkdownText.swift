import Foundation

/// A doc written in the writing editor is Pandoc-flavoured Markdown, stored exactly as typed. This reads
/// it for Listen, search and the outline, and writes it from the older docs once, when they first open
/// in the new editor. It never renders HTML: that's the editor's job on screen and the exporter's later.
public enum MarkdownText {
    /// RFC 7763 names Pandoc's flavour, so the mime alone says which rules the text follows.
    public static let mime = "text/markdown; variant=pandoc"

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case item(String)
        case code(String)
    }

    // MARK: Reading

    /// Blocks in order. Soft line breaks inside a paragraph become spaces, as they do when printed.
    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var fence: String?
        var code: [String] = []

        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(inline(paragraph.joined(separator: " ")))) }
            paragraph = []
        }

        let all = lines(markdown)
        let labels = labelText(all)
        // Front matter holds settings like the citation style, not words to read.
        var skip = 0
        if all.first == "---", let close = all.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) { skip = close + 1 }
        for raw in all.dropFirst(skip) {
            let line = withReferences(raw.trimmingCharacters(in: .whitespaces), labels: labels)
            if let open = fence {
                if line.hasPrefix(open) {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                    fence = nil
                } else {
                    code.append(raw)
                }
                continue
            }
            // Each pattern below needs a particular first character, so a cheap look at it skips the
            // regexes, which are slow on long lines, for the plain paragraphs that make up most docs.
            let first = line.first
            if first == "`" || first == "~", let marker = line.firstMatch(of: /^(`{3,}|~{3,})/) {
                endParagraph()
                fence = String(marker.1)
                continue
            }
            if line.isEmpty {
                endParagraph()
                continue
            }
            if first == "#", let heading = line.firstMatch(of: /^(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/) {
                endParagraph()
                blocks.append(.heading(level: heading.1.count, text: inline(String(heading.2))))
                continue
            }
            if first == "-" || first == "*" || first == "_", line.wholeMatch(of: /([-*_])(?:[ \t]*\1){2,}/) != nil {
                endParagraph()
                continue
            }
            // A table's divider row says nothing aloud. Its cells read as a list of words.
            if line.contains("-"), line.allSatisfy(dividerCharacters.contains),
               line.wholeMatch(of: /\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?/) != nil {
                continue
            }
            var content = line
            while content.hasPrefix(">") {
                content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let lead = content.first, lead == "-" || lead == "*" || lead == "+" || lead.isNumber,
               let item = content.firstMatch(of: /^(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?/) {
                endParagraph()
                blocks.append(.item(inline(String(content[item.range.upperBound...]))))
                continue
            }
            if content.hasPrefix("[^"), let note = content.firstMatch(of: /^\[\^[^\]]+\]:[ \t]*/) {
                endParagraph()
                content = String(content[note.range.upperBound...])
            }
            if content.hasPrefix("|") {
                content = content.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            paragraph.append(content)
        }
        endParagraph()
        if fence != nil, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    /// The only characters a table's divider row can hold.
    private static let dividerCharacters: Set<Character> = ["|", ":", "-", " ", "\t"]

    /// How each cross-reference label reads aloud: a section by its heading, a figure or table by number.
    static func labelText(_ lines: [String]) -> [String: String] {
        var found: [String: String] = [:]
        var counts = ["fig": 0, "tbl": 0]
        var fence = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") { fence.toggle() }
            guard !fence, line.contains("{#"), let match = line.firstMatch(of: /\{#((sec|fig|tbl):[\w:.\-]+)[^}]*\}/) else { continue }
            let id = String(match.1)
            guard found[id] == nil else { continue }
            switch match.2 {
            case "sec":
                let heading = line.replacing(/\s*\{#[^}]*\}/, with: "").replacing(/^#{1,6}\s+/, with: "")
                found[id] = inline(heading)
            case "fig":
                counts["fig", default: 0] += 1
                found[id] = "Figure \(counts["fig"] ?? 0)"
            default:
                counts["tbl", default: 0] += 1
                found[id] = "Table \(counts["tbl"] ?? 0)"
            }
        }
        return found
    }

    /// Labels go, bracketed citations go, and cross-references read as what they point at. A narrative
    /// citation keeps its key, without the `@`.
    static func withReferences(_ line: String, labels: [String: String]) -> String {
        // Most lines have neither, and Swift's regexes are slow enough on long lines to matter for search.
        guard line.contains("@") || line.contains("{#") else { return line }
        return line
            .replacing(/\s*\{#[\w:.\-]+[^}\n]*\}/, with: "")
            .replacing(/\[[^\[\]\n]*?-?@[\w][^\[\]\n]*\](?![(\[])/) { match in
                let keys = String(match.0).matches(of: /@((?:sec|fig|tbl):[\w:.\-]*\w)/).map { labels[String($0.1)] ?? String($0.1) }
                return keys.isEmpty ? "" : keys.joined(separator: ", ")
            }
            .replacing(/(^|[^\w@])@((?:sec|fig|tbl):[\w:.\-]*\w)/) { match in
                String(match.1) + (labels[String(match.2)] ?? String(match.2))
            }
            .replacing(/(^|[\s(])@(\w[\w:.#$%&\-+?<>~\/]*\w|\w)/) { match in String(match.1) + String(match.2) }
            .replacing(/\ +([.,;:])/) { String($0.1) }
    }

    /// What Listen speaks and search looks through: the words without the symbols, a block per line.
    public static func plainText(_ markdown: String) -> String {
        blocks(markdown).map { block in
            switch block {
            case .heading(_, let text), .paragraph(let text), .item(let text), .code(let text): text
            }
        }
        .joined(separator: "\n")
    }

    public static func headings(_ markdown: String) -> [(level: Int, text: String)] {
        blocks(markdown).compactMap { block in
            if case .heading(let level, let text) = block { return (level, text) }
            return nil
        }
    }

    /// Escaped characters are swapped for private-use stand-ins first, so nothing after can mistake
    /// them for symbols, and swapped back at the end.
    static func inline(_ text: String) -> String {
        var escapes: [Character] = []
        var protected = text
        // Most paragraphs escape nothing, and keep their text as it is.
        if text.contains("\\") {
            protected = ""
            var iterator = Array(text).makeIterator()
            while let character = iterator.next() {
                if character == "\\", let next = iterator.next() {
                    if next.isASCII, next.isPunctuation || next.isSymbol {
                        protected.append(Character(Unicode.Scalar(UInt32(0xF0000 + escapes.count))!))
                        escapes.append(next)
                    } else {
                        protected.append(character)
                        protected.append(next)
                    }
                } else {
                    protected.append(character)
                }
            }
        }
        // A link to another doc reads as its words, or the title it names.
        if protected.contains("[[") { protected = WikiLinks.readable(protected) }
        // Each pass needs its own symbol, and most paragraphs have none, so a quick look skips the regex.
        var result = protected
        if result.contains("[") {
            if result.contains("![") { result = result.replacing(/!\[([^\]]*)\]\([^)]*\)/) { String($0.1) } }
            if result.contains("[^") { result = result.replacing(/\[\^[^\]]+\]/, with: "") }
            result = result
                .replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.1) }
                .replacing(/\[([^\]]+)\]\[[^\]]*\]/) { String($0.1) }
        }
        if result.contains("<") { result = result.replacing(/<((?:https?|mailto):[^>\s]+)>/) { String($0.1) } }
        if result.contains("`") { result = result.replacing(/`+([^`]+)`+/) { String($0.1) } }
        if result.contains("*") || result.contains("~~") { result = result.replacing(/\*+|~~/, with: "") }
        if result.contains("_") { result = withoutEmphasisUnderscores(result) }
        if !escapes.isEmpty {
            var restored = String.UnicodeScalarView()
            for scalar in result.unicodeScalars {
                let index = Int(scalar.value) - 0xF0000
                if index >= 0 && index < escapes.count {
                    restored.append(contentsOf: escapes[index].unicodeScalars)
                } else {
                    restored.append(scalar)
                }
            }
            result = String(restored)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// `_` marks emphasis only at the edge of a word, so `snake_case` keeps its underscore.
    private static func withoutEmphasisUnderscores(_ text: String) -> String {
        let characters = Array(text)
        let isWord = { (c: Character) in c.isLetter || c.isNumber }
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "_" else {
                result.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end] == "_" { end += 1 }
            let inside = index > 0 && end < characters.count && isWord(characters[index - 1]) && isWord(characters[end])
            if inside { result += String(characters[index..<end]) }
            index = end
        }
        return result
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    // MARK: Converting older docs

    /// An older doc, as the new editor's Markdown. Each old line was a paragraph, so paragraphs are now
    /// split by a blank line, while neighbouring list items stay one list. Empty lines were only space,
    /// and Markdown keeps space between paragraphs anyway.
    public static func markdown(from doc: DocText) -> String {
        var parts: [String] = []
        var previous: DocText.Style?
        var number = 0
        for paragraph in doc.paragraphs {
            let words = paragraph.runs.map(run).joined()
            guard !words.trimmingCharacters(in: .whitespaces).isEmpty else {
                previous = nil
                number = 0
                continue
            }
            number = paragraph.style == .numbered ? number + 1 : 0
            let line: String
            switch paragraph.style {
            case .body: line = escapingStart(words)
            case .heading1: line = "# " + words.trimmingCharacters(in: .whitespaces)
            case .heading2: line = "## " + words.trimmingCharacters(in: .whitespaces)
            case .bullet: line = "- " + words.trimmingCharacters(in: .whitespaces)
            case .numbered: line = "\(number). " + words.trimmingCharacters(in: .whitespaces)
            }
            if !parts.isEmpty {
                parts.append(previous == paragraph.style && paragraph.style.isList ? "\n" : "\n\n")
            }
            parts.append(line)
            previous = paragraph.style
        }
        return parts.joined()
    }

    /// The characters that mean something inside a Pandoc paragraph: emphasis, code, links and notes,
    /// raw HTML, sub- and superscript, maths, and citations.
    private static let inlineSpecials: Set<Character> = ["\\", "*", "_", "`", "[", "]", "<", ">", "~", "^", "$"]

    static func escaped(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if inlineSpecials.contains(character) {
                result.append("\\")
            } else if character == "@", previous.map({ !($0.isLetter || $0.isNumber) }) ?? true {
                // `@name` would be read as a citation. An email address has a letter before its `@`.
                result.append("\\")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func run(_ run: DocText.Run) -> String {
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
            let address = link.absoluteString
                .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                .replacingOccurrences(of: " ", with: "%20")
            text = "[\(text)](\(address))"
        }
        return leading + text + trailing
    }

    /// A paragraph that happens to start like a heading, a list, a quote or a table stays a paragraph.
    /// Leading spaces would make a code block, so they become spaces that don't count.
    private static func escapingStart(_ text: String) -> String {
        let indent = text.prefix { $0 == " " || $0 == "\t" }
        var rest = String(text.dropFirst(indent.count))
        while rest.last == " " || rest.last == "\t" { rest.removeLast() }
        let kept = String(repeating: "\u{00A0}", count: indent.count)
        if let first = rest.first, "#-+=|:%".contains(first) { return kept + "\\" + rest }
        if let number = rest.firstMatch(of: /^\d{1,9}(?=[.)](?:[ \t]|$))/) {
            return kept + rest[..<number.range.upperBound] + "\\" + rest[number.range.upperBound...]
        }
        return kept + rest
    }
}

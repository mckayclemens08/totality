import Foundation

/// A book or Word file as text to read: sections holding headings and paragraphs. Images aren't kept.
public struct ReadableDocument: Sendable, Equatable {
    public struct Block: Sendable, Equatable {
        public var text: String
        public var isHeading = false
    }

    public struct Section: Sendable, Equatable {
        public var blocks: [Block]

        /// The first heading, which is what a chapter list shows.
        public var title: String? {
            blocks.first(where: \.isHeading)?.text
        }
    }

    public var sections: [Section]

    public var plainText: String {
        sections.flatMap(\.blocks).map(\.text).joined(separator: "\n")
    }
}

/// Parses XML that came from outside the app. Everything reaches the parser as plain UTF-8 with no
/// declaration and no doctype, because that's where encoding and entity tricks live, and nothing here
/// ever fetches anything.
enum SafeXML {
    /// More text than this isn't a book, so it stops rather than filling memory.
    static let maxCharacters = 32 * 1024 * 1024
    static let maxTitleLength = 300

    private static let namedEntities = [
        "&nbsp;": "\u{00A0}", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}",
        "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        "&copy;": "\u{00A9}", "&reg;": "\u{00AE}", "&trade;": "\u{2122}", "&eacute;": "\u{00E9}",
    ]

    /// UTF-16 has to become text before anything can look for a doctype in it.
    private static func decoded(_ data: Data) -> String {
        let start = Array(data.prefix(2))
        switch start {
        case [0xFF, 0xFE], [0x3C, 0]:
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        case [0xFE, 0xFF], [0, 0x3C]:
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        default:
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func withoutDeclaration(_ text: String) -> String {
        let trimmed = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        guard trimmed.hasPrefix("<?xml"), let end = trimmed.range(of: "?>") else { return String(trimmed) }
        return String(trimmed[end.upperBound...])
    }

    /// One pass that never looks back, so a hostile file costs no more than its length. A doctype
    /// becomes a space, so what's left on either side of it can't join up into a new one.
    static func withoutDoctypes(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let marker = Array("<!doctype".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let isMarker = bytes[index] == marker[0] && index + marker.count <= bytes.count
                && zip(bytes[index...], marker).allSatisfy { ($0 | 0x20) == ($1 | 0x20) }
            if isMarker {
                index = doctypeEnd(in: bytes, from: index + marker.count)
                output.append(0x20)
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Past the closing `>`, ignoring any inside quotes or the `[ ]` section. One that never closes
    /// takes the rest of the file with it, which only ever removes text.
    private static func doctypeEnd(in bytes: [UInt8], from start: Int) -> Int {
        var quote: UInt8?
        var depth = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "]") {
                depth = max(0, depth - 1)
            } else if byte == UInt8(ascii: ">"), depth == 0 {
                return index
            }
        }
        return bytes.count
    }

    static func parse(_ data: Data, with delegate: XMLParserDelegate) {
        var text = withoutDoctypes(withoutDeclaration(decoded(data))).replacingOccurrences(of: "\0", with: "")
        if text.contains("&") {
            for (name, value) in namedEntities { text = text.replacingOccurrences(of: name, with: value) }
        }
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        // A failure partway keeps what was read, because a half-readable chapter beats none.
        _ = parser.parse()
    }

    static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }
}

/// Collects readable text from a chapter of XHTML.
private final class ChapterParser: NSObject, XMLParserDelegate {
    private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote", "br", "tr", "section", "article", "pre", "ul", "ol", "table", "hr",
    ]
    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let skippedTags: Set<String> = ["head", "script", "style", "svg", "template", "nav"]

    private(set) var blocks: [ReadableDocument.Block] = []
    private var current = ""
    private var skipDepth = 0
    private var headingDepth = 0
    private var total = 0

    private func flush() {
        let text = current.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !text.isEmpty { blocks.append(.init(text: text, isHeading: headingDepth > 0)) }
        current = ""
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let tag = SafeXML.localName(name)
        if Self.skippedTags.contains(tag) { skipDepth += 1 }
        if Self.blockTags.contains(tag) { flush() }
        if Self.headingTags.contains(tag) {
            flush()
            headingDepth += 1
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let tag = SafeXML.localName(name)
        if Self.skippedTags.contains(tag) { skipDepth = max(0, skipDepth - 1) }
        if Self.blockTags.contains(tag) { flush() }
        if Self.headingTags.contains(tag) {
            flush()
            headingDepth = max(0, headingDepth - 1)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        total += string.utf16.count
        guard total <= SafeXML.maxCharacters else {
            parser.abortParsing()
            return
        }
        current += string
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        flush()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        flush()
    }
}

/// Reads an EPUB's package file: its title, and the order its chapters come in.
private final class PackageParser: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var manifest: [String: (href: String, type: String)] = [:]
    private(set) var spine: [String] = []
    private var inTitle = false
    private var titleText = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch SafeXML.localName(name) {
        case "title" where title == nil:
            inTitle = true
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = (href, attributes["media-type"] ?? "")
            }
        case "itemref":
            if let id = attributes["idref"] { spine.append(id) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if SafeXML.localName(name) == "title", inTitle {
            inTitle = false
            let text = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            title = text.isEmpty ? nil : String(text.prefix(SafeXML.maxTitleLength))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { titleText += string }
    }
}

private final class ContainerParser: NSObject, XMLParserDelegate {
    private(set) var packagePath: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if SafeXML.localName(name) == "rootfile", packagePath == nil { packagePath = attributes["full-path"] }
    }
}

/// Reads the words out of a Word file's main part.
private final class WordParser: NSObject, XMLParserDelegate {
    private(set) var blocks: [ReadableDocument.Block] = []
    private var current = ""
    private var inText = false
    private var isHeading = false
    private var total = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch SafeXML.localName(name) {
        case "p":
            current = ""
            isHeading = false
        case "pstyle":
            let style = (attributes["w:val"] ?? "").lowercased()
            isHeading = style.hasPrefix("heading") || style == "title"
        case "t":
            inText = true
        case "tab", "br":
            current += " "
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch SafeXML.localName(name) {
        case "p":
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.init(text: text, isHeading: isHeading)) }
            current = ""
        case "t":
            inText = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        total += string.utf16.count
        guard total <= SafeXML.maxCharacters else {
            parser.abortParsing()
            return
        }
        current += string
    }
}

enum BookReader {
    static func epub(_ data: Data) throws -> (title: String?, document: ReadableDocument) {
        var archive = try ZipArchive(data)
        guard let containerData = try archive.read("META-INF/container.xml") else { throw ReaderError.notReadable }
        let container = ContainerParser()
        SafeXML.parse(containerData, with: container)
        guard let packagePath = container.packagePath, let packageData = try archive.read(packagePath) else {
            throw ReaderError.notReadable
        }
        let package = PackageParser()
        SafeXML.parse(packageData, with: package)
        var sections: [ReadableDocument.Section] = []
        var seen = Set<String>()
        for id in package.spine {
            guard let entry = package.manifest[id], entry.type.contains("html") else { continue }
            let path = resolve(entry.href, from: packagePath)
            guard seen.insert(path).inserted, let chapter = try archive.read(path) else { continue }
            let parser = ChapterParser()
            SafeXML.parse(chapter, with: parser)
            if !parser.blocks.isEmpty { sections.append(.init(blocks: parser.blocks)) }
        }
        guard !sections.isEmpty else { throw ReaderError.notReadable }
        return (package.title, ReadableDocument(sections: sections))
    }

    static func word(_ data: Data) throws -> ReadableDocument {
        var archive = try ZipArchive(data)
        guard let part = try archive.read("word/document.xml") else { throw ReaderError.notReadable }
        let parser = WordParser()
        SafeXML.parse(part, with: parser)
        guard !parser.blocks.isEmpty else { throw ReaderError.notReadable }
        return ReadableDocument(sections: [.init(blocks: parser.blocks)])
    }

    /// A chapter's name is relative to the package file. This only ever looks up a name in the
    /// archive, so a path like `../../x` finds nothing rather than reaching anywhere.
    static func resolve(_ href: String, from packagePath: String) -> String {
        let clean = (href.split(separator: "#").first.map(String.init) ?? href)
        let decoded = clean.removingPercentEncoding ?? clean
        var parts = packagePath.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/") {
            if part == ".." {
                _ = parts.popLast()
            } else if part != "." {
                parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }
}

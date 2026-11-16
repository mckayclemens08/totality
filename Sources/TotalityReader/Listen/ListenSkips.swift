import Foundation
import PDFKit

/// What Listen leaves out, as places in the text it reads. A PDF's running heads, running feet and page
/// numbers are never read: they're the same few words at the top or foot of page after page. Headings
/// are left out too unless the person turns on Read headings, so a book doesn't start every chapter, or a
/// PDF every page, with its title. Nothing is removed from the text, so every offset stays the same.
enum ListenSkips {
    static let readHeadingsKey = "reader.listen.readHeadings"

    /// Everything to skip in an item's text. `file` is the file, read a page or a part at a time, and
    /// `mime` says what kind it is.
    static func ranges(text: String, file: any ByteSource, mime: String?, readHeadings: Bool) -> [Range<Int>] {
        if mime == "application/pdf" {
            guard let pdf = PDFSource.open(file), !pdf.isLocked else { return [] }
            let pages = pdf.pages
            let map = PDFPageMap(whole: text, pages: pages)
            var found = furniture(pages: pages, map: map)
            // A PDF too big to hold whole has no chapter list read, only its running heads and feet.
            if !readHeadings, let document = pdf.document { found += outlineHeadings(document, pages: pages, map: map) }
            return merged(found)
        }
        guard !readHeadings else { return [] }
        let titles: [String]
        if mime == MarkdownText.mime {
            let data = (try? ReadableText.whole(file)) ?? Data()
            titles = MarkdownText.headings(String(decoding: data, as: UTF8.self)).map(\.text).map(MarkdownText.plainText)
        } else if let document = try? ReadableText.document(file, mime: mime) {
            titles = document.sections.flatMap(\.blocks).filter(\.isHeading).map(\.text)
        } else {
            titles = []
        }
        return headings(in: text, titles: titles)
    }

    /// The lines of `text` that are one of `titles`, each title used as many times as it's listed.
    static func headings(in text: String, titles: [String]) -> [Range<Int>] {
        var wanted: [String: Int] = [:]
        for title in titles {
            let key = normalized(title)
            if !key.isEmpty { wanted[key, default: 0] += 1 }
        }
        guard !wanted.isEmpty else { return [] }
        var found: [Range<Int>] = []
        for line in lines(text) {
            let key = normalized(line.text)
            guard let left = wanted[key], left > 0 else { continue }
            wanted[key] = left - 1
            found.append(line.range)
        }
        return found
    }

    // MARK: PDF pages

    /// How far into a page a running head can be, and how far from its foot a running foot.
    private static let edgeLines = 2

    /// Lines at the top or foot of a page that repeat, give or take their numbers, across a good share of
    /// the pages, and any line there that's only a page number.
    static func furniture(pages: [String], map: PDFPageMap) -> [Range<Int>] {
        struct Edge {
            let key: String
            let range: Range<Int>
            let isNumber: Bool
        }
        var edges: [[Edge]] = []
        var counts: [String: Int] = [:]
        for page in map.pages where pages.indices.contains(page.index) {
            let all = lines(pages[page.index]).filter { !$0.text.allSatisfy(\.isWhitespace) }
            let picked = Array(all.prefix(edgeLines)) + Array(all.dropFirst(edgeLines).suffix(edgeLines))
            let here = picked.map { line in
                Edge(
                    key: shape(line.text),
                    range: (page.start + line.range.lowerBound)..<(page.start + line.range.upperBound),
                    isNumber: isPageNumber(line.text)
                )
            }
            for key in Set(here.map(\.key)) { counts[key, default: 0] += 1 }
            edges.append(here)
        }
        let enough = max(3, Int((Double(map.pages.count) * 0.3).rounded(.up)))
        return edges.flatMap { $0 }.filter { edge in
            edge.isNumber || (map.pages.count >= 3 && (counts[edge.key] ?? 0) >= enough)
        }
        .map(\.range)
    }

    /// A PDF's own chapter list names its headings, and each one's page. The line on that page that
    /// reads the same is the heading.
    static func outlineHeadings(_ document: PDFDocument, pages: [String], map: PDFPageMap) -> [Range<Int>] {
        var found: [Range<Int>] = []
        func visit(_ outline: PDFOutline, depth: Int) {
            guard depth < 8 else { return }
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                if let label = child.label, let page = child.destination?.page {
                    let number = document.index(for: page)
                    if let place = map.pages.first(where: { $0.index == number }), pages.indices.contains(number) {
                        let wanted = normalized(label)
                        if let line = lines(pages[number]).prefix(8).first(where: { normalized($0.text) == wanted && !wanted.isEmpty }) {
                            found.append((place.start + line.range.lowerBound)..<(place.start + line.range.upperBound))
                        }
                    }
                }
                visit(child, depth: depth + 1)
            }
        }
        if let root = document.outlineRoot { visit(root, depth: 0) }
        return found
    }

    /// "12", "Page 12", "12 of 300", "- 12 -", "xii".
    static func isPageNumber(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return false }
        if trimmed.wholeMatch(of: /(page\s*)?[-–—\s]*\d{1,4}[-–—\s]*((of|\/)\s*\d{1,4})?/) != nil { return true }
        // Only a well-formed numeral, so a lone word like "civil" isn't taken for one.
        return trimmed.wholeMatch(of: /c{0,3}(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})/) != nil
    }

    // MARK: Lines

    /// Each line of `text`, without its line break, with where it sits in UTF-16 units.
    static func lines(_ text: String) -> [(text: String, range: Range<Int>)] {
        var found: [(String, Range<Int>)] = []
        let words = text as NSString
        words.enumerateSubstrings(in: NSRange(location: 0, length: words.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            found.append((words.substring(with: range), range.location..<(range.location + range.length)))
        }
        return found
    }

    /// Spaces collapsed and case ignored, for comparing a heading with a line.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The line with its numbers made alike, so "Chapter 3 · 47" and "Chapter 3 · 48" count as one.
    private static func shape(_ text: String) -> String {
        String(normalized(text).map { $0.isNumber ? "#" : $0 })
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

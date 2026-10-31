import Foundation
import Testing
@testable import TotalityReader

@Suite struct DocTextTests {
    private typealias Run = DocText.Run
    private typealias Paragraph = DocText.Paragraph

    private let trip = DocText(paragraphs: [
        Paragraph(.heading1, runs: [Run("Red Rock trip")]),
        Paragraph(runs: [Run("Leave "), Run("Friday", bold: true), Run(", back "), Run("Sunday", italic: true), Run(".")]),
        Paragraph(.heading2, runs: [Run("Packing")]),
        Paragraph(.bullet, runs: [Run("Rope")]),
        Paragraph(.bullet, runs: [Run("Rack", bold: true, italic: true)]),
        Paragraph(.numbered, runs: [Run("Book the campsite")]),
        Paragraph(.numbered, runs: [Run("Check the "), Run("forecast", link: URL(string: "https://www.weather.gov/"))]),
        Paragraph(),
        Paragraph(runs: [Run("Done.")]),
    ])

    @Test("Everything survives being written and read back")
    func roundTrip() {
        #expect(DocText(markdown: trip.markdown) == trip)
    }

    @Test("The file is plain Markdown a person could read")
    func readableFile() {
        #expect(trip.markdown.components(separatedBy: "\n") == [
            "# Red Rock trip",
            "Leave **Friday**, back *Sunday*.",
            "## Packing",
            "- Rope",
            "- ***Rack***",
            "1. Book the campsite",
            "2. Check the [forecast](https://www.weather.gov/)",
            "",
            "Done.",
        ])
    }

    @Test("Listen and search get the words and none of the markup")
    func plainText() {
        #expect(trip.plainText.hasPrefix("Red Rock trip\nLeave Friday, back Sunday.\nPacking\nRope\nRack\n"))
    }

    @Test("Text that looks like markup stays text", arguments: [
        "# not a heading", "#hashtag", "- not a list", "1. not a list", "12. still not", "**stars**", "*one*",
        "a * b * c", "[not](a link)", "[not](https://a.link/)", "back\\slash", "\\*", "]", "[", "***", "1.", "-", "#",
    ])
    func literalText(_ text: String) {
        let doc = DocText(paragraphs: [Paragraph(runs: [Run(text)])])
        #expect(DocText(markdown: doc.markdown) == doc, "\(doc.markdown)")
    }

    @Test("Spaces at the edge of bold text survive")
    func spacesAtEdges() {
        let doc = DocText(paragraphs: [Paragraph(runs: [Run("a"), Run(" bold ", bold: true), Run("b")])])
        #expect(doc.markdown == "a **bold** b")
        #expect(DocText(markdown: doc.markdown).plainText == "a bold b")
    }

    @Test("A run of only spaces doesn't make stray markers")
    func spacesOnly() {
        let doc = DocText(paragraphs: [Paragraph(runs: [Run("a"), Run("  ", bold: true), Run("b")])])
        #expect(doc.markdown == "a  b")
    }

    @Test("Bold and italic can overlap and links can hold them")
    func nesting() {
        let parsed = DocText(markdown: "**bold *both* bold** [**strong link**](https://a.example/)")
        #expect(parsed.paragraphs[0].runs == [
            Run("bold ", bold: true), Run("both", bold: true, italic: true), Run(" bold", bold: true), Run(" "),
            Run("strong link", bold: true, link: URL(string: "https://a.example/")),
        ])
    }

    @Test("A lone star in an imported file is just a star")
    func loneStars() {
        #expect(DocText(markdown: "2 * 3 = 6").plainText == "2 * 3 = 6")
        #expect(DocText(markdown: "2 * 3 = 6").paragraphs[0].runs == [Run("2 * 3 = 6")])
    }

    @Test("Only web and mail links count", arguments: ["javascript:alert(1)", "file:///etc/passwd", "totality://open", "ftp://x.example/"])
    func unsafeLinks(_ address: String) {
        let parsed = DocText(markdown: "[press me](\(address))")
        #expect(parsed.paragraphs[0].runs.allSatisfy { $0.link == nil })
    }

    @Test("Safe links open", arguments: ["https://a.example/", "http://a.example/", "mailto:a@example.com", "HTTPS://A.EXAMPLE/"])
    func safeLinks(_ address: String) {
        let parsed = DocText(markdown: "[press me](\(address))")
        #expect(parsed.paragraphs[0].runs.first?.link != nil)
    }

    @Test("Old notes read as they were written")
    func plainNotes() {
        let doc = DocText(plain: "# literally\n**this**\n- too")
        #expect(doc.paragraphs.allSatisfy { $0.style == .body })
        #expect(doc.plainText == "# literally\n**this**\n- too")
    }

    @Test("Empty text is one empty paragraph, and Windows line endings don't show")
    func edges() {
        #expect(DocText(markdown: "").paragraphs == [Paragraph()])
        #expect(DocText(markdown: "one\r\ntwo").plainText == "one\ntwo")
        #expect(DocText(paragraphs: []).paragraphs == [Paragraph()])
    }

    @Test("Numbers restart after anything that isn't a numbered line")
    func numbering() {
        let doc = DocText(paragraphs: [
            Paragraph(.numbered, runs: [Run("a")]), Paragraph(.numbered, runs: [Run("b")]),
            Paragraph(runs: [Run("break")]), Paragraph(.numbered, runs: [Run("c")]),
        ])
        #expect(doc.markdown == "1. a\n2. b\nbreak\n1. c")
    }

    @Test("Any whitespace at the edge of styled text survives", arguments: ["\tfoo", "\u{00A0}foo", "\u{3000}foo", "foo\t", " \tfoo\u{00A0} "])
    func edgeWhitespace(_ text: String) {
        let doc = DocText(paragraphs: [Paragraph(runs: [Run("a"), Run(text, bold: true), Run("b")])])
        #expect(DocText(markdown: doc.markdown).plainText == "a\(text)b")
    }

    @Test("Styles can run straight into each other", arguments: [
        [Run("bold", bold: true), Run("ital", italic: true)],
        [Run("ital", italic: true), Run("bold", bold: true)],
        [Run("both", bold: true, italic: true), Run("bold", bold: true)],
        [Run("both", bold: true, italic: true), Run("ital", italic: true)],
        [Run("bold", bold: true), Run("both", bold: true, italic: true)],
        [Run("ital", italic: true), Run("both", bold: true, italic: true)],
        [Run("plain"), Run("both", bold: true, italic: true), Run("plain again")],
    ])
    func adjacentStyles(_ runs: [DocText.Run]) {
        let doc = DocText(paragraphs: [Paragraph(runs: runs)])
        #expect(DocText(markdown: doc.markdown) == doc)
    }

    @Test("A link's address can hold brackets", arguments: [
        "https://en.wikipedia.org/wiki/Mercury_(planet)", "https://a.example/x)y", "https://a.example/x(y",
    ])
    func bracketsInLinks(_ address: String) throws {
        let url = try #require(URL(string: address))
        let doc = DocText(paragraphs: [Paragraph(runs: [Run("Map", link: url), Run(" and more")])])
        #expect(DocText(markdown: doc.markdown) == doc)
    }

    @Test("Hostile lines stay quick", arguments: [
        String(repeating: "[a](", count: 40_000), String(repeating: "[", count: 200_000),
        String(repeating: "[a](http:", count: 20_000) + String(repeating: ")", count: 20_000), String(repeating: "*", count: 200_000),
        String(repeating: "* ", count: 100_000),
    ])
    func hostileLines(_ line: String) {
        let start = Date()
        _ = DocText(markdown: line)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("Splitting keeps formatting on both sides, even in the middle of a word or an emoji neighbour")
    func splitting() {
        var doc = DocText(paragraphs: [Paragraph(.bullet, runs: [Run("🧗 clim", bold: true), Run("bing")])])
        doc.split(paragraph: 0, at: 5, into: .bullet)
        #expect(doc.paragraphs[0].runs == [Run("🧗 cl", bold: true)])
        #expect(doc.paragraphs[1].runs == [Run("im", bold: true), Run("bing")])
        #expect(doc.paragraphs[1].style == .bullet)
    }

    @Test("Splitting at the ends leaves an empty paragraph, not a lost one")
    func splittingAtEnds() {
        var doc = DocText(paragraphs: [Paragraph(.heading1, runs: [Run("Title")])])
        doc.split(paragraph: 0, at: 5, into: .body)
        #expect(doc.paragraphs == [Paragraph(.heading1, runs: [Run("Title")]), Paragraph()])
        doc.split(paragraph: 0, at: 0, into: .body)
        #expect(doc.paragraphs[0].text.isEmpty)
        #expect(doc.paragraphs[1].text == "Title")
        #expect(doc.paragraphs.count == 3)
    }

    @Test("A doc saves with its formatting and reads back, and a plain note still opens")
    func vaultRoundTrip() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Trip")
        try await vault.saveNote(note.id, title: "Trip", body: "# plain")
        #expect(try await vault.doc(note.id).paragraphs[0].style == .body)
        try await vault.saveNote(note.id, title: "Trip", body: trip.markdown, mime: "text/markdown")
        #expect(try await vault.doc(note.id) == trip)
        #expect(try await vault.text(of: note.id).contains("**") == false)
        #expect(try await vault.search("forecast").count == 1)
        #expect(try await vault.search("https").isEmpty)
    }

    @Test("A kept copy keeps its formatting")
    func keptCopies() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Trip")
        try await vault.delete(note.id)
        let result = try await vault.saveNote(note.id, title: "Trip", body: trip.markdown, mime: "text/markdown", basedOn: note.updatedAt)
        guard case .keptAsCopy(let copy) = result else {
            Issue.record("Expected a copy")
            return
        }
        #expect(try await vault.doc(copy.id) == trip)
    }
}

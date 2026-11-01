import Foundation
import Testing
@testable import TotalityReader

@Suite struct ReadAlongPageTests {
    private let text = "# Lisbon\n\nTake the tram. Walk back.\n\nStop for coffee."

    private func page(_ text: String, headings: Set<String> = []) -> ReadAlongPage {
        ReadAlongPage(text: text, headings: headings)
    }

    @Test("Empty lines leave the page but stay in the count, so places still match Listen's")
    func offsets() {
        let found = page("One here.\n\n\nTwo here.\n   \nThree here.")
        #expect(found.paragraphs.map(\.text) == ["One here.", "Two here.", "Three here."])
        #expect(found.paragraphs.map(\.offset) == [0, 12, 26])
        for (paragraph, sentence) in zip(found.paragraphs, found.script.sentences) {
            #expect(paragraph.offset == sentence.offset)
        }
    }

    @Test("A heading is marked by its text, and only a heading can be gone to")
    func headings() {
        let found = page("The river\nThe river runs on.\nThe river", headings: ["The river"])
        #expect(found.paragraphs.map(\.isHeading) == [true, false, true])
        #expect(found.paragraph(titled: "The river")?.id == 0)
        #expect(found.paragraph(titled: "The river runs on.") == nil)
    }

    @Test("A place is found in the paragraph that holds it")
    func holding() {
        let found = page("One here.\n\nTwo here.")
        #expect(found.paragraph(holding: 4)?.text == "One here.")
        #expect(found.paragraph(holding: 11)?.text == "Two here.")
    }

    @Test("Each sentence is its own tappable stretch, and all the text is kept")
    func pieces() {
        let found = page("Take the tram. Walk back.")
        let pieces = found.pieces(of: found.paragraphs[0], highlight: nil)
        #expect(pieces.map(\.text).joined() == "Take the tram. Walk back.")
        #expect(pieces.compactMap(\.sentence) == [0, 1])
        #expect(pieces.allSatisfy { $0.mark == .none })
    }

    @Test("The sentence and word are marked, and the word wins where they overlap")
    func marks() throws {
        let found = page("Take the tram. Walk back.")
        let highlight = try #require(found.script.highlight(sentence: 0, spoken: 5))
        let pieces = found.pieces(of: found.paragraphs[0], highlight: highlight)
        #expect(pieces.filter { $0.mark == .word }.map(\.text) == ["the"])
        #expect(pieces.filter { $0.mark == .sentence }.map(\.text) == ["Take ", " tram."])
        #expect(pieces.filter { $0.mark == .none }.map(\.text).joined().contains("Walk back."))
        #expect(pieces.map(\.text).joined() == "Take the tram. Walk back.")
    }

    @Test("A sentence running over two paragraphs is marked in both, and tapping either finds it")
    func acrossParagraphs() throws {
        let text = "We walked for hours along the long bank of the river\nand came at last to the old town."
        let found = page(text)
        #expect(found.script.sentences.count == 1)
        #expect(found.paragraphs.count == 2)
        let highlight = try #require(found.script.highlight(sentence: 0, spoken: 0))
        for paragraph in found.paragraphs {
            #expect(found.touches(paragraph, highlight))
            #expect(found.pieces(of: paragraph, highlight: highlight).allSatisfy { $0.sentence == 0 })
        }
    }

    @Test("Only the paragraph with the highlight is told about it")
    func touches() throws {
        let found = page("One here.\nTwo here.")
        let highlight = try #require(found.script.highlight(sentence: 1, spoken: 0))
        #expect(!found.touches(found.paragraphs[0], highlight))
        #expect(found.touches(found.paragraphs[1], highlight))
        #expect(!found.touches(found.paragraphs[1], nil))
    }

    @Test("A bullet Listen skips can't be tapped, and it stays on the page")
    func notRead() {
        let found = page("• Take the tram.")
        let pieces = found.pieces(of: found.paragraphs[0], highlight: nil)
        #expect(pieces.map(\.text).joined() == "• Take the tram.")
    }

    @Test("Text with nothing to read has no sentences, so the page says so")
    func nothing() {
        #expect(page("  \n ").paragraphs.isEmpty)
        #expect(page("1 2 3").script.sentences.isEmpty)
    }

    @Test("An emoji isn't cut in half")
    func emoji() throws {
        let found = page("Send 🧗 now. Next.")
        let highlight = try #require(found.script.highlight(sentence: 0, spoken: 8))
        let pieces = found.pieces(of: found.paragraphs[0], highlight: highlight)
        #expect(pieces.map(\.text).joined() == "Send 🧗 now. Next.")
        #expect(pieces.first { $0.mark == .word }?.text == "now.")
    }

    @Test("A sentence's link says which sentence, and nothing else counts as one")
    func links() throws {
        let url = try #require(ReadAlongLink.url(forSentence: 42))
        #expect(ReadAlongLink.sentence(in: url) == 42)
        #expect(ReadAlongLink.sentence(in: URL(string: "https://usetotality.com/sentence/42")!) == nil)
        #expect(ReadAlongLink.sentence(in: URL(string: "totality-read-along://sentence/nope")!) == nil)
    }
}

@Suite struct PDFPageMapTests {
    private let map = PDFPageMap(whole: "First page.\nSecond page.\nThird page.", pages: ["First page.", "Second page.", "Third page."])

    @Test("Each page is found in the text, past the one before it")
    func starts() {
        #expect(map.pages.map(\.start) == [0, 12, 25])
        #expect(map.pages.map(\.length) == [11, 12, 11])
    }

    @Test("Two pages with the same text are told apart")
    func repeated() {
        let found = PDFPageMap(whole: "Intro.\nIntro.\nIntro.", pages: ["Intro.", "Intro.", "Intro."])
        #expect(found.pages.map(\.start) == [0, 7, 14])
    }

    @Test("A page with no text is passed over and keeps its number")
    func blank() {
        let found = PDFPageMap(whole: "First.\n\nThird.", pages: ["First.", "", "Third."])
        #expect(found.pages.map(\.index) == [0, 2])
        #expect(found.offset(page: 2, character: 1) == 9)
        #expect(found.offset(page: 1, character: 0) == nil)
    }

    @Test("A page that can't be found doesn't stop the ones after it")
    func missing() {
        let found = PDFPageMap(whole: "First.\nThird.", pages: ["First.", "Lost.", "Third."])
        #expect(found.pages.map(\.index) == [0, 2])
    }

    @Test("A stretch across a page break comes back in two parts, in page terms")
    func acrossPages() {
        let pieces = map.pieces(of: 6..<18)
        #expect(pieces.map(\.page) == [0, 1])
        #expect(pieces.map(\.range) == [NSRange(location: 6, length: 5), NSRange(location: 0, length: 6)])
    }

    @Test("The line break between pages belongs to neither")
    func gap() {
        #expect(map.pieces(of: 11..<12).isEmpty)
    }

    @Test("A tap's place on a page is its place in the text")
    func tap() {
        #expect(map.offset(page: 2, character: 3) == 28)
    }

    @Test("A real PDF lines up with the text Listen reads")
    func realFile() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/founding-brief-v6.pdf"))
        let text = try ReadableText.extract(data, mime: "application/pdf")
        let found = ReadableText.pageMap(data)
        #expect(found.pages.count == 16)
        for page in found.pages {
            #expect(page.start + page.length <= text.utf16.count)
        }
    }

    @Test("A file that isn't a PDF maps to nothing")
    func notAPDF() {
        #expect(ReadableText.pageMap(Data("Not a PDF".utf8)).pages.isEmpty)
    }
}

import Foundation
import PDFKit
import Testing
import TotalityCore
@testable import TotalityReader

/// A spoken sentence, with its spaces made alike, for comparing with the words on the page.
private func plain(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// Every sentence's place in the text holds that sentence's words, so the highlight is on what's said.
private func inStep(_ script: ListenScript, _ text: String) -> Bool {
    let words = text as NSString
    return script.sentences.indices.allSatisfy { index in
        guard let range = script.range(ofSentence: index) else { return false }
        let marked = words.substring(with: NSRange(location: range.lowerBound, length: range.count))
        return plain(marked.replacingOccurrences(of: "-\n", with: "")) == plain(script.sentences[index].text)
            || plain(marked).filter { !$0.isWhitespace } == plain(script.sentences[index].text).filter { !$0.isWhitespace }
    }
}

/// An essay long enough for several pages, laid out as a real PDF with a running head ("Ortiz 2") at the
/// top of each page, by the Reader's own exporter.
private func essayPDF(template: ExportTemplate) throws -> Data {
    var document = ExportDocument()
    document.meta.title = "Why teachers leave rural schools"
    document.meta.author = "Ana Ortiz"
    document.blocks = [.heading(level: 1, runs: [ExportDocument.Run("Why teachers leave")])]
    let districts = ["Alder", "Birch", "Cedar", "Dogwood", "Elm", "Fir", "Gum", "Hazel", "Ivy", "Juniper", "Kapok", "Larch", "Maple", "Nutmeg"]
    for district in districts {
        document.blocks.append(.paragraph([ExportDocument.Run(
            "Teachers who leave name the principal before the salary, in \(district) district as in the rest. In the exit survey, isolation and the drive to town come next, and pay comes fourth. The districts that kept their staff were the ones where teachers were asked before a schedule changed."
        )]))
    }
    return try #require(PDFExporter.pdf(document, template: template, paper: .letter))
}

@Suite struct ListenSkipsTests {
    @Test("A real PDF's running heads and page numbers are never spoken, and the highlight stays on what is")
    func pdfFurniture() throws {
        for template in [ExportTemplate.essay, .doc] {
            let data = try essayPDF(template: template)
            let text = try ReadableText.extract(data, mime: "application/pdf")
            let pages = try #require(PDFDocument(data: data)).pageCount
            #expect(pages >= 3, "\(template)")
            let skips = ListenSkips.ranges(text: text, file: data, mime: "application/pdf", readHeadings: true)
            let script = ListenScript(text: text, skipping: skips)
            for sentence in script.sentences {
                #expect(sentence.text.firstMatch(of: /Ortiz \d/) == nil, "\(template): \(sentence.text)")
                #expect(!ListenSkips.isPageNumber(sentence.text), "\(template): \(sentence.text)")
            }
            // Every page's words are still read.
            #expect(script.sentences.filter { $0.text.hasPrefix("Teachers who leave name the principal") }.count == 14, "\(template)")
            #expect(inStep(script, text), "\(template)")
            // Without the skips, the running heads would have been read.
            let unskipped = ListenScript(text: text)
            #expect(unskipped.sentences.contains { sentence in
                sentence.text.firstMatch(of: /Ortiz \d/) != nil || sentence.text.split(whereSeparator: \.isWhitespace).contains { $0.allSatisfy(\.isNumber) }
            }, "\(template)")
            for sentence in script.sentences {
                #expect(!sentence.text.split(whereSeparator: \.isWhitespace).contains { $0.allSatisfy(\.isNumber) }, "\(template): \(sentence.text)")
            }
        }
    }

    @Test("An EPUB's chapter titles are skipped with a pause when Read headings is off, and read when it's on")
    func epubHeadings() throws {
        let data = GutenbergBook.epub()
        let text = try ReadableText.extract(data, mime: ReadableText.epubMime)
        let off = ListenScript(text: text, skipping: ListenSkips.ranges(text: text, file: data, mime: ReadableText.epubMime, readHeadings: false))
        #expect(!off.sentences.contains { $0.text.contains("CHAPTER") })
        let opening = try #require(off.sentences.first { $0.text.hasPrefix("It is a truth") })
        #expect(opening.pauseBefore)
        let second = try #require(off.sentences.first { $0.text.hasPrefix("Mr. Bennet was among") })
        #expect(second.pauseBefore)
        #expect(off.sentences.filter(\.pauseBefore).count == 2)
        #expect(inStep(off, text))

        let on = ListenScript(text: text, skipping: ListenSkips.ranges(text: text, file: data, mime: ReadableText.epubMime, readHeadings: true))
        #expect(on.sentences.contains { $0.text == "CHAPTER I." })
        #expect(on.sentences.contains { $0.text == "CHAPTER II." })
        #expect(on.sentences.allSatisfy { !$0.pauseBefore })
        #expect(on.fingerprint != off.fingerprint)
        // Skipping leaves every offset where it was.
        #expect(on.length == off.length)
        #expect(off.sentences.first { $0.text.hasPrefix("It is a truth") }?.offset == on.sentences.first { $0.text.hasPrefix("It is a truth") }?.offset)
    }

    @Test("HTML and docs skip their headings too")
    func otherHeadings() throws {
        let html = Data(SavedArticle.html().utf8)
        let htmlText = try ReadableText.extract(html, mime: "text/html")
        let article = ListenScript(text: htmlText, skipping: ListenSkips.ranges(text: htmlText, file: html, mime: "text/html", readHeadings: false))
        #expect(article.sentences.first?.text.hasPrefix("Turnover is less about pay") == true)

        let markdown = "# The Tragic Hero in Macbeth\n\nMacbeth's letter arrives before he does.\n\n## The *letter*\n\nShe reads it as a plan."
        let docText = MarkdownText.plainText(markdown)
        let doc = ListenScript(text: docText, skipping: ListenSkips.ranges(text: docText, file: Data(markdown.utf8), mime: MarkdownText.mime, readHeadings: false))
        #expect(doc.sentences.map(\.text) == ["Macbeth's letter arrives before he does.", "She reads it as a plan."])
        #expect(inStep(doc, docText))
    }

    @Test("Running heads are found by their shape across pages, and page numbers on their own")
    func shapes() {
        let body = [
            "It is a truth universally acknowledged, that a single man in possession",
            "of a good fortune, must be in want of a wife. However little known",
            "the feelings or views of such a man may be on his first entering",
            "a neighbourhood, this truth is so well fixed in the minds of the",
            "surrounding families, that he is considered the rightful property",
            "of some one or other of their daughters. My dear Mr. Bennet, said",
            "his lady to him one day, have you heard that Netherfield Park is",
            "let at last? Mr. Bennet replied that he had not. But it is, returned",
            "she; for Mrs. Long has just been here, and she told me all about it.",
            "Mr. Bennet made no answer. Do you not want to know who has taken it?",
            "cried his wife impatiently. You want to tell me, and I have no",
            "objection to hearing it. This was invitation enough. Why, my dear,",
        ]
        let pages = (1...6).map { number in
            ([number.isMultiple(of: 2) ? "PRIDE AND PREJUDICE" : "CHAPTER III \(number * 2 + 10)"]
                + body[((number - 1) * 2)..<((number - 1) * 2 + 2)] + body[((number + 5) % 12)..<((number + 5) % 12 + 1)]
                + ["- \(number) -"]).joined(separator: "\n")
        }
        let whole = pages.joined(separator: "\n")
        let map = PDFPageMap(whole: whole, pages: pages)
        let found = ListenSkips.furniture(pages: pages, map: map)
        let words = whole as NSString
        let skipped = Set(found.map { words.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) })
        #expect(skipped.contains("PRIDE AND PREJUDICE"))
        #expect(skipped.contains("CHAPTER III 16"))
        #expect(skipped.contains("- 3 -"))
        #expect(!skipped.contains { line in body.contains(line) })

        for number in ["12", "Page 12", "12 of 300", "- 12 -", "xii", "  7  "] {
            #expect(ListenSkips.isPageNumber(number), "\(number)")
        }
        for words in ["12 apples", "Chapter 12", "", "It was then disclosed.", "civil", "vivid"] {
            #expect(!ListenSkips.isPageNumber(words), "\(words)")
        }
    }

    @Test("Blanking keeps the text's length, even through characters wider than one unit")
    func blanking() {
        let text = "Emoji 😀 heading\nBody."
        let blanked = ListenScript.blanked(text, [6..<16])
        #expect(blanked.utf16.count == text.utf16.count)
        #expect(blanked.hasSuffix("\nBody."))
    }
}

@MainActor
@Suite struct ListenSkipPauseTests {
    @Test("Listen pauses where a heading was skipped, and pausing in the gap waits for play")
    func pause() async throws {
        let text = "CHAPTER I.\nIt is a truth universally acknowledged.\nCHAPTER II.\nMr. Bennet was among the earliest."
        let skips = ListenSkips.headings(in: text, titles: ["CHAPTER I.", "CHAPTER II."])
        let script = ListenScript(text: text, skipping: skips)
        #expect(script.sentences.map(\.text) == ["It is a truth universally acknowledged.", "Mr. Bennet was among the earliest."])
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        listen.play(try #require(ListenTrack(id: UUID(), title: "Pride and Prejudice", script: script)))
        #expect(engine.spoken == ["It is a truth universally acknowledged."])
        engine.onFinish?()
        // The next sentence waits out the pause.
        #expect(engine.spoken.count == 1)
        #expect(listen.sentence == 1)
        try await Task.sleep(for: ListenController.skippedPause + .milliseconds(200))
        #expect(engine.spoken.last == "Mr. Bennet was among the earliest.")

        // Pausing during the gap holds it until play.
        listen.jump(to: 0)
        engine.onFinish?()
        listen.togglePause()
        try await Task.sleep(for: ListenController.skippedPause + .milliseconds(200))
        #expect(engine.spoken.last == "It is a truth universally acknowledged.")
        listen.togglePause()
        #expect(engine.spoken.last == "Mr. Bennet was among the earliest.")
    }
}

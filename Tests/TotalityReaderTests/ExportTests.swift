import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import TotalityCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import WebKit
#endif
@testable import TotalityReader

private typealias Run = ExportDocument.Run

private func paragraph(_ words: String) -> ExportDocument.Block { .paragraph([Run(words)]) }

/// An essay with real words, long enough to need several pages when double spaced.
private func essay(paragraphs: Int = 1) -> ExportDocument {
    var document = ExportDocument()
    document.meta.title = "Why teachers leave rural schools"
    document.meta.author = "Ana Ortiz, Sam Reyes"
    document.meta.date = "May 2027"
    document.meta.course = "EDU 410"
    document.meta.instructor = "Dr. Hale"
    var marked = Run("Turnover")
    marked.bold = true
    var noted = Run("")
    noted.note = 1
    document.blocks = [.heading(level: 1, runs: [Run("Why teachers leave")])]
    document.blocks.append(.paragraph([marked, Run(" is less about pay than about how a school is run."), noted]))
    for _ in 0..<paragraphs {
        document.blocks.append(paragraph(
            "Teachers who leave name the principal before the salary. In the exit survey, isolation and the drive to town come next, and pay comes fourth. The districts that kept their staff were the ones where teachers were asked before a schedule changed."
        ))
    }
    document.notes = [.init(number: 1, blocks: [paragraph("Ingersoll's analysis of the national survey.")])]
    document.bibliographyHeading = "References"
    document.bibliography = ["Ingersoll, R. M. (2001). Teacher turnover and teacher shortages. American Educational Research Journal, 38(3), 499–534."]
    return document
}

private func pdf(_ document: ExportDocument, _ template: ExportTemplate, images: [String: ExportImage] = [:]) throws -> PDFDocument {
    let data = try #require(PDFExporter.pdf(document, template: template, paper: .letter, images: images))
    return try #require(PDFDocument(data: data))
}

/// A small real image: a grey square with a darker band, encoded as PNG.
private func pngImage() throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.92, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    context.setFillColor(CGColor(srgbRed: 0.3, green: 0.33, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 100, width: 400, height: 80))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite struct ExportDocumentTests {
    @Test("The page's data is read strictly: unknown shapes, bad links and bad numbers are dropped")
    func parse() throws {
        let page: [String: Any] = [
            "meta": ["title": "Why teachers leave", "author": "Ana Ortiz"],
            "blocks": [
                ["t": "h", "level": 9, "runs": [["text": "Opening"]]],
                ["t": "p", "runs": [
                    ["text": "the survey", "href": "https://example.org/survey"],
                    ["text": "a trap", "href": "javascript:alert(1)"],
                    ["text": "a file", "href": "file:///etc/passwd"],
                    ["text": "", "note": -3],
                    ["text": "", "note": 2],
                ]],
                ["t": "script", "text": "alert(1)"],
                "not a block",
                ["t": "list", "ordered": true, "start": -5, "items": [["blocks": [["t": "p", "runs": [["text": "Pay"]]]], "task": true]]],
                ["t": "figure", "alt": "Turnover", "number": 1, "src": "turnover.png"],
            ],
            "notes": [["number": 2, "blocks": [["t": "p", "runs": [["text": "Asked in spring."]]]]], ["number": 0]],
            "bibliography": ["heading": "Works Cited", "entries": ["Ingersoll, R. (2001).", 7]],
        ]
        let document = try #require(ExportDocument(page: page, title: "Fallback"))
        #expect(document.meta.title == "Why teachers leave")
        #expect(document.blocks.count == 4)
        #expect(document.blocks[0] == .heading(level: 6, runs: [Run("Opening")]))
        guard case .paragraph(let runs) = document.blocks[1] else { Issue.record("not a paragraph"); return }
        #expect(runs.map(\.link) == [URL(string: "https://example.org/survey"), nil, nil, nil, nil])
        #expect(runs.map(\.note) == [nil, nil, nil, nil, 2])
        guard case .list(true, let start, let items) = document.blocks[2] else { Issue.record("not a list"); return }
        #expect(start == 0)
        #expect(items.first?.task == true)
        #expect(document.imageSources == ["turnover.png"])
        #expect(document.notes.map(\.number) == [2])
        #expect(document.bibliography == ["Ingersoll, R. (2001)."])
        #expect(document.bibliographyHeading == "Works Cited")

        #expect(ExportDocument(page: "text", title: "x") == nil)
        #expect(ExportDocument(page: ["blocks": [["t": "p", "runs": [["text": String(repeating: "x", count: ExportDocument.maxText + 1)]]]]], title: "x") == nil)
        #expect(ExportDocument(page: ["blocks": []], title: "Fallback")?.meta.title == "Fallback")
    }

    @Test("Chapters join with page breaks, and only the first keeps its front matter")
    func manuscript() {
        let joined = ExportDocument.manuscript([
            "---\ntitle: The Long Field\n---\n\n# One\n\nThe rain came early.",
            "---\ntitle: Chapter two\n---\n\n# Two\n\nThe barn held.",
        ])
        #expect(joined == "---\ntitle: The Long Field\n---\n\n# One\n\nThe rain came early.\n\n\\newpage\n\n\n# Two\n\nThe barn held.")
    }

    @Test("Images are re-encoded, and internet addresses are never looked up")
    func images() throws {
        let image = try #require(ExportImage(data: try pngImage()))
        #expect(image.image.width == 400)
        #expect(image.size(fitting: CGSize(width: 100, height: 500)) == CGSize(width: 100, height: 75))
        #expect(ExportImage(data: Data("not an image".utf8)) == nil)
        #expect(ExportImage.filename("images/turnover%20map.png") == "turnover map.png")
        #expect(ExportImage.filename("https://example.org/turnover.png") == nil)
        #expect(ExportImage.filename("data:image/png;base64,AAAA") == nil)
        let inline = "data:image/png;base64," + (try pngImage()).base64EncodedString()
        #expect(ExportImage.inline(inline) != nil)
        #expect(ExportImage.inline("data:text/html;base64,PHNjcmlwdD4=") == nil)
    }
}

@Suite struct WordExportTests {
    @Test("CRC-32 matches the standard check value")
    func crc() {
        #expect(ZipWriter.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test("A .docx reads back with its words, a real footnote, a page number and the image")
    func roundTrip() throws {
        var document = essay()
        document.blocks.append(.figure(alt: "Turnover by district", number: 1, source: "turnover.png"))
        let image = try #require(ExportImage(data: try pngImage()))
        let data = WordExporter.docx(document, template: .essay, paper: .letter, images: ["turnover.png": image])

        let text = try ReadableText.extract(data, mime: ReadableText.wordMime)
        #expect(text.contains("Turnover is less about pay than about how a school is run."))
        #expect(text.contains("Figure 1. Turnover by district"))
        #expect(text.contains("Ingersoll, R. M. (2001)."))

        var zip = try ZipArchive(data)
        let footnotes = String(decoding: try #require(try zip.read("word/footnotes.xml")), as: UTF8.self)
        #expect(footnotes.contains("Ingersoll&apos;s analysis") || footnotes.contains("Ingersoll's analysis"))
        let header = String(decoding: try #require(try zip.read("word/header1.xml")), as: UTF8.self)
        #expect(header.contains("PAGE"))
        #expect(header.contains("Ortiz"))
        let media = try #require(try zip.read("word/media/image1.png"))
        #expect(ExportImage(data: media) != nil)
        let body = String(decoding: try #require(try zip.read("word/document.xml")), as: UTF8.self)
        #expect(body.contains("w:pgMar"))
        #expect(!body.contains("<script"))
    }

    @Test("Characters XML can't hold are dropped, so the file still opens")
    func controlCharacters() throws {
        var document = ExportDocument()
        document.meta.title = "Bad \u{0001} bytes"
        document.blocks = [paragraph("Before\u{0008}after <b>&</b>")]
        let data = WordExporter.docx(document, template: .doc, paper: .a4)
        let text = try ReadableText.extract(data, mime: ReadableText.wordMime)
        #expect(text.contains("Beforeafter <b>&</b>"))
    }
}

@Suite struct PDFExportTests {
    @Test("Page breaks make pages, and long double-spaced text runs on to more")
    func pageCount() throws {
        var short = ExportDocument()
        short.meta.title = "Field notes"
        short.blocks = [paragraph("Monday: the creek was up."), .pageBreak, paragraph("Tuesday: it went down."), .pageBreak, paragraph("Wednesday: dry.")]
        #expect(try pdf(short, .doc).pageCount == 3)

        let long = essay(paragraphs: 30)
        let single = try pdf(long, .doc).pageCount
        let double = try pdf(long, .essay).pageCount
        #expect(single >= 2)
        #expect(double > single)
    }

    @Test("The words are real text, so they can be searched and read aloud")
    func selectableText() throws {
        let document = try pdf(essay(), .doc)
        let text = try #require(document.string)
        #expect(text.contains("Turnover is less about pay"))
        #expect(text.contains("Ingersoll's analysis of the national survey."))
        #expect(text.contains("References"))
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Why teachers leave rural schools")
    }

    @Test("Page numbers sit in the footer for a doc and beside the surname in the header for an essay")
    func pageNumbers() throws {
        let doc = try pdf(essay(paragraphs: 30), .doc)
        let second = try #require(doc.page(at: 1))
        let footer = try #require(doc.findString("2", withOptions: []).first { $0.pages.first == second && $0.bounds(for: second).minY < 72 })
        #expect(footer.bounds(for: second).midX > 250 && footer.bounds(for: second).midX < 362)

        let essayPDF = try pdf(essay(paragraphs: 30), .essay)
        for index in 0..<essayPDF.pageCount {
            let page = try #require(essayPDF.page(at: index))
            let head = try #require(essayPDF.findString("Ortiz \(index + 1)", withOptions: []).first { $0.pages.first == page })
            let bounds = head.bounds(for: page)
            #expect(bounds.minY > 792 - 72)
            #expect(bounds.maxX <= 612 - 72 + 1)
        }
    }

    @Test("A thesis has an unnumbered title page and a wider binding margin")
    func thesis() throws {
        let document = try pdf(essay(paragraphs: 12), .thesis)
        let title = try #require(document.page(at: 0))
        #expect(title.string?.contains("Why teachers leave rural schools") == true)
        #expect(title.string?.contains("1") == false)
        let body = try #require(document.page(at: 1))
        #expect(body.string?.contains("Why teachers leave\n") == true || body.string?.hasPrefix("Why teachers leave") == true)
        for selection in document.findString("Teachers who leave", withOptions: []) {
            guard let page = selection.pages.first else { continue }
            #expect(selection.bounds(for: page).minX >= 108 - 1)
        }
    }

    @Test("Text stays inside the template's margins")
    func margins() throws {
        for template in [ExportTemplate.doc, .essay, .manuscript] {
            let document = try pdf(essay(paragraphs: 20), template)
            for selection in document.findString("principal", withOptions: []) {
                guard let page = selection.pages.first else { continue }
                let bounds = selection.bounds(for: page)
                #expect(bounds.minX >= 72 - 1, "\(template)")
                #expect(bounds.maxX <= 612 - 72 + 1, "\(template)")
                #expect(bounds.minY >= 72 - 1, "\(template)")
                #expect(bounds.maxY <= 792 - 72 + 1, "\(template)")
            }
        }
    }

    @Test("Images are drawn on the page, and links stay clickable")
    func imagesAndLinks() throws {
        var document = essay()
        var link = Run("the survey")
        link.link = URL(string: "https://example.org/survey")
        document.blocks.append(.paragraph([Run("See "), link, Run(".")]))
        document.blocks.append(.figure(alt: "Turnover by district", number: 1, source: "turnover.png"))
        let image = try #require(ExportImage(data: try pngImage()))
        let withImage = try #require(PDFExporter.pdf(document, template: .doc, paper: .letter, images: ["turnover.png": image]))
        let without = try #require(PDFExporter.pdf(document, template: .doc, paper: .letter))
        #expect(withImage.count > without.count + 500)

        let pdfDocument = try #require(PDFDocument(data: withImage))
        let links = (0..<pdfDocument.pageCount).flatMap { pdfDocument.page(at: $0)?.annotations ?? [] }.compactMap(\.url)
        #expect(links == [URL(string: "https://example.org/survey")!])
        #expect(pdfDocument.string?.contains("Figure 1. Turnover by district") == true)
    }

    @Test("An empty doc still makes one page with its title")
    func empty() throws {
        var document = ExportDocument()
        document.meta.title = "Untitled draft"
        let pdfDocument = try pdf(document, .doc)
        #expect(pdfDocument.pageCount == 1)
        #expect(pdfDocument.string?.contains("Untitled draft") == true)
    }
}

#if os(macOS)
/// Writes real exports, and pictures of their pages, for a person to look at, when TOTALITY_RENDER_DIR is set.
@Suite struct RenderExports {
    @Test func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        var document = essay(paragraphs: 6)
        var link = Run("the national survey")
        link.link = URL(string: "https://nces.ed.gov/surveys/sass/")
        document.blocks.insert(.paragraph([Run("The figures come from "), link, Run(", which asked every district the same questions.")]), at: 2)
        document.blocks.insert(.figure(alt: "Turnover by district", number: 1, source: "turnover.png"), at: 3)
        document.blocks.insert(.list(ordered: true, start: 1, items: [
            .init(task: nil, blocks: [paragraph("Leadership")]), .init(task: nil, blocks: [paragraph("Isolation")]), .init(task: nil, blocks: [paragraph("Pay")]),
        ]), at: 4)
        document.blocks.insert(.table(header: [[Run("District")], [Run("Left in 2026")]], rows: [[[Run("North")], [Run("12")]], [[Run("Valley")], [Run("4")]]]), at: 5)
        let images = ["turnover.png": try #require(ExportImage(data: try pngImage()))]
        for template in ExportTemplate.allCases {
            let data = try #require(PDFExporter.pdf(document, template: template, paper: .letter, images: images))
            try data.write(to: folder.appendingPathComponent("export-\(template.rawValue).pdf"))
            let pdf = try #require(PDFDocument(data: data))
            for index in 0..<min(2, pdf.pageCount) {
                let page = try #require(pdf.page(at: index))
                let image = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
                let tiff = try #require(image.tiffRepresentation)
                let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("export-\(template.rawValue)-page\(index + 1).png"))
            }
        }
        try WordExporter.docx(document, template: .essay, paper: .letter, images: images)
            .write(to: folder.appendingPathComponent("export-essay.docx"))
    }
}
#endif

@MainActor
@Suite struct ExportTwoUserTests {
    @Test("Export finds images only in the person's own Reader")
    func staysPrivate() async throws {
        let store = MemoryBlobStore()
        let vault1 = try newVault(store: store)
        _ = try await vault1.importFile(try pngImage(), filename: "turnover.png")
        let user1 = ReaderModel(vault: vault1, listen: ListenController(engine: FakeSpeechEngine()))
        await user1.load()
        var document = ExportDocument()
        document.blocks = [.figure(alt: "Turnover", number: 1, source: "images/turnover.png"), .figure(alt: "Map", number: 2, source: "https://example.org/map.png")]
        let found = await user1.exportImages(for: document, near: nil)
        #expect(Set(found.keys) == ["images/turnover.png"])

        let user2 = ReaderModel(vault: try newVault(store: store), listen: ListenController(engine: FakeSpeechEngine()))
        await user2.load()
        #expect(await user2.exportImages(for: document, near: nil).isEmpty)
    }
}

#if os(macOS)
/// The writing page reads a doc for export.
@MainActor
@Suite(.serialized) struct ExportWebTests {
    @Test("The page sends a doc with its citations, notes and figures worked out")
    func exportDoc() async throws {
        let rules = WritingRules(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ExportWebTests-\(UUID())"))
        let editor = WritingEditorController(rules: rules)
        await editor.start()
        try #require(editor.webView).frame = CGRect(x: 0, y: 0, width: 600, height: 900)
        let text = """
        ---
        title: Why teachers leave rural schools
        author: Ana Ortiz
        ---

        # Why teachers leave

        Turnover is *less* about pay.[^1] See [[Retention notes|our notes]].

        ![Turnover by district](turnover.png)

        [^1]: Asked in spring.
        """
        editor.load(text, settings: WritingSettings(), docs: [])
        for _ in 0..<200 where editor.phase != .ready {
            try await Task.sleep(for: .milliseconds(25))
        }
        let value = try #require(await editor.call("exportDoc", text))
        let document = try #require(ExportDocument(page: value, title: "Fallback"))
        #expect(document.meta.title == "Why teachers leave rural schools")
        #expect(document.meta.author == "Ana Ortiz")
        #expect(document.notes.map(\.number) == [1])
        #expect(document.imageSources == ["turnover.png"])
        guard case .paragraph(let runs) = document.blocks[1] else { Issue.record("not a paragraph"); return }
        #expect(Run.words(runs).contains("See our notes."))
    }
}
#endif

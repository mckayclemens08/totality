import Foundation
import Testing
import TotalityCore
@testable import TotalityReader
#if os(macOS)
import AppKit
import WebKit
#endif

/// A BibTeX export much like Zotero's, with the awkward parts real libraries have.
private let zoteroExport = #"""
@string{ajps = "American Journal of Political Science"}

% Exported from Zotero
@article{ingersoll2001,
  author = {Ingersoll, Richard M.},
  title = {Teacher Turnover and Teacher Shortages: An Organizational Analysis},
  journal = {American Educational Research Journal},
  year = 2001,
  volume = {38},
  number = {3},
  pages = {499--534},
  doi = {10.3102/00028312038003499}
}

@book{bourdieu1984,
  author = {Bourdieu, Pierre and Nice, Richard},
  title = {Distinction: A Social Critique of the Judgement of Taste},
  publisher = {Harvard University Press},
  address = {Cambridge, MA},
  year = {1984}
}

@incollection{garcia2019,
  author = {Garc{\'\i}a, Ana and van der Berg, Servaas and {World Bank}},
  title = {Rural Schools {and} the Long Walk},
  booktitle = ajps # " Supplement",
  year = {2019},
  month = mar
}

@comment{this is ignored}
"""#

@Suite struct ReferencesTests {
    private func items(_ bib: String) -> [[String: Any]] { BibTeX.items(bib) }

    @Test("BibTeX entries become CSL items with the right types, names, dates and pages")
    func bibtex() throws {
        let found = items(zoteroExport)
        #expect(found.map { $0["id"] as? String } == ["ingersoll2001", "bourdieu1984", "garcia2019"])
        let article = try #require(found.first)
        #expect(article["type"] as? String == "article-journal")
        #expect(article["container-title"] as? String == "American Educational Research Journal")
        #expect(article["page"] as? String == "499–534")
        #expect(article["DOI"] as? String == "10.3102/00028312038003499")
        #expect(article["issue"] as? String == "3")
        let issued = try #require(article["issued"] as? [String: Any])
        #expect((issued["date-parts"] as? [[Int]]) == [[2001]])
        #expect((article["author"] as? [[String: String]]) == [["family": "Ingersoll", "given": "Richard M."]])

        let book = found[1]
        #expect(book["type"] as? String == "book")
        #expect(book["publisher-place"] as? String == "Cambridge, MA")
        #expect((book["author"] as? [[String: String]])?.count == 2)
    }

    @Test("Accents, particles, organisations, macros and months come through")
    func awkwardParts() throws {
        let chapter = try #require(items(zoteroExport).last)
        #expect(chapter["type"] as? String == "chapter")
        #expect(chapter["title"] as? String == "Rural Schools and the Long Walk")
        #expect(chapter["container-title"] as? String == "American Journal of Political Science Supplement")
        let people = try #require(chapter["author"] as? [[String: String]])
        #expect(people[0]["family"] == "García")
        #expect(people[1]["family"]?.hasSuffix("Berg") == true)
        #expect(people[2]["literal"] == "World Bank")
        let issued = try #require(chapter["issued"] as? [String: Any])
        #expect((issued["date-parts"] as? [[Int]]) == [[2019, 3]])
    }

    @Test("A file that isn't a reference library isn't treated as one")
    func notALibrary() {
        #expect(References.library(from: Data("Just some notes about the trip.".utf8), filename: "notes.bib") == nil)
        #expect(References.library(from: Data(#"{"name": "package"}"#.utf8), filename: "package.json") == nil)
        #expect(References.library(from: Data(#"[{"id": "a"}]"#.utf8), filename: "refs.json") == nil, "no type")
        #expect(References.library(from: Data(zoteroExport.utf8), filename: "thesis.txt") == nil)
    }

    @Test("CSL JSON keeps items with an id and a type, and a numeric id becomes a string")
    func cslJSON() throws {
        let json = #"[{"id": 7, "type": "book", "title": "Seven"}, {"type": "book"}, {"id": "smith2020", "type": "article-journal"}]"#
        let library = try #require(References.library(from: Data(json.utf8), filename: "My Library.json"))
        #expect(References.summaries(library).map(\.id) == ["7", "smith2020"])
    }

    @Test("Summaries name one, two or many authors the way the picker shows them")
    func summaries() throws {
        let library = try #require(References.library(from: Data(zoteroExport.utf8), filename: "thesis.bib"))
        let summaries = References.summaries(library)
        #expect(summaries.map(\.author) == ["Ingersoll", "Bourdieu and Nice", "García et al."])
        #expect(summaries.map(\.year) == ["2001", "1984", "2019"])
        #expect(References.readableText(library).hasPrefix("Ingersoll, 2001, Teacher Turnover"))
    }
}

@Suite struct ReferenceVaultTests {
    @Test("A .bib file imports as one sealed library, stored as CSL JSON")
    func importsAsLibrary() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let item = try await vault.importFile(Data(zoteroExport.utf8), filename: "Thesis sources.bib")
        #expect(item.mime == References.mime)
        #expect(item.title == "Thesis sources")
        #expect(item.typeName == "References")
        let body = try await vault.body(of: item.id)
        #expect(References.summaries(body).count == 3)
        for name in try store.names() {
            let blob = try #require(try store.read(name))
            #expect(blob.range(of: Data("Ingersoll".utf8)) == nil, "\(name) holds a name in the clear")
        }
        #expect(try await vault.text(of: item.id).contains("Bourdieu and Nice, 1984"))
    }

    @Test("Every library is merged for citing, and the newer one wins a shared key")
    func merges() async throws {
        let vault = try newVault()
        _ = try await vault.importFile(Data(zoteroExport.utf8), filename: "old.bib")
        try await Task.sleep(for: .milliseconds(5))
        let newer = #"[{"id": "ingersoll2001", "type": "article-journal", "title": "Corrected title"}, {"id": "lortie1975", "type": "book", "title": "Schoolteacher"}]"#
        _ = try await vault.importFile(Data(newer.utf8), filename: "new.json")
        let merged = References.summaries(try await vault.referenceLibrary())
        #expect(merged.count == 4)
        #expect(merged.first { $0.id == "ingersoll2001" }?.title == "Corrected title")
    }

    @Test("With no libraries, the merged library is an empty list")
    func emptyLibrary() async throws {
        let vault = try newVault()
        #expect(String(decoding: try await vault.referenceLibrary(), as: UTF8.self) == "[]")
    }
}

@Suite struct ScholarlyMarkdownTests {
    private let essay = """
    ---
    title: Why teachers leave
    csl: apa
    ---

    # Method {#sec:method}

    Turnover is organisational [@ingersoll2001, p. 501], as @bourdieu1984 might say.[^1]

    ![Turnover by district](turnover.png){#fig:turnover}

    As @fig:turnover shows, and [see @sec:method], the pattern holds.

    [^1]: Bourdieu writes about taste, not schools.
    """

    @Test("Listen and search skip front matter, labels and bracket citations, and read cross-refs")
    func plainText() {
        let text = MarkdownText.plainText(essay)
        #expect(!text.contains("csl: apa"))
        #expect(!text.contains("{#"))
        #expect(!text.contains("ingersoll2001"))
        #expect(text.contains("Turnover is organisational, as bourdieu1984 might say."))
        #expect(text.contains("As Figure 1 shows, and Method, the pattern holds."))
        #expect(MarkdownText.headings(essay).map(\.text) == ["Method"])
    }

    @Test("An email address isn't a citation")
    func email() {
        #expect(MarkdownText.plainText("Write to ana@example.org about it.").contains("ana@example.org"))
    }
}

@Suite struct ScholarlyMessageTests {
    @Test("The outline brings labels and the style, and a bad label is dropped")
    func outline() {
        let message: [String: Any] = [
            "type": "outline",
            "headings": [["level": 1, "text": "Method", "from": 30]],
            "labels": [
                ["id": "sec:method", "kind": "sec", "number": 1, "caption": "Method"],
                ["id": "fig:turnover", "kind": "fig", "number": 1, "caption": "Turnover by district"],
                ["id": "fig:x", "kind": "sec", "number": 1, "caption": "Kind doesn't match"],
                ["id": "<script>", "kind": "sec", "number": 1, "caption": "Not a label"],
            ],
            "style": "chicago",
        ]
        guard case .outline(let headings, let labels, let style) = WritingMessage.parse(message) else {
            Issue.record("not an outline")
            return
        }
        #expect(headings.map(\.text) == ["Method"])
        #expect(labels.map(\.id) == ["sec:method", "fig:turnover"])
        #expect(labels.map(\.title) == ["Method", "Figure 1: Turnover by district"])
        #expect(style == .chicago)
    }

    @Test("An unknown style reads as APA")
    func unknownStyle() {
        let message: [String: Any] = ["type": "outline", "headings": [], "style": "harvard-cite-them-right"]
        guard case .outline(_, _, let style) = WritingMessage.parse(message) else {
            Issue.record("not an outline")
            return
        }
        #expect(style == .apa)
    }
}

@Suite struct ScholarlyTwoUserTests {
    @Test("User 2 can't read user 1's library, and a share opens as CSL JSON for the grantee")
    func librariesStayPrivate() async throws {
        let store = MemoryBlobStore()
        let user1 = try newVault(store: store)
        let library = try await user1.importFile(Data(zoteroExport.utf8), filename: "Thesis sources.bib")

        let user2 = ReaderVault(store: store, rootKey: try .generate())
        await #expect(throws: CryptoError.authenticationFailed) { try await user2.body(of: library.id) }
        #expect(References.summaries(try await user2.referenceLibrary()).isEmpty)

        let grantee = try IdentityKeys.generate()
        let opened = try await user1.share(library.id, with: grantee.bundle()).open(with: grantee)
        #expect(opened.header.mime == References.mime)
        #expect(References.summaries(opened.body).map(\.id) == ["ingersoll2001", "bourdieu1984", "garcia2019"])
    }
}

#if os(macOS)
/// Footnotes, citations and cross-references in the real page.
@MainActor
@Suite(.serialized) struct WritingScholarlyWebTests {
    private let essay = """
    ---
    csl: apa
    ---

    # Why teachers leave {#sec:why}

    Turnover is organisational [@ingersoll2001, p. 501], and taste is social [@bourdieu1984].

    ## Method

    The interviews ran in six rural districts.
    """

    private var library: Data {
        References.library(from: Data(zoteroExport.utf8), filename: "thesis.bib") ?? Data("[]".utf8)
    }

    private func readyEditor(_ text: String) async throws -> WritingEditorController {
        let rules = WritingRules(directory: FileManager.default.temporaryDirectory.appendingPathComponent("WritingRulesTests-\(UUID())"))
        let editor = WritingEditorController(rules: rules)
        await editor.start()
        try #require(editor.webView).frame = CGRect(x: 0, y: 0, width: 600, height: 900)
        editor.load(text, settings: WritingSettings(), library: library)
        for _ in 0..<200 where editor.phase != .ready || editor.outline.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(editor.phase == .ready)
        return editor
    }

    private func script(_ editor: WritingEditorController, _ source: String) async throws -> Any? {
        try await #require(editor.webView).callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    private func text(_ editor: WritingEditorController) async throws -> String {
        let reply = try await script(editor, "return window.totality.text()")
        return try #require((reply as? [String: Any])?["text"] as? String)
    }

    @Test("Citations read in the style, and the bibliography lists what's cited")
    func citations() async throws {
        let editor = try await readyEditor(essay)
        #expect(editor.style == .apa)
        #expect(editor.labels.map(\.id) == ["sec:why"])
        _ = await editor.call("jump", 0)
        let chips = try await script(editor, "return [...document.querySelectorAll('.cm-tl-cite')].map(e => e.textContent)") as? [String]
        #expect(chips == ["(Ingersoll, 2001, p. 501)", "(Bourdieu & Nice, 1984)"])
        let entries = try await script(editor, "return [...document.querySelectorAll('.cm-tl-bibliography-entry')].map(e => e.textContent)") as? [String]
        #expect(entries?.count == 2)
        #expect(entries?.last?.hasPrefix("Ingersoll, R. M. (2001).") == true)
        let heading = try await script(editor, "return document.querySelector('.cm-tl-bibliography-title').textContent") as? String
        #expect(heading == "References")
    }

    @Test("Changing the style rewrites the front matter and the bibliography heading")
    func style() async throws {
        let editor = try await readyEditor(essay)
        _ = await editor.call("style", "mla")
        for _ in 0..<100 where editor.style != .mla { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.style == .mla)
        #expect(try await text(editor).hasPrefix("---\ncsl: mla\n---"))
        let heading = try await script(editor, "return document.querySelector('.cm-tl-bibliography-title').textContent") as? String
        #expect(heading == "Works Cited")
    }

    @Test("A footnote adds its marker and its note, numbered after the last")
    func footnote() async throws {
        let editor = try await readyEditor("The districts were rural.\n\n[^1]: All six were in Montana.")
        _ = await editor.call("jump", ("The districts were rural." as NSString).length)
        #expect(await editor.call("footnote") as? String == "2")
        let typed = try await text(editor)
        #expect(typed.hasPrefix("The districts were rural.[^2]"))
        #expect(typed.hasSuffix("[^1]: All six were in Montana.\n[^2]: "))
    }

    @Test("Citing adds to the citation the cursor is in, and a bad key is refused")
    func cite() async throws {
        let editor = try await readyEditor("Turnover is organisational [@ingersoll2001].")
        _ = await editor.call("jump", ("Turnover is organisational [@ingersoll2001" as NSString).length)
        #expect(await editor.call("cite", "bourdieu1984") as? Bool == true)
        #expect(try await text(editor) == "Turnover is organisational [@ingersoll2001; @bourdieu1984].")
        #expect(await editor.call("cite", "x]<img>") as? Bool == false)
    }

    @Test("Labelling a heading, then referring to it, reads as its title")
    func crossReference() async throws {
        let editor = try await readyEditor(essay)
        let method = try #require(editor.outline.first { $0.text == "Method" })
        #expect(await editor.call("label", method.from) as? String == "sec:method")
        #expect(await editor.call("label", method.from) as? String == "sec:method", "a second label isn't added")
        _ = await editor.call("jump", (try await text(editor) as NSString).length)
        #expect(await editor.call("crossref", "sec:method") as? Bool == true)
        let typed = try await text(editor)
        #expect(typed.contains("## Method {#sec:method}\n"))
        #expect(typed.hasSuffix("@sec:method"))
        #expect(await editor.call("crossref", "javascript:alert(1)") as? Bool == false)
        for _ in 0..<100 where editor.labels.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.labels.map(\.id) == ["sec:why", "sec:method"])
    }

    @Test("Library text stays text in the bibliography")
    func libraryStaysText() async throws {
        let hostile = #"[{"id": "x", "type": "book", "title": "<img src=x onerror=\"document.title='ran'\">", "author": [{"family": "<b>Bold</b>"}]}]"#
        let editor = try await readyEditor("A claim [@x].")
        editor.useLibrary(Data(hostile.utf8))
        try await Task.sleep(for: .milliseconds(200))
        let images = try await script(editor, "return document.querySelectorAll('img:not(.cm-widgetBuffer), b').length") as? Int
        #expect(images == 0)
        let title = try await script(editor, "return document.title") as? String
        #expect(title != "ran")
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let thesis = """
        ---
        title: Why teachers leave rural schools
        csl: apa
        ---

        # Why teachers leave {#sec:why}

        Turnover is less about pay than about how a school is run [@ingersoll2001, p. 501]. What counts as a good post is learned, not given [@bourdieu1984].[^1]

        ## The long walk {#sec:walk}

        García and colleagues found the same in rural districts [-@garcia2019], which @sec:why takes up.

        [^1]: Bourdieu writes about taste, but the argument carries to careers.
        """
        let editor = try await readyEditor(thesis)
        _ = await editor.call("jump", (thesis as NSString).length)
        let webView = try #require(editor.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 393, height: 900)
        try await Task.sleep(for: .milliseconds(300))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = try await webView.takeSnapshot(configuration: configuration)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("writing-scholarly.png"))
    }
}
#endif

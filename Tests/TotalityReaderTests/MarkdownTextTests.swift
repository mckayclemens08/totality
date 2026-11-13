import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

@Suite struct MarkdownTextTests {
    private typealias Run = DocText.Run
    private typealias Paragraph = DocText.Paragraph

    private let essay = """
    # The Tragic Hero in *Macbeth*

    Aristotle's account of tragedy, in the *Poetics*, asks for a hero who falls through **hamartia**,
    an error of judgement rather than a vice.[^1] Macbeth fits that \\*only\\* in part.

    ## Ambition

    - The witches' prophecy
    - Lady Macbeth's *goading*
    - [ ] Check the Arden line numbers

    > Stars, hide your fires;
    > Let not light see my black and deep desires.

    1. Act one
    2. Act five

    See the [Folger edition](https://www.folger.edu/explore/shakespeares-works/macbeth/) and `snake_case`.

    ---

    [^1]: Poetics, 1453a.
    """

    @Test("Listen hears the words without the symbols, and soft line breaks join a paragraph")
    func plainText() {
        let text = MarkdownText.plainText(essay)
        #expect(text == """
        The Tragic Hero in Macbeth
        Aristotle's account of tragedy, in the Poetics, asks for a hero who falls through hamartia, an error of judgement rather than a vice. Macbeth fits that *only* in part.
        Ambition
        The witches' prophecy
        Lady Macbeth's goading
        Check the Arden line numbers
        Stars, hide your fires; Let not light see my black and deep desires.
        Act one
        Act five
        See the Folger edition and snake_case.
        Poetics, 1453a.
        """)
    }

    @Test("Headings come out with their levels, for the outline and for Read Along")
    func headings() {
        let found = MarkdownText.headings(essay)
        #expect(found.map(\.level) == [1, 2])
        #expect(found.map(\.text) == ["The Tragic Hero in Macbeth", "Ambition"])
    }

    @Test("A fenced code block is read as written, and a `#` inside it isn't a heading")
    func codeBlocks() {
        let text = "Intro\n\n```\n# not a heading\n```\n\nAfter"
        #expect(MarkdownText.headings(text).isEmpty)
        #expect(MarkdownText.plainText(text) == "Intro\n# not a heading\nAfter")
    }

    @Test("Underscores mark emphasis only at the edge of a word")
    func underscores() {
        #expect(MarkdownText.inline("__The Prince__ and _Discourses_ by file_name_v2") == "The Prince and Discourses by file_name_v2")
    }

    @Test("A table reads as its cells")
    func tables() {
        let table = "| Act | Scene |\n|-----|:-----:|\n| 1 | 3 |"
        #expect(MarkdownText.plainText(table) == "Act, Scene 1, 3")
    }

    // MARK: Converting older docs

    @Test("An older formatted doc becomes Markdown with blank lines between paragraphs and tight lists")
    func convertsFormattedDoc() {
        let trip = DocText(paragraphs: [
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
        #expect(MarkdownText.markdown(from: trip) == """
        # Red Rock trip

        Leave **Friday**, back *Sunday*.

        ## Packing

        - Rope
        - ***Rack***

        1. Book the campsite
        2. Check the [forecast](https://www.weather.gov/)

        Done.
        """)
    }

    @Test("A plain note's symbols stay as written, rather than becoming formatting")
    func plainNoteStaysLiteral() {
        let note = DocText(plain: """
        # of tickets: 4
        - not a list
        1. not a number
        > not a quote
        2 * 3 = 6, file_name, [draft], <b>, ~approx~, x^2, $5, @mention, me@example.com
            indented line
        """)
        let converted = MarkdownText.markdown(from: note)
        #expect(converted == """
        \\# of tickets: 4

        \\- not a list

        1\\. not a number

        \\> not a quote

        2 \\* 3 = 6, file\\_name, \\[draft\\], \\<b\\>, \\~approx\\~, x\\^2, \\$5, \\@mention, me@example.com

        \u{00A0}\u{00A0}\u{00A0}\u{00A0}indented line
        """)
        // Reading it back gives the very words that were typed.
        #expect(MarkdownText.plainText(converted) == """
        # of tickets: 4
        - not a list
        1. not a number
        > not a quote
        2 * 3 = 6, file_name, [draft], <b>, ~approx~, x^2, $5, @mention, me@example.com
        indented line
        """)
    }

    @Test("A link address can't break out of its brackets")
    func linkAddressesStayInside() {
        let doc = DocText(paragraphs: [Paragraph(runs: [Run("notes", link: URL(string: "https://example.org/a_(b)"))])])
        #expect(MarkdownText.markdown(from: doc) == "[notes](https://example.org/a_%28b%29)")
    }
}

@Suite struct WritingConversionTests {
    private func oldNote(_ vault: ReaderVault, body: String, mime: String?, folder: UUID? = nil) async throws -> ReaderItem {
        let note = try await vault.createNote(title: "Thesis notes", folder: folder)
        return try await vault.saveNote(note.id, title: "Thesis notes", body: body, mime: mime ?? "text/plain")
    }

    @Test("New docs are Markdown from the start, and nothing is kept for them")
    func newDocs() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Chapter 1")
        #expect(note.mime == MarkdownText.mime)
        let opened = try await vault.markdown(of: note.id)
        #expect(opened.text.isEmpty)
        #expect(opened.item.keptOriginalID == nil)
        #expect(try await vault.list().items.count == 1)
    }

    @Test("An older doc converts once, keeps its original beside it read-only, and leaves its date alone")
    func convertsOnce() async throws {
        let vault = try newVault()
        let folder = try await vault.createFolder(title: "Dissertation")
        let old = try await oldNote(vault, body: "# Method\n**Interviews** with 12 teachers\n- Coded twice", mime: ReadableText.markdownMime, folder: folder.id)

        let opened = try await vault.markdown(of: old.id)
        #expect(opened.text == "# Method\n\n**Interviews** with 12 teachers\n\n- Coded twice")
        #expect(opened.item.mime == MarkdownText.mime)
        #expect(opened.item.updatedAt == old.updatedAt)
        let originalID = try #require(opened.item.keptOriginalID)

        let original = try await vault.item(originalID)
        #expect(original.kind == .file)
        #expect(original.title == "Thesis notes (before the new editor)")
        #expect(original.folderID == folder.id)
        #expect(original.mime == ReadableText.markdownMime)
        #expect(String(decoding: try await vault.body(of: originalID), as: UTF8.self) == "# Method\n**Interviews** with 12 teachers\n- Coded twice")

        // Opening again changes nothing.
        let again = try await vault.markdown(of: old.id)
        #expect(again.text == opened.text)
        #expect(try await vault.list().items.count == 2)

        // Search and Listen read the new text.
        #expect(try await vault.text(of: old.id) == "Method\nInterviews with 12 teachers\nCoded twice")
    }

    @Test("Two devices converting the same doc land on the same original")
    func sameOriginalEverywhere() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let vault = ReaderVault(store: store, rootKey: key)
        let old = try await oldNote(vault, body: "Draft one", mime: nil)
        let first = try await vault.markdown(of: old.id).item.keptOriginalID
        let other = ReaderVault(store: store, rootKey: key)
        try await other.saveNote(old.id, title: "Thesis notes", body: "Draft one", mime: "text/plain")
        let second = try await other.markdown(of: old.id).item.keptOriginalID
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("Saying it looks right sends the original to Recently Deleted, where it can come back")
    func confirming() async throws {
        let vault = try newVault()
        let old = try await oldNote(vault, body: "Literature review", mime: nil)
        let originalID = try #require(try await vault.markdown(of: old.id).item.keptOriginalID)
        try await vault.confirmConversion(old.id)
        #expect(try await vault.item(old.id).keptOriginalID == nil)
        #expect(try await vault.trashed().map(\.id) == [originalID])
        try await vault.restore(originalID)
        #expect(try await vault.item(originalID).title == "Thesis notes (before the new editor)")
    }

    @Test("Confirming still works when the original was already deleted by hand")
    func confirmingAfterManualDelete() async throws {
        let vault = try newVault()
        let old = try await oldNote(vault, body: "Abstract", mime: nil)
        let originalID = try #require(try await vault.markdown(of: old.id).item.keptOriginalID)
        try await vault.delete(originalID)
        try await vault.confirmConversion(old.id)
        #expect(try await vault.item(old.id).keptOriginalID == nil)
    }

    @Test("An empty older doc just becomes Markdown")
    func emptyOldDoc() async throws {
        let vault = try newVault()
        let old = try await oldNote(vault, body: "  \n", mime: nil)
        let opened = try await vault.markdown(of: old.id)
        #expect(opened.item.keptOriginalID == nil)
        #expect(opened.text.isEmpty)
        #expect(try await vault.list().items.count == 1)
    }

    @Test("Only notes open for writing")
    func filesDoNotOpen() async throws {
        let vault = try newVault()
        let file = try await vault.importFile(Data("Notes".utf8), filename: "notes.txt")
        await #expect(throws: ReaderError.notANote) { try await vault.markdown(of: file.id) }
    }

    @Test("A save from the writing editor keeps its Markdown, and a conflict copy does too")
    func savesAndConflicts() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Essay")
        let text = "# Essay\n\nFirst *draft*."
        let saved = try await vault.saveNote(note.id, title: "Essay", body: text, mime: MarkdownText.mime, basedOn: note.updatedAt)
        guard case .saved(let item) = saved else {
            Issue.record("Expected a save")
            return
        }
        #expect(try await vault.markdown(of: item.id).text == text)
        let stale = try await vault.saveNote(note.id, title: "Essay", body: text + " Second.", mime: MarkdownText.mime, basedOn: note.updatedAt)
        guard case .keptAsCopy(let copy) = stale else {
            Issue.record("Expected a copy")
            return
        }
        #expect(try await vault.markdown(of: copy.id).text == text + " Second.")
        #expect(try await vault.search("draft").count == 2)
    }
}

/// User 2 can't open User 1's docs, the originals kept from converting them, or their text.
@Suite struct WritingTwoUserTests {
    @Test("User 2 can't read user 1's converted doc or its kept original from the same storage")
    func user2CannotReadConvertedDocs() async throws {
        let store = MemoryBlobStore()
        let user1 = try newVault(store: store)
        let note = try await user1.createNote(title: "Dissertation chapter 2")
        try await user1.saveNote(note.id, title: "Dissertation chapter 2", body: "Unpublished findings", mime: "text/plain")
        let originalID = try #require(try await user1.markdown(of: note.id).item.keptOriginalID)

        let user2 = ReaderVault(store: store, rootKey: try .generate())
        let listing = try await user2.list()
        #expect(listing.items.isEmpty)
        #expect(listing.unreadable == 2)
        await #expect(throws: CryptoError.authenticationFailed) { try await user2.markdown(of: note.id) }
        await #expect(throws: CryptoError.authenticationFailed) { try await user2.body(of: originalID) }
        #expect(try await user2.search("Unpublished").isEmpty)

        // Nothing either user wrote is readable in storage.
        for name in try store.names() {
            let blob = try #require(try store.read(name))
            for needle in ["Unpublished", "Dissertation", "before the new editor", "variant=pandoc"] {
                #expect(blob.range(of: Data(needle.utf8)) == nil, "\(needle) in \(name)")
            }
        }
    }

    @Test("A shared Markdown doc opens for user 2 as the Markdown user 1 wrote")
    func sharedDocOpens() async throws {
        let user1 = try newVault()
        let note = try await user1.createNote(title: "Essay for review")
        try await user1.saveNote(note.id, title: "Essay for review", body: "# Draft\n\nPlease read *section two*.", mime: MarkdownText.mime)
        let user2 = try IdentityKeys.generate()
        let opened = try await user1.share(note.id, with: user2.bundle()).open(with: user2)
        #expect(opened.header.mime == MarkdownText.mime)
        #expect(MarkdownText.plainText(String(decoding: opened.body, as: UTF8.self)) == "Draft\nPlease read section two.")
    }
}

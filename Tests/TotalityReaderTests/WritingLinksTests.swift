import Foundation
import Testing
import TotalityCore
#if os(macOS)
import AppKit
import WebKit
#endif
@testable import TotalityReader

private let essay = """
# The Tragic Hero in Macbeth

## The letter

Macbeth's letter to his wife arrives before he does. She reads it as a plan.
"""

private let notes = """
# Act one notes

The letter scene is argued in [[The Tragic Hero in Macbeth#The letter|the essay]], and the witches get
their own page in [[Witches and prophecy]]. Back to [[#Act one notes]].

```
[[The Tragic Hero in Macbeth]] inside code is only an example
```

Quoting `[[The Tragic Hero in Macbeth]]` in a code span isn't a link either.
"""

@Suite struct WikiLinksTests {
    @Test("Links name a doc, a heading in it, and the words they read as, outside code")
    func links() {
        #expect(WikiLinks.links(in: notes) == [
            .init(target: "The Tragic Hero in Macbeth", heading: "The letter", alias: "the essay"),
            .init(target: "Witches and prophecy", heading: "", alias: ""),
            .init(target: "", heading: "Act one notes", alias: ""),
        ])
        #expect(WikiLinks.links(in: "[[]] [[ | words]] [[Unclosed").isEmpty)
        #expect(WikiLinks.links(in: "[[\(String(repeating: "x", count: 201))]]").isEmpty)
    }

    @Test("Listen and search read a link as its words")
    func readable() {
        #expect(WikiLinks.readable("See [[Witches and prophecy|the witches]] and [[Macbeth#Act two]].") == "See the witches and Macbeth.")
        #expect(MarkdownText.plainText("Argued in [[The Tragic Hero in Macbeth#The letter|the essay]].") == "Argued in the essay.")
        #expect(MarkdownText.plainText("Jump to [[#Act two]].") == "Jump to Act two.")
    }

    @Test("Titles match whatever their case and spacing")
    func titles() {
        #expect(WikiLinks.titleKey("  The Tragic  Hero in MACBETH ") == WikiLinks.titleKey("The Tragic Hero in Macbeth"))
        #expect(WikiLinks.linkable("Lady Macbeth's goading"))
        for title in ["C# notes", "Draft [old]", "This | that", "", "   "] { #expect(!WikiLinks.linkable(title)) }
    }

    @Test("Two docs with one title: the one in the same folder wins, then the newer")
    func resolve() {
        let folder = UUID()
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        let nearby = ReaderItem(id: UUID(), kind: .note, title: "Witches and prophecy", collection: nil, mime: MarkdownText.mime, byteCount: 0,
                                createdAt: old, updatedAt: old, listenPosition: 0, folderID: folder)
        let newer = ReaderItem(id: UUID(), kind: .note, title: "witches and prophecy", collection: nil, mime: MarkdownText.mime, byteCount: 0,
                               createdAt: old, updatedAt: old.addingTimeInterval(60), listenPosition: 0)
        let file = ReaderItem(id: UUID(), kind: .file, title: "Witches and prophecy", collection: nil, mime: "application/pdf", byteCount: 0,
                              createdAt: old, updatedAt: old.addingTimeInterval(120), listenPosition: 0)
        let items = [nearby, newer, file]
        #expect(WikiLinks.resolve("Witches and prophecy", in: items, near: folder)?.id == nearby.id)
        #expect(WikiLinks.resolve("Witches and prophecy", in: items, near: nil)?.id == newer.id)
        #expect(WikiLinks.resolve("Banquo", in: items, near: nil) == nil)
    }

    @Test("A followed link reaches Swift only as a title and heading it could name")
    func message() {
        #expect(WritingMessage.parse(["type": "wiki", "target": " Witches and prophecy ", "heading": "Act one"])
            == .wiki(target: "Witches and prophecy", heading: "Act one"))
        #expect(WritingMessage.parse(["type": "wiki", "target": "Witches and prophecy"]) == .wiki(target: "Witches and prophecy", heading: ""))
        for bad: [String: Any] in [
            ["type": "wiki", "target": ""],
            ["type": "wiki", "target": "a]]b"],
            ["type": "wiki", "target": "C#"],
            ["type": "wiki", "target": 42],
            ["type": "wiki", "target": String(repeating: "x", count: 201)],
            ["type": "wiki", "target": "Witches", "heading": "x\ny"],
        ] {
            #expect(WritingMessage.parse(bad) == nil)
        }
    }
}

@Suite struct BacklinkTests {
    @Test("Backlinks list the docs that link here, with the words around the link, and skip code")
    func backlinks() async throws {
        let vault = try newVault()
        let target = try await vault.createNote(title: "The Tragic Hero in Macbeth")
        try await vault.saveNote(target.id, title: target.title, body: essay, mime: MarkdownText.mime)
        let source = try await vault.createNote(title: "Act one notes")
        try await vault.saveNote(source.id, title: source.title, body: notes, mime: MarkdownText.mime)
        let unrelated = try await vault.createNote(title: "Banquo")
        try await vault.saveNote(unrelated.id, title: unrelated.title, body: "Only `[[The Tragic Hero in Macbeth]]` in code.", mime: MarkdownText.mime)

        let links = try await vault.backlinks(to: target.id)
        #expect(links.map(\.item.id) == [source.id])
        #expect(links.first?.count == 1)
        #expect(links.first?.snippet == "The letter scene is argued in the essay, and the witches get")
        #expect(try await vault.backlinks(to: unrelated.id).isEmpty)
    }

    @Test("A link leads to the doc it resolves to, so a same-named doc elsewhere gets no backlink")
    func sameTitle() async throws {
        let vault = try newVault()
        let thesis = try await vault.createFolder(title: "Thesis")
        let near = try await vault.createNote(title: "Method", folder: thesis.id)
        let far = try await vault.createNote(title: "Method")
        let chapter = try await vault.createNote(title: "Chapter one", folder: thesis.id)
        try await vault.saveNote(chapter.id, title: chapter.title, body: "As [[Method]] explains.", mime: MarkdownText.mime)
        #expect(try await vault.backlinks(to: near.id).map(\.item.id) == [chapter.id])
        #expect(try await vault.backlinks(to: far.id).isEmpty)
    }
}

@Suite struct DocVersionTests {
    private func doc(_ vault: ReaderVault, _ body: String) async throws -> ReaderItem {
        let item = try await vault.createNote(title: "The Tragic Hero in Macbeth")
        try await vault.saveNote(item.id, title: item.title, body: body, mime: MarkdownText.mime)
        return item
    }

    @Test("A snapshot keeps the saved words once, and an unchanged doc adds none")
    func snapshot() async throws {
        let vault = try newVault()
        let item = try await doc(vault, essay)
        let first = try #require(try await vault.snapshot(item.id))
        #expect(try await vault.snapshot(item.id) == nil)
        #expect(first.words == 22)
        #expect(first.title == "The Tragic Hero in Macbeth")
        #expect(try await vault.versionText(first.id, of: item.id) == essay)

        try await vault.saveNote(item.id, title: item.title, body: essay + "\nThe cost comes in act five.", mime: MarkdownText.mime)
        try await vault.snapshot(item.id)
        #expect(try await vault.versions(of: item.id).count == 2)
        let empty = try await vault.createNote(title: "Empty")
        #expect(try await vault.snapshot(empty.id) == nil)
    }

    @Test("Restoring puts the words back and keeps what was there as a version")
    func restore() async throws {
        let vault = try newVault()
        let item = try await doc(vault, essay)
        let original = try #require(try await vault.snapshot(item.id))
        try await vault.saveNote(item.id, title: "Macbeth, revised", body: "A shorter draft.", mime: MarkdownText.mime)

        let restored = try await vault.restoreVersion(original.id, of: item.id)
        #expect(restored.title == "Macbeth, revised", "the title stays, so links keep working")
        #expect(String(decoding: try await vault.body(of: item.id), as: UTF8.self) == essay)
        let versions = try await vault.versions(of: item.id)
        #expect(versions.count == 2)
        #expect(try await vault.versionText(versions[0].id, of: item.id) == "A shorter draft.")
    }

    @Test("A version opens only through its own doc")
    func ownDocOnly() async throws {
        let vault = try newVault()
        let essayDoc = try await doc(vault, essay)
        let other = try await doc(vault, notes)
        let version = try #require(try await vault.snapshot(essayDoc.id))
        await #expect(throws: ReaderError.notFound) { try await vault.versionText(version.id, of: other.id) }
        await #expect(throws: ReaderError.notFound) { try await vault.restoreVersion(version.id, of: other.id) }
    }

    @Test("Recent versions all stay, older ones thin out, and there's a limit")
    func thinning() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // One every ten minutes for two days, then one an hour for sixty days.
        let recent = (0..<288).map { now.addingTimeInterval(-Double($0) * 600) }
        let older = (0..<(60 * 24)).map { now.addingTimeInterval(-2 * 86400 - Double($0) * 3600) }
        let versions = (recent + older).map { DocVersion(id: UUID(), savedAt: $0, title: "Draft", words: 1, byteCount: 1) }
        let kept = DocVersions.thinned(versions.shuffled(), now: now)
        // 20 recent, one an hour for the rest of the day, one a day to a month, one a week after.
        #expect(kept.count == 76)
        #expect(kept.prefix(DocVersions.allRecent).map(\.savedAt) == Array(recent.prefix(DocVersions.allRecent)))
        #expect(kept.map(\.savedAt) == kept.map(\.savedAt).sorted(by: >))
        let lastHour = kept.filter { now.timeIntervalSince($0.savedAt) < 3600 }
        #expect(lastHour.count == 6)

        let weekly = (0..<300).map { DocVersion(id: UUID(), savedAt: now.addingTimeInterval(-Double($0) * 7 * 86400), title: "Draft", words: 1, byteCount: 1) }
        #expect(DocVersions.thinned(weekly, now: now).count == DocVersions.mostKept)
    }

    @Test("Versions are sealed, move with the key, stay through Recently Deleted, and go with the doc")
    func lifecycle() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let item = try await doc(vault, essay)
        try await vault.snapshot(item.id)
        for name in try store.names() {
            #expect(ReaderVault.sealedPurposes.keys.contains { name.hasSuffix($0) }, "\(name)")
            #expect(!String(decoding: try #require(try store.read(name)), as: UTF8.self).contains("letter"))
        }
        #expect(try await vault.sealedObjectIDs() == [item.id], "versions never sync")

        try await vault.delete(item.id)
        try await vault.restore(item.id)
        #expect(try await vault.versions(of: item.id).count == 1)

        try await vault.delete(item.id)
        try await vault.deleteForever(item.id)
        #expect(try store.names().filter { $0.hasSuffix(".version") || $0.hasSuffix(".versions") }.isEmpty)
    }

    @Test("A file held from outside, like Drive's, keeps no versions here")
    func heldFiles() async throws {
        let vault = try newVault()
        let now = Date()
        let drive = ReaderItem(id: UUID(), kind: .note, title: "Shared outline", collection: nil, mime: MarkdownText.mime, byteCount: 5,
                               createdAt: now, updatedAt: now, listenPosition: 0)
        try await vault.hold(drive, body: Data("Draft".utf8))
        #expect(try await vault.snapshot(drive.id) == nil)
        #expect(try await vault.versions(of: drive.id).isEmpty)
    }
}

@Suite struct LinksAndVersionsTwoUserTests {
    @Test("User 2 can't open user 1's versions or see user 1's docs through links")
    func staysPrivate() async throws {
        let store = MemoryBlobStore()
        let user1 = try newVault(store: store)
        let target = try await user1.createNote(title: "The Tragic Hero in Macbeth")
        try await user1.saveNote(target.id, title: target.title, body: essay, mime: MarkdownText.mime)
        let source = try await user1.createNote(title: "Act one notes")
        try await user1.saveNote(source.id, title: source.title, body: notes, mime: MarkdownText.mime)
        let version = try #require(try await user1.snapshot(target.id))

        let user2 = ReaderVault(store: store, rootKey: try .generate())
        await #expect(throws: CryptoError.authenticationFailed) { try await user2.versions(of: target.id) }
        await #expect(throws: (any Error).self) { try await user2.versionText(version.id, of: target.id) }
        await #expect(throws: (any Error).self) { try await user2.restoreVersion(version.id, of: target.id) }
        await #expect(throws: (any Error).self) { try await user2.backlinks(to: target.id) }
        // User 2's own doc with the same title gets nothing from user 1's links.
        let own = try await user2.createNote(title: "The Tragic Hero in Macbeth")
        #expect(try await user2.backlinks(to: own.id).isEmpty)
    }
}

#if os(macOS)
/// Wiki links in the real page.
@MainActor
@Suite(.serialized) struct WritingLinksWebTests {
    private let page = """
    # Act one notes

    The letter scene is argued in [[The Tragic Hero in Macbeth#The letter|the essay]]. The witches
    need [[Witches and prophecy]], which isn't written yet.

    ## Later

    Back to [[#Act one notes]].
    """

    private func readyEditor(_ text: String, docs: [String]) async throws -> WritingEditorController {
        let rules = WritingRules(directory: FileManager.default.temporaryDirectory.appendingPathComponent("WritingRulesTests-\(UUID())"))
        let editor = WritingEditorController(rules: rules)
        await editor.start()
        try #require(editor.webView).frame = CGRect(x: 0, y: 0, width: 600, height: 900)
        editor.load(text, settings: WritingSettings(), docs: docs)
        for _ in 0..<200 where editor.phase != .ready || editor.outline.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(editor.phase == .ready)
        return editor
    }

    private func script(_ editor: WritingEditorController, _ source: String) async throws -> Any? {
        try await #require(editor.webView).callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test("Links read as their words, and one to a doc that isn't there yet reads differently")
    func rendering() async throws {
        let editor = try await readyEditor(page, docs: ["The Tragic Hero in Macbeth"])
        let links = try await script(editor, "return [...document.querySelectorAll('.cm-tl-wiki')].map(e => [e.textContent, e.classList.contains('cm-tl-wiki-missing')])") as? [[Any]]
        #expect(links?.map { $0[0] as? String } == ["the essay", "Witches and prophecy", "Act one notes"])
        #expect(links?.map { $0[1] as? Bool } == [false, true, false])

        editor.useDocs(["The Tragic Hero in Macbeth", "Witches and prophecy"])
        try await Task.sleep(for: .milliseconds(200))
        let missing = try await script(editor, "return document.querySelectorAll('.cm-tl-wiki-missing').length") as? Int
        #expect(missing == 0)
    }

    @Test("Tapping a link to another doc tells Swift its title and heading, and a heading here jumps")
    func following() async throws {
        let editor = try await readyEditor(page, docs: ["The Tragic Hero in Macbeth"])
        var followed: [(String, String)] = []
        editor.onWikiLink = { followed.append(($0, $1)) }
        _ = try await script(editor, "document.querySelectorAll('.cm-tl-wiki')[0].click()")
        for _ in 0..<100 where followed.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(followed.map { $0.0 } == ["The Tragic Hero in Macbeth"])
        #expect(followed.map { $0.1 } == ["The letter"])

        #expect(await editor.call("goToHeading", "later") as? Bool == true)
        #expect(await editor.call("goToHeading", "Banquo") as? Bool == false)
        _ = try await script(editor, "document.querySelectorAll('.cm-tl-wiki')[2].click()")
        try await Task.sleep(for: .milliseconds(100))
        #expect(followed.count == 1, "a heading in this doc doesn't leave it")
    }

    @Test("Inserting a link uses the title, a selection becomes its words, and a bad title is refused")
    func inserting() async throws {
        let editor = try await readyEditor("Witches.", docs: [])
        _ = await editor.call("jump", 0)
        #expect(await editor.call("wikilink", "Witches and prophecy") as? Bool == true)
        let reply = try await script(editor, "return window.totality.text()") as? [String: Any]
        #expect((reply?["text"] as? String)?.hasPrefix("[[Witches and prophecy]]") == true)
        #expect(await editor.call("wikilink", "a]]<img src=x>") as? Bool == false)
        #expect(await editor.call("wikilink", 42) as? Bool == false)
    }

    /// Writes the page with its links to a PNG for a person to look at, when TOTALITY_RENDER_DIR is set.
    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let editor = try await readyEditor(page, docs: ["The Tragic Hero in Macbeth"])
        let webView = try #require(editor.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 393, height: 500)
        try await Task.sleep(for: .milliseconds(300))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = try await webView.takeSnapshot(configuration: configuration)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("writing-links-page.png"))
    }
}
#endif

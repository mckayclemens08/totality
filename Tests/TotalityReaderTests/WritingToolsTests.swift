import Foundation
import Testing
import TotalityCore
import WebKit
@testable import TotalityReader

@Suite struct WritingToolsTests {
    @Test("Counts, the outline and find results are read strictly")
    func messages() {
        #expect(WritingMessage.parse(["type": "stats", "stats": ["words": 1204, "selection": 12, "section": 312, "characters": 7000]])
            == .stats({ var s = WritingStats(); s.words = 1204; s.selection = 12; s.section = 312; s.characters = 7000; return s }()))
        #expect(WritingMessage.parse(["type": "stats", "stats": ["words": -5]]) == .stats(WritingStats()))
        let outline = WritingMessage.parse(["type": "outline", "headings": [
            ["level": 1, "text": "Chapter One: The Harbour", "from": 0],
            ["level": 9, "text": "Too deep", "from": 40],
            ["level": 2, "text": "The letter", "from": -1],
            ["level": 2, "text": "The crossing", "from": 120],
        ]])
        #expect(outline == .outline([
            WritingHeading(level: 1, text: "Chapter One: The Harbour", from: 0),
            WritingHeading(level: 2, text: "The crossing", from: 120),
        ]))
        #expect(WritingMessage.parse(["type": "find"]) == .find)
        #expect(WritingMessage.parse(["type": "matches", "count": 3, "current": 7]) == .matches(WritingMatches(count: 3, current: 3)))
    }

    @Test("The counts line says what a writer wants to know")
    func countsLine() {
        var stats = WritingStats()
        stats.words = 1204
        stats.section = 312
        #expect(WritingCountsLine.summary(stats, docTarget: nil) == "1,204 words · section 312")
        stats.selection = 12
        #expect(WritingCountsLine.summary(stats, docTarget: 80_000) == "1,204 of 80,000 words · section 312 · 12 selected")
        #expect(WritingCountsLine.summary(WritingStats(), docTarget: nil) == "0 words")
    }

    @Test("The find bar says where it is among the matches")
    func findPosition() {
        #expect(WritingFindBar.position(WritingMatches(), hasQuery: false) == "")
        #expect(WritingFindBar.position(WritingMatches(), hasQuery: true) == "None")
        #expect(WritingFindBar.position(WritingMatches(count: 1, current: 0), hasQuery: true) == "1 match")
        #expect(WritingFindBar.position(WritingMatches(count: 12, current: 0), hasQuery: true) == "12 matches")
        #expect(WritingFindBar.position(WritingMatches(count: 12, current: 3), hasQuery: true) == "3 of 12")
    }

    @Test("Today's words add up, start again tomorrow, and survive a relaunch")
    func dailyGoal() throws {
        let defaults = try #require(UserDefaults(suiteName: "WritingGoalsTests-\(UUID())"))
        let morning = Date(timeIntervalSince1970: 1_794_550_000)
        var goals = WritingGoals.load(from: defaults, now: morning)
        #expect(goals.written == 0)
        goals.dailyTarget = 500
        goals.add(120, now: morning)
        goals.add(-30, now: morning)
        goals.save(to: defaults)
        let later = WritingGoals.load(from: defaults, now: morning.addingTimeInterval(60))
        #expect(later.written == 120)
        #expect(later.dailyTarget == 500)
        #expect(WritingGoals.progress(later.written, of: later.dailyTarget) == 0.24)
        let tomorrow = morning.addingTimeInterval(36 * 60 * 60)
        #expect(WritingGoals.load(from: defaults, now: tomorrow).written == 0)
        var carried = later
        carried.add(10, now: tomorrow)
        #expect(carried.written == 10)
        #expect(WritingGoals.progress(10, of: 0) == nil)
        #expect(WritingGoals.progress(900, of: 500) == 1)
    }

    @Test("A doc's word target is sealed with it, leaves its date alone, and only docs have one")
    func wordTarget() async throws {
        let vault = try newVault()
        let note = try await vault.createNote(title: "Thesis")
        try await vault.setWordTarget(80_000, of: note.id)
        let stored = try await vault.item(note.id)
        #expect(stored.wordTarget == 80_000)
        #expect(stored.updatedAt == note.updatedAt)
        try await vault.setWordTarget(0, of: note.id)
        #expect(try await vault.item(note.id).wordTarget == nil)
        try await vault.setWordTarget(99_999_999, of: note.id)
        #expect(try await vault.item(note.id).wordTarget == 10_000_000)
        let file = try await vault.importFile(Data("Notes".utf8), filename: "notes.txt")
        await #expect(throws: ReaderError.notANote) { try await vault.setWordTarget(500, of: file.id) }
    }
}

/// User 2 can't read user 1's targets, and a share carries none of them.
@Suite struct WritingToolsTwoUserTests {
    @Test("A word target is sealed: user 2 can't open it, and a share leaves it out")
    func targetsStayPrivate() async throws {
        let store = MemoryBlobStore()
        let user1 = try newVault(store: store)
        let note = try await user1.createNote(title: "Novel draft")
        try await user1.setWordTarget(90_000, of: note.id)

        let user2 = ReaderVault(store: store, rootKey: try .generate())
        await #expect(throws: CryptoError.authenticationFailed) { try await user2.item(note.id) }
        for name in try store.names() {
            let blob = try #require(try store.read(name))
            #expect(blob.range(of: Data("wordTarget".utf8)) == nil, "\(name)")
        }

        let grantee = try IdentityKeys.generate()
        let share = try await user1.share(note.id, with: grantee.bundle())
        let header = try ContentCipher.open(share.sealedHeader, key: grantee.open(share.wrappedKey), objectID: note.id)
        #expect(String(decoding: header, as: UTF8.self).contains("wordTarget") == false)
    }
}

#if os(macOS)
/// The tools in the real page.
@MainActor
@Suite(.serialized) struct WritingToolsWebTests {
    private let chapter = """
    # Chapter One: The Harbour

    The fog came in off the Solent before dawn, and the harbour lamp was still lit.

    ## The letter

    She read the letter twice. The letter was dated the ninth of March.

    ## The crossing

    Nobody spoke on the ferry.
    """

    private func readyEditor(_ text: String, settings: WritingSettings = WritingSettings()) async throws -> WritingEditorController {
        let rules = WritingRules(directory: FileManager.default.temporaryDirectory.appendingPathComponent("WritingRulesTests-\(UUID())"))
        let editor = WritingEditorController(rules: rules)
        await editor.start()
        try #require(editor.webView).frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        editor.load(text, settings: settings)
        for _ in 0..<200 where editor.phase != .ready || editor.outline.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(editor.phase == .ready)
        return editor
    }

    @Test("Counts and the outline arrive when a doc opens")
    func countsAndOutline() async throws {
        let editor = try await readyEditor(chapter)
        #expect(editor.outline.map(\.text) == ["Chapter One: The Harbour", "The letter", "The crossing"])
        #expect(editor.outline.map(\.level) == [1, 2, 2])
        #expect(editor.stats.words == 42)
    }

    @Test("Find counts matches, steps through them, and replaces them all")
    func findAndReplace() async throws {
        let editor = try await readyEditor(chapter)
        await editor.find("letter")
        #expect(editor.matches.count == 3)
        await editor.findStep("findNext")
        #expect(editor.matches.current == 1)
        await editor.find("letter", replacement: "note")
        await editor.findStep("replaceAll")
        #expect(editor.matches.count == 0)
        await editor.flush()
        #expect(editor.text.contains("She read the note twice. The note was dated"))
        #expect(editor.text.contains("## The note"))
        editor.closeFind()
    }

    @Test("A heading folds its section, and jumping into it unfolds it")
    func folding() async throws {
        let editor = try await readyEditor(chapter)
        let letter = try #require(editor.outline.first { $0.text == "The letter" })
        #expect(await editor.call("fold", letter.from) as? Bool == true)
        let webView = try #require(editor.webView)
        let shown = try await webView.callAsyncJavaScript("return document.querySelector('.cm-content').innerText", arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(shown?.contains("She read") == false)
        _ = await editor.call("jump", (chapter as NSString).range(of: "She read").location)
        let after = try await webView.callAsyncJavaScript("return document.querySelector('.cm-content').innerText", arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(after?.contains("She read") == true)
        // Folding never changes the text.
        await editor.flush()
        #expect(editor.text == chapter)
    }

    @Test("Focus mode dims the other paragraphs, and turning it off brings them back")
    func focusMode() async throws {
        let editor = try await readyEditor(chapter, settings: WritingSettings(focus: true))
        let webView = try #require(editor.webView)
        let count = { try await webView.callAsyncJavaScript("return document.querySelectorAll('.cm-tl-dim').length", arguments: [:], in: nil, contentWorld: .page) as? Int }
        #expect(try await count() ?? 0 > 0)
        editor.apply(WritingSettings(focus: false))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await count() == 0)
    }
}
#endif

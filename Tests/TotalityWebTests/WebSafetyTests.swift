import Foundation
import Testing
import TotalityCore
import WebKit
@testable import TotalityWeb

@MainActor
@Suite struct WebBlockingTests {
    private func listFile() throws -> URL {
        try #require(Bundle.module(named: "blocklist"))
    }

    private func store() -> WKContentRuleListStore {
        WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    @Test("The list that ships is only whole-site block rules, within WebKit's limit")
    func shippedList() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: listFile())) as? [[String: Any]])
        #expect(rules.count > 50_000)
        #expect(rules.count < 120_000)
        let shape = /\^\[\^:\]\+:\/\/\+\(\[\^:\/\]\+\\\.\)\?[a-z0-9\\.-]+\[:\/\]/
        for rule in rules {
            #expect((rule["action"] as? [String: String]) == ["type": "block"])
            let filter = try #require((rule["trigger"] as? [String: Any])?["url-filter"] as? String)
            #expect(filter.wholeMatch(of: shape) != nil)
        }
    }

    @Test("WebKit compiles the shipped list, and the second launch doesn't compile again")
    func compiles() async throws {
        let store = store()
        let encoded = String(decoding: try Data(contentsOf: listFile()), as: UTF8.self)
        let first = WebBlocker(store: store)
        await first.prepare(encoded: encoded, identifier: "list-a")
        #expect(first.rules != nil)
        let second = WebBlocker(store: store)
        await second.prepare(encoded: "not a list", identifier: "list-a")
        #expect(second.rules != nil)
    }

    @Test("A broken list leaves pages working, unblocked")
    func brokenList() async {
        let blocker = WebBlocker(store: store())
        await blocker.prepare(encoded: "not a list", identifier: "list-b")
        #expect(blocker.rules == nil)
    }

    @Test("Blocking turns off for one site and comes back, and the choice is sealed")
    func perSite() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let vault = WebVault(store: store, rootKey: key)
        let model = WebModel(client: nil, vault: vault)
        await model.use(account: "user-1")
        let site = URL(string: "https://www.lisbon.example/trams")!
        #expect(model.isBlocking(site))
        model.setBlocking(false, for: "lisbon.example")
        #expect(!model.isBlocking(site))
        #expect(model.isBlocking(URL(string: "https://porto.example")))
        #expect(model.unblockedSites == ["lisbon.example"])
        for _ in 0..<200 where try await vault.settings(for: "user-1").unblockedSites.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let reopened = WebModel(client: nil, vault: WebVault(store: store, rootKey: key))
        await reopened.use(account: "user-1")
        #expect(!reopened.isBlocking(site))
        for name in try store.names() {
            #expect(!String(decoding: try #require(try store.read(name)), as: UTF8.self).contains("lisbon"))
        }
    }

    @Test("Rules come off a page only on a site that's turned off")
    func rulesFollowTheSite() async throws {
        let blocker = WebBlocker(store: store())
        let rule = #"[{"trigger":{"url-filter":"tracker"},"action":{"type":"block"}}]"#
        await blocker.prepare(encoded: rule, identifier: "list-c")
        let rules = try #require(blocker.rules)
        let page = WebPage(configuration: WebPage.configuration(isPrivate: false, store: .nonPersistent()), isPrivate: false)
        page.isUnblocked = { $0 == "lisbon.example" }
        page.rules = rules
        #expect(page.blockingIsOn)
        page.applyRules(for: URL(string: "https://www.lisbon.example"))
        #expect(!page.blockingIsOn)
        page.applyRules(for: URL(string: "https://porto.example"))
        #expect(page.blockingIsOn)
    }
}

@MainActor
@Suite struct WebDownloadTests {
    @Test("A site can't pick a name that reaches out of the folder", arguments: [
        ("../../secrets.txt", "secrets.txt"),
        ("..\\..\\boot.ini", "boot.ini"),
        ("/etc/passwd", "passwd"),
        (".hidden", "hidden"),
        ("report\u{0}.pdf", "report.pdf"),
        ("a:b*c?.pdf", "abc.pdf"),
        ("..", "Download"),
        ("", "Download"),
    ])
    func names(suggested: String, safe: String) {
        #expect(WebDownloadFolder.safeName(suggested) == safe)
    }

    @Test("A long name is cut and keeps its type")
    func longName() {
        let name = WebDownloadFolder.safeName(String(repeating: "a", count: 400) + ".pdf")
        #expect(name.count == WebDownloadFolder.nameLimit)
        #expect(name.hasSuffix(".pdf"))
    }

    @Test("A second file with the same name doesn't overwrite the first")
    func uniqueNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = WebDownloadFolder(directory: directory)
        let first = try folder.destination(for: "tram.pdf")
        try Data("one".utf8).write(to: first)
        #expect(try folder.destination(for: "tram.pdf").lastPathComponent == "tram 2.pdf")
        #expect(folder.existing().map(\.lastPathComponent) == ["tram.pdf"])
    }

    @Test("Each account has its own downloads")
    func perAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let mine = root.appendingPathComponent(WebVault.siteID(for: "user-1").uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: mine.appendingPathComponent("tram.pdf"))

        let model = WebModel(client: nil, vault: WebVault(store: store, rootKey: key), downloads: root)
        await model.use(account: "user-1")
        #expect(model.downloads.map(\.filename) == ["tram.pdf"])
        await model.use(account: nil)
        #expect(model.downloads.isEmpty)
        await model.use(account: "user-1")
        #expect(model.downloads.map(\.filename) == ["tram.pdf"])
        await model.use(account: "user-2")
        #expect(model.downloads.isEmpty)
    }

    @Test("Downloads stay out of the device's backups")
    func outOfBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try WebDownloadFolder(directory: directory).destination(for: "tram.pdf")
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("Removing a download removes the file")
    func removal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WebVault(store: MemoryBlobStore(), rootKey: try .generate())
        let mine = root.appendingPathComponent(WebVault.siteID(for: "user-1").uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let file = mine.appendingPathComponent("tram.pdf")
        try Data("one".utf8).write(to: file)
        let model = WebModel(client: nil, vault: vault, downloads: root)
        await model.use(account: "user-1")
        model.remove(try #require(model.downloads.first))
        #expect(model.downloads.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

/// Stands in for the Reader, the way a real one is reached: through `ContentReceiver`.
private actor FakeReader: ContentReceiver {
    nonisolated let module = ModuleID.reader
    nonisolated let kinds: Set<ContentKind> = [.note, .file]
    private(set) var notes: [(title: String, body: String)] = []
    private(set) var files: [(data: Data, name: String)] = []
    var refuses = false

    func refuse() { refuses = true }

    private func ref(_ kind: ContentKind, _ title: String) -> ContentRef {
        let id = UUID()
        return ContentRef(module: .reader, kind: kind, id: id, keyRef: .crk(objectID: id), preview: .init(title: title))
    }

    func receive(noteTitled title: String, body: String) throws -> ContentRef {
        if refuses { throw CancellationError() }
        notes.append((title, body))
        return ref(.note, title)
    }

    func receive(file data: Data, named filename: String) throws -> ContentRef {
        if refuses { throw CancellationError() }
        files.append((data, filename))
        return ref(.file, filename)
    }
}

@MainActor
@Suite(.serialized) struct WebReadableTests {
    private let html = """
    <html><head><title>Tram 28</title></head><body>
    <nav><ul><li>Home link</li></ul></nav>
    <article>
      <h1>Riding tram 28</h1>
      <p>The yellow tram climbs through Alfama, and the first car of the morning leaves Martim Moniz before the crowds arrive at the stops along the hill.</p>
      <p>Validate your card as you board, and hold on through the sharp turns near the cathedral, where the rails squeal and the driver rings the bell.</p>
      <form><p>Newsletter sign-up</p><input id="box" value="typed by the person"><textarea id="note">typed in a note</textarea></form>
      <p style="display:none">Hidden line</p>
    </article>
    <footer><p>Footer line</p></footer>
    </body></html>
    """

    private func loaded(_ html: String) async throws -> WebPage {
        let page = WebPage(configuration: WebPage.configuration(isPrivate: true, store: .nonPersistent()), isPrivate: true)
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://lisbon.example/trams"))
        try await until { !page.webView.isLoading && page.webView.title?.isEmpty == false }
        return page
    }

    @Test("Saving keeps the article and drops navigation, forms, and hidden text")
    func cleans() async throws {
        let page = try await loaded(html)
        let text = try await page.readableText()
        #expect(text.body.hasPrefix("Riding tram 28\n\nThe yellow tram"))
        #expect(text.body.contains("Validate your card"))
        for dropped in ["Home link", "Newsletter", "Hidden line", "Footer line"] {
            #expect(!text.body.contains(dropped))
        }
    }

    @Test("Nothing typed into a page is read, even on a short page")
    func typedTextStays() async throws {
        let page = try await loaded(#"<html><head><title>Sign in</title></head><body><p>Hello</p><input id="box"><textarea id="note"></textarea></body></html>"#)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('box').value = 'secret one'; document.getElementById('note').value = 'secret two'; 1")
        let text = try await page.readableText()
        #expect(text.body == "Hello")
    }

    @Test("Text in an editable area isn't read, on a long page or a short one")
    func editableAreasStay() async throws {
        let filler = String(repeating: "The yellow tram climbs through Alfama before the crowds arrive. ", count: 5)
        for body in ["<p>\(filler)</p><p contenteditable>my draft</p>", "<p>Hello</p><div contenteditable>my draft</div>", "<div contenteditable><p>\(filler)</p><p>my draft</p></div>"] {
            let page = try await loaded("<html><head><title>Draft</title></head><body>\(body)</body></html>")
            #expect(try await !page.readableText().body.contains("my draft"))
        }
    }

    @Test("A page's own script can't see or change the reader")
    func pageCantInterfere() async throws {
        let page = try await loaded("""
        <html><head><title>Sly</title><script>
        Element.prototype.querySelectorAll = () => { throw new Error('caught') };
        Document.prototype.querySelector = () => { window.saw = true; return null };
        </script></head><body><p>Plain words</p></body></html>
        """)
        let text = try await page.readableText()
        #expect(text.body == "Plain words")
        #expect(try await page.webView.evaluateJavaScript("window.saw === undefined") as? Bool == true)
    }

    @Test("Save to Reader goes through the registry's receiver")
    func saves() async throws {
        let reader = FakeReader()
        let model = WebModel(client: nil, receiver: reader)
        var told = 0
        model.onSentToReader = { told += 1 }
        model.open(URL(string: "https://lisbon.example")!)
        let page = try #require(model.current.page)
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://lisbon.example/trams"))
        try await until { !page.webView.isLoading && page.title == "Tram 28" }
        await model.saveToReader()
        let notes = await reader.notes
        #expect(notes.first?.title == "Tram 28")
        #expect(notes.first?.body.contains("yellow tram") == true)
        #expect(model.notice == "Saved to Reader.")
        #expect(told == 1)
    }

    @Test("A page with no text says so, and a refusal isn't called a save")
    func failures() async throws {
        let reader = FakeReader()
        let model = WebModel(client: nil, receiver: reader)
        model.open(URL(string: "https://lisbon.example")!)
        let page = try #require(model.current.page)
        page.webView.loadHTMLString("<html><head><title>Empty</title></head><body></body></html>", baseURL: nil)
        try await until { !page.webView.isLoading && page.title == "Empty" }
        await model.saveToReader()
        #expect(model.notice == "This page has no text to save.")
        page.webView.loadHTMLString("<html><head><title>Full</title></head><body><p>Words</p></body></html>", baseURL: nil)
        try await until { !page.webView.isLoading && page.title == "Full" }
        await reader.refuse()
        await model.saveToReader()
        #expect(model.notice == "This page wasn't saved.")
    }

    @Test("Find says whether the page has the words, and text size moves in steps")
    func tools() async throws {
        let page = try await loaded(html)
        #expect(await page.find("Alfama"))
        #expect(await !page.find("Porto"))
        page.zoom(in: true)
        #expect(page.webView.pageZoom == 1.1)
        page.zoom(in: false)
        page.zoom(in: false)
        #expect(page.webView.pageZoom == 0.9)
    }
}

/// Through a real page and a real server, because a rule that looks applied can still load too late.
@MainActor
@Suite(.serialized) struct WebLiveTests {
    private let store = WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))!

    private func blocked() async throws -> WKContentRuleList {
        let blocker = WebBlocker(store: store)
        await blocker.prepare(encoded: #"[{"trigger":{"url-filter":"tracker"},"action":{"type":"block"}}]"#, identifier: "live")
        return try #require(blocker.rules)
    }

    private let html = #"<html><head><title>Trams</title></head><body><img src="/tracker.png"><img src="/tram.png"></body></html>"#

    @Test("A blocked resource is never fetched, and turning a site off lets it through")
    func blocking() async throws {
        let site = try LocalSite(pages: ["/": ("text/html", "", html)])
        let page = WebPage(configuration: WebPage.configuration(isPrivate: true, store: .nonPersistent()), isPrivate: true)
        var off = false
        page.isUnblocked = { _ in off }
        page.rules = try await blocked()

        page.load(try await site.url("/"))
        try await until { !page.isLoading && page.title == "Trams" && site.requested.contains("/tram.png") }
        #expect(!site.requested.contains("/tracker.png"))

        off = true
        page.reload()
        try await until { site.requested.contains("/tracker.png") }
    }

    private func downloadModel(_ root: URL) async throws -> WebModel {
        let model = WebModel(client: nil, vault: WebVault(store: MemoryBlobStore(), rootKey: try .generate()), downloads: root)
        await model.use(account: "user-1")
        return model
    }

    private let file: (type: String, extra: String, body: String) = ("application/octet-stream", "Content-Disposition: attachment; filename=\"../../tram.bin\"\r\n", "tram timetable")

    @Test("A download asks first, then lands in the folder under a safe name")
    func download() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = try LocalSite(pages: ["/file": file])
        let model = try await downloadModel(root)
        model.open(try await site.url("/file"))
        let page = try #require(model.current.page)
        try await until { page.dialog != nil }
        #expect(model.downloads.isEmpty)
        #expect(page.dialog?.message.hasSuffix("tram.bin?") == true)
        page.answer(try #require(page.dialog), true)
        try await until { model.downloads.first?.state == .finished }
        let done = try #require(model.downloads.first)
        // WebKit cleans the name before we see it, and `safeName` is checked on its own above.
        #expect(done.filename.hasSuffix("tram.bin"))
        #expect(!done.filename.contains("/"))
        #expect(try String(contentsOf: done.file, encoding: .utf8) == "tram timetable")
        #expect(done.file.path.hasPrefix(root.path) || done.file.standardizedFileURL.path.contains(root.lastPathComponent))
    }

    @Test("Saying no to a download writes nothing")
    func refusedDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = try LocalSite(pages: ["/file": file])
        let model = try await downloadModel(root)
        model.open(try await site.url("/file"))
        let page = try #require(model.current.page)
        try await until { page.dialog != nil }
        page.answer(try #require(page.dialog), false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.downloads.isEmpty)
        let written = FileManager.default.subpaths(atPath: root.path) ?? []
        #expect(!written.contains { $0.contains("tram") })
    }

    private func stalledPage() async throws -> (page: WebPage, shown: URL, stalled: URL, site: LocalSite) {
        let site = try LocalSite(pages: ["/": ("text/html", "", "<html><head><title>Sign in</title></head><body>Hi</body></html>")], silent: ["/stalled"])
        let page = WebPage(configuration: WebPage.configuration(isPrivate: false, store: .nonPersistent()), isPrivate: false)
        let shown = try await site.url("/")
        page.load(shown)
        try await until { !page.isLoading && page.title == "Sign in" }
        var other = try #require(URLComponents(url: try await site.url("/stalled"), resolvingAgainstBaseURL: false))
        other.host = "localhost"
        return (page, shown, try #require(other.url), site)
    }

    @Test("A site's name doesn't show until that site has answered")
    func addressWaitsForTheSite() async throws {
        let (page, shown, stalled, site) = try await stalledPage()
        _ = try await page.webView.evaluateJavaScript("location = '\(stalled.absoluteString)'; 1")
        try await until { site.requested.contains("/stalled") && page.webView.url == stalled }
        #expect(page.url == shown)

        // A dialog can't borrow the name either.
        Task { _ = try? await page.webView.evaluateJavaScript("alert('Enter your password'); 1") }
        try await until { page.dialog != nil }
        #expect(page.dialog?.site == shown.host())
        page.answer(try #require(page.dialog), true)
        page.stop()
    }

    @Test("Where the person asked to go shows at once, a page's dialog keeps its own name, and stopping goes back")
    func askedForAddressShows() async throws {
        let (page, shown, stalled, site) = try await stalledPage()
        page.load(stalled)
        #expect(page.url == stalled)
        try await until { site.requested.contains("/stalled") }
        #expect(page.url == stalled)
        Task { _ = try? await page.webView.evaluateJavaScript("alert('Enter your password'); 1") }
        try await until { page.dialog != nil }
        #expect(page.dialog?.site == shown.host())
        page.answer(try #require(page.dialog), true)
        page.stop()
        try await until { page.url == shown }
    }

    @Test("Changes inside a page still show, and a page that does load takes over")
    func addressFollowsThePage() async throws {
        let site = try LocalSite(pages: [
            "/": ("text/html", "", "<html><head><title>One</title></head><body>Hi</body></html>"),
            "/two": ("text/html", "", "<html><head><title>Two</title></head><body>Hi</body></html>"),
        ])
        let page = WebPage(configuration: WebPage.configuration(isPrivate: false, store: .nonPersistent()), isPrivate: false)
        page.load(try await site.url("/"))
        try await until { !page.isLoading && page.title == "One" }
        _ = try await page.webView.evaluateJavaScript("history.pushState({}, '', '/moved'); 1")
        try await until { page.url?.path() == "/moved" }
        _ = try await page.webView.evaluateJavaScript("location.hash = 'lower'; 1")
        try await until { page.url?.fragment() == "lower" }
        _ = try await page.webView.evaluateJavaScript("location = '/two'; 1")
        try await until { page.url?.path() == "/two" && page.title == "Two" }
    }

    @Test("A page can't start a tab by itself, and a plain address shows as not secure")
    func popups() async throws {
        let html = #"<html><head><title>Popup</title><script>window.open('/other')</script></head><body>Hi</body></html>"#
        let site = try LocalSite(pages: ["/": ("text/html", "", html)])
        let model = try await downloadModel(FileManager.default.temporaryDirectory)
        model.open(try await site.url("/"))
        let page = try #require(model.current.page)
        try await until { !page.isLoading && page.title == "Popup" }
        #expect(model.tabs.count == 1)
        #expect(!page.isSecure)
    }
}

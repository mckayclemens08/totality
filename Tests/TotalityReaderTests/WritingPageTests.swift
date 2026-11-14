import Foundation
import Testing
import WebKit
@testable import TotalityReader

@Suite struct WritingPageTests {
    @Test("The bundled page is there and never closes its own script tag")
    func bundled() throws {
        let resources = try #require(WritingPage.resources())
        #expect(resources.script.count > 100_000)
        #expect(!resources.script.contains("</script"))
        #expect(resources.style.contains("--tl-accent"))
    }

    @Test("The bundle has no way to reach the network or keep anything")
    func bundleHasNoNetworkCode() throws {
        let script = try #require(WritingPage.resources()).script
        for api in ["fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "localStorage", "indexedDB", "document.cookie"] {
            #expect(!script.contains(api), "\(api)")
        }
    }

    @Test("Only the bundled script may run, and nothing may load")
    func policy() throws {
        let script = try #require(WritingPage.resources()).script
        let policy = WritingPage.policy(script: script)
        #expect(policy.hasPrefix("default-src 'none'; script-src 'sha256-"))
        #expect(!policy.contains("unsafe-eval"))
        #expect(!policy.contains("script-src 'unsafe-inline'"))
        for directive in ["connect-src 'none'", "img-src data:", "base-uri 'none'", "form-action 'none'", "frame-src 'none'"] {
            #expect(policy.contains(directive), "\(directive)")
        }
        // A different script has a different hash, so it wouldn't run.
        #expect(WritingPage.policy(script: script + " ") != policy)
    }

    @Test("The policy comes before the stylesheet and the script")
    func policyFirst() {
        let page = WritingPage.document(script: "window.x=1", style: "body{}")
        let policy = try! #require(page.range(of: "Content-Security-Policy"))
        let style = try! #require(page.range(of: "<style>"))
        let script = try! #require(page.range(of: "<script>"))
        #expect(policy.lowerBound < style.lowerBound)
        #expect(style.lowerBound < script.lowerBound)
    }

    @Test("Colours and spaces come from the design tokens")
    func tokens() {
        let variables = WritingPage.variables()
        #expect(variables.contains("--tl-text:#15181d"))
        #expect(variables.contains("--tl-accent:#1f5fbf"))
        #expect(variables.contains("--tl-s4:16px"))
    }

    @Test("Every load is blocked by the rule list")
    func rules() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(WritingPage.closedRules.utf8)) as? [[String: [String: String]]]
        #expect(rules?.count == 1)
        #expect(rules?.first?["trigger"]?["url-filter"] == ".*")
        #expect(rules?.first?["action"]?["type"] == "block")
    }

    @Test("The page's own first load is the only navigation it gets")
    func navigation() {
        let blank = URL(string: "about:blank")
        #expect(WritingPage.allows(url: blank, isMainFrame: true, isLinkTap: false, expectingLoad: true))
        #expect(!WritingPage.allows(url: blank, isMainFrame: true, isLinkTap: false, expectingLoad: false))
        #expect(!WritingPage.allows(url: blank, isMainFrame: false, isLinkTap: false, expectingLoad: true))
        #expect(!WritingPage.allows(url: URL(string: "https://example.com"), isMainFrame: true, isLinkTap: false, expectingLoad: true))
        #expect(!WritingPage.allows(url: URL(string: "https://example.com"), isMainFrame: true, isLinkTap: true, expectingLoad: true))
        #expect(!WritingPage.allows(url: URL(string: "file:///etc/passwd"), isMainFrame: true, isLinkTap: false, expectingLoad: true))
    }

    @Test("Messages are read strictly, and anything unknown is dropped")
    func messages() {
        #expect(WritingMessage.parse(["type": "ready"]) == .ready)
        #expect(WritingMessage.parse(["type": "changed", "revision": 3]) == .changed(revision: 3))
        #expect(WritingMessage.parse(["type": "text", "revision": 4, "text": "# Chapter one"]) == .text(revision: 4, text: "# Chapter one"))
        #expect(WritingMessage.parse(["type": "text", "revision": -1, "text": "x"]) == nil)
        #expect(WritingMessage.parse(["type": "text", "revision": 1]) == nil)
        #expect(WritingMessage.parse(["type": "open", "url": "https://www.folger.edu/"]) == .open(URL(string: "https://www.folger.edu/")!))
        #expect(WritingMessage.parse(["type": "open", "url": "javascript:alert(1)"]) == nil)
        #expect(WritingMessage.parse(["type": "open", "url": "file:///private/var"]) == nil)
        #expect(WritingMessage.parse(["type": "open", "url": "tel:5551234"]) == nil)
        #expect(WritingMessage.parse(["type": "save", "text": "x"]) == nil)
        #expect(WritingMessage.parse("ready") == nil)
        #expect(WritingMessage.parse(["kind": "ready"]) == nil)
        let huge = String(repeating: "a", count: WritingMessage.maxText + 1)
        #expect(WritingMessage.parse(["type": "text", "revision": 1, "text": huge]) == nil)
    }

    @Test("The format state is clamped to what the bar knows")
    func formatState() {
        let state = WritingFormat(["bold": true, "heading": 9, "list": "<script>", "link": "https://a.org"])
        #expect(state.bold)
        #expect(state.heading == 6)
        #expect(state.list == "")
        #expect(state.link == "https://a.org")
    }
}

#if os(macOS)
/// The real page in a real web view: the doc goes in, a command runs, and the text comes back.
@MainActor
@Suite(.serialized) struct WritingPageWebTests {
    private func readyEditor(_ text: String) async throws -> WritingEditorController {
        let rules = WritingRules(directory: FileManager.default.temporaryDirectory.appendingPathComponent("WritingRulesTests-\(UUID())"))
        let editor = WritingEditorController(rules: rules)
        await editor.start()
        let webView = try #require(editor.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        editor.load(text)
        for _ in 0..<200 where editor.phase != .ready {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(editor.phase == .ready)
        return editor
    }

    private func pageText(_ editor: WritingEditorController) async throws -> String {
        let webView = try #require(editor.webView)
        let reply = try await webView.callAsyncJavaScript("return window.totality.text()", arguments: [:], in: nil, contentWorld: .page)
        return try #require((reply as? [String: Any])?["text"] as? String)
    }

    @Test("A doc loads, a heading command edits its Markdown, and the text comes back to Swift")
    func roundTrip() async throws {
        let editor = try await readyEditor("The Burial of the Dead\n\nApril is the cruellest month.")
        #expect(try await pageText(editor) == "The Burial of the Dead\n\nApril is the cruellest month.")
        let before = editor.revision
        editor.run("heading", 1)
        for _ in 0..<200 where editor.revision == before {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(editor.text == "# The Burial of the Dead\n\nApril is the cruellest month.")
        #expect(editor.format.heading == 1)
    }

    @Test("The page can't reach the network")
    func networkIsBlocked() async throws {
        let editor = try await readyEditor("Offline")
        let webView = try #require(editor.webView)
        let result = try await webView.callAsyncJavaScript(
            """
            try { await fetch("https://example.com/"); return "reached" } catch (error) { return "blocked" }
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        #expect(result as? String == "blocked")
        let image = try await webView.callAsyncJavaScript(
            """
            return await new Promise((done) => {
              const img = new Image();
              img.onload = () => done("loaded");
              img.onerror = () => done("blocked");
              img.src = "https://example.com/pixel.png";
            });
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        #expect(image as? String == "blocked")
    }

    /// Writes the page to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set.
    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let samples = [
            ("writing-essay.png", """
            # The Tragic Hero in *Macbeth*

            Aristotle's account of tragedy, in the *Poetics*, asks for a hero who falls through **hamartia**, an error of judgement rather than a vice. Macbeth fits that only in part: he chooses, knowing the cost, and keeps choosing.

            ## Ambition and prophecy

            - The witches' prophecy names a future but never forces it
            - Lady Macbeth's *goading* in 1.7
            - [x] Check the Arden line numbers
            - [ ] Compare the Folger text

            > Stars, hide your fires;
            > Let not light see my black and deep desires.

            1. Act one: the choice
            2. Act five: the cost

            See the [Folger edition](https://www.folger.edu/) for the full text, and `1.7.35` for the line.

            ---

            ### Works cited
            """),
            ("writing-empty.png", ""),
        ]
        for (name, text) in samples {
            let editor = try await readyEditor(text)
            let webView = try #require(editor.webView)
            webView.frame = CGRect(x: 0, y: 0, width: 393, height: 760)
            try await Task.sleep(for: .milliseconds(300))
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            let image = try await webView.takeSnapshot(configuration: configuration)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
    }

    @Test("Text that looks like markup stays text")
    func markupStaysText() async throws {
        let hostile = "<img src=x onerror=\"window.webkit.messageHandlers.editor.postMessage({type:'open',url:'https://evil.example'})\">\n<script>document.title='ran'</script>"
        let editor = try await readyEditor(hostile)
        let webView = try #require(editor.webView)
        let images = try await webView.callAsyncJavaScript("return document.querySelectorAll('img, script:not(:last-of-type)').length", arguments: [:], in: nil, contentWorld: .page)
        #expect(images as? Int == 0)
        let title = try await webView.callAsyncJavaScript("return document.title", arguments: [:], in: nil, contentWorld: .page)
        #expect(title as? String != "ran")
        #expect(try await pageText(editor) == hostile)
    }
}
#endif

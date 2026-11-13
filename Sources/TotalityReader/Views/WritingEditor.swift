import SwiftUI
import TotalityUI
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Runs one doc's writing page. The page holds the text while it's open. It sends the text here after
/// every pause in typing, and on request, and this keeps the latest copy so a save never waits on the page.
@MainActor
@Observable
final class WritingEditorController: NSObject {
    enum Phase: Equatable {
        case starting, ready
        case failed(String)
    }

    private(set) var phase = Phase.starting
    /// Goes up whenever newer text has arrived, so the screen knows there's something to save.
    private(set) var revision = 0
    private(set) var format = WritingFormat()
    /// Set when the person asks for a link. The screen asks for the address and clears it.
    var linkRequest: String?

    /// Where links the page asks to open go. They've already been checked.
    @ObservationIgnored var onOpen: ((URL) -> Void)?

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var latestText = ""
    @ObservationIgnored private var pageRevision = 0
    @ObservationIgnored private var typedRevision = 0
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var expectingLoad = false
    @ObservationIgnored private var options: [String: Any] = [:]
    @ObservationIgnored private var hasText = false
    @ObservationIgnored private var rules: WritingRules

    init(rules: WritingRules = .shared) {
        self.rules = rules
    }

    /// The text as of the last time the page sent it.
    var text: String { latestText }

    /// Makes the page once. The doc goes in when it's ready.
    func start() async {
        guard webView == nil else { return }
        guard let resources = WritingPage.resources() else {
            phase = .failed("The writing page is missing from this build.")
            return
        }
        guard let list = await rules.list() else {
            phase = .failed("The writing page couldn't be shut off from the internet, so it didn't open.")
            return
        }
        let view = WritingWebView(frame: .zero, configuration: WritingPage.configuration(rules: list, handler: MessageRelay(self)))
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsLinkPreview = false
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = Theme.current.bg.platformColor
        view.scrollView.backgroundColor = Theme.current.bg.platformColor
        view.scrollView.keyboardDismissMode = .interactive
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        view.underPageBackgroundColor = Theme.current.bg.platformColor
        view.allowsMagnification = false
        #endif
        webView = view
        loadPage(view, resources: resources)
    }

    private func loadPage(_ view: WKWebView, resources: (script: String, style: String)) {
        pageReady = false
        expectingLoad = true
        view.loadHTMLString(WritingPage.document(script: resources.script, style: resources.style), baseURL: nil)
    }

    /// Puts a doc in the page, replacing what's there.
    func load(_ text: String, placeholder: String = "Start writing", serif: Bool = false) {
        latestText = text
        hasText = true
        pageRevision = 0
        typedRevision = 0
        options = ["placeholder": placeholder, "serif": serif]
        revision += 1
        sendLoad()
    }

    private func sendLoad() {
        guard pageReady, hasText, let webView else { return }
        Task {
            do {
                _ = try await webView.callAsyncJavaScript(
                    "window.totality.load(text, options)", arguments: ["text": latestText, "options": options],
                    in: nil, contentWorld: .page
                )
                phase = .ready
            } catch {
                phase = .failed("The doc couldn't be put on the page.")
            }
        }
    }

    /// Gets anything typed since the last pause. Called before saving when the screen is going away.
    func flush() async {
        guard let webView, pageReady, typedRevision > pageRevision else { return }
        guard let result = try? await webView.callAsyncJavaScript("return window.totality.text()", arguments: [:], in: nil, contentWorld: .page),
              let reply = result as? [String: Any], let revision = reply["revision"] as? Int, let text = reply["text"] as? String,
              text.utf8.count <= WritingMessage.maxText
        else { return }
        accept(text, revision: revision)
    }

    func run(_ command: String, _ argument: Any? = nil) {
        guard let webView, pageReady else { return }
        var arguments: [String: Any] = ["name": command]
        arguments["argument"] = argument ?? NSNull()
        Task { _ = try? await webView.callAsyncJavaScript("window.totality.command(name, argument)", arguments: arguments, in: nil, contentWorld: .page) }
    }

    private func accept(_ text: String, revision: Int) {
        guard revision >= pageRevision else { return }
        pageRevision = revision
        typedRevision = max(typedRevision, revision)
        guard text != latestText else { return }
        latestText = text
        self.revision += 1
    }

    fileprivate func receive(_ message: WritingMessage) {
        switch message {
        case .ready:
            pageReady = true
            sendLoad()
        case .changed(let revision):
            typedRevision = max(typedRevision, revision)
        case .text(let revision, let text):
            accept(text, revision: revision)
        case .format(let state):
            if state != format { format = state }
        case .link(let address):
            linkRequest = address
        case .open(let url):
            onOpen?(url)
        }
    }

    /// Tries again after the page failed to start.
    func retry() async {
        webView = nil
        phase = .starting
        await start()
    }
}

extension WritingEditorController: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = WritingPage.allows(
            url: action.request.url, isMainFrame: action.targetFrame?.isMainFrame ?? false,
            isLinkTap: action.navigationType == .linkActivated, expectingLoad: expectingLoad
        )
        if allowed { expectingLoad = false }
        decisionHandler(allowed ? .allow : .cancel)
    }

    /// No new windows, ever.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    /// The page's process can be ended by the system. What was last sent is put back, so at most the
    /// last pause's worth of typing is lost, and only if it hadn't been sent yet.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let resources = WritingPage.resources() else { return }
        loadPage(webView, resources: resources)
    }
}

/// Holds the controller weakly, because the web view's content controller holds its handler strongly.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var controller: WritingEditorController?

    init(_ controller: WritingEditorController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the page itself speaks: not a frame inside it, and not some other web view.
        guard let controller, message.frameInfo.isMainFrame, message.webView === controller.webView,
              let parsed = WritingMessage.parse(message.body)
        else { return }
        controller.receive(parsed)
    }
}

#if os(iOS)
final class WritingWebView: WKWebView {}

struct WritingEditorView: UIViewRepresentable {
    let controller: WritingEditorController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = Theme.current.bg.platformColor
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    /// The web view belongs to the controller, so it lives as long as the doc is open, not as long as
    /// SwiftUI keeps this view.
    private func attach(to container: UIView) {
        guard let webView = controller.webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
#else
/// The Mac's right-click menu can fetch or open things by itself, so only editing stays.
final class WritingWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            let name = item.identifier?.rawValue ?? ""
            return ["Open", "Download", "Reload", "Inspect", "Share"].contains { name.contains($0) }
        }
        super.willOpenMenu(menu, with: event)
    }
}

struct WritingEditorView: NSViewRepresentable {
    let controller: WritingEditorController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        guard let webView = controller.webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
#endif

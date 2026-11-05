import SwiftUI
import WebKit

/// A compiled rule list, and which choice about images it belongs to. The page's policy and proxy follow
/// from the same choice, so a page can't be built with one and shown with the other.
struct MailPageRules: Equatable {
    let list: WKContentRuleList
    let allowsImages: Bool
}

/// An HTML message in its own web view, as tall as what it says. Pages wider than the space scale down
/// to fit. The rule list and the page's policy are set before the page loads and never change, so
/// turning images on makes a new view.
#if os(iOS)
struct MailPage: UIViewRepresentable {
    let document: String
    let rules: MailPageRules
    @Binding var height: CGFloat
    let onOpenLink: (URL) -> Void

    func makeCoordinator() -> MailPageCoordinator { MailPageCoordinator(height: $height, onOpenLink: onOpenLink) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: MailWebView.configuration(rules: rules.list, allowingImages: rules.allowsImages))
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(document, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.fit(view)
    }
}
#else
struct MailPage: NSViewRepresentable {
    let document: String
    let rules: MailPageRules
    @Binding var height: CGFloat
    let onOpenLink: (URL) -> Void

    func makeCoordinator() -> MailPageCoordinator { MailPageCoordinator(height: $height, onOpenLink: onOpenLink) }

    func makeNSView(context: Context) -> WKWebView {
        let view = MailMacWebView(frame: .zero, configuration: MailWebView.configuration(rules: rules.list, allowingImages: rules.allowsImages))
        view.allowsLinkPreview = false
        view.allowsMagnification = false
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(document, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.fit(view)
    }
}

/// The Mac's right-click menu can fetch a link or an image by itself, so only copying stays.
private final class MailMacWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            let name = item.identifier?.rawValue ?? ""
            return !name.hasSuffix("Copy") && !name.hasSuffix("CopyLink")
        }
        super.willOpenMenu(menu, with: event)
    }
}
#endif

/// Holds the only navigation a page ever gets, and measures what loaded.
@MainActor
final class MailPageCoordinator: NSObject, WKNavigationDelegate {
    var onOpenLink: (URL) -> Void

    private var height: Binding<CGFloat>
    private var measuredWidth: CGFloat = 0
    private var isLoaded = false

    init(height: Binding<CGFloat>, onOpenLink: @escaping (URL) -> Void) {
        self.height = height
        self.onOpenLink = onOpenLink
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        switch MailHTML.navigation(to: action.request.url, isLinkTap: action.navigationType == .linkActivated) {
        case .stay:
            decisionHandler(.allow)
        case .refuse:
            decisionHandler(.cancel)
        case .open(let url):
            decisionHandler(.cancel)
            onOpenLink(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        measure(webView)
    }

    /// A change of width changes where the words wrap.
    func fit(_ view: WKWebView) {
        guard isLoaded, view.bounds.width != measuredWidth else { return }
        measure(view)
    }

    private func measure(_ view: WKWebView) {
        let width = view.bounds.width
        guard width > 0 else { return }
        measuredWidth = width
        view.pageZoom = 1
        Task { [height] in
            guard let wide = await Self.number("document.documentElement.scrollWidth", in: view) else { return }
            if wide > width {
                view.pageZoom = width / wide
            }
            if let tall = await Self.number("document.documentElement.scrollHeight", in: view), tall > 0 {
                height.wrappedValue = tall * view.pageZoom
            }
        }
    }

    /// Runs apart from the page, which has no scripts of its own anyway.
    private static func number(_ script: String, in view: WKWebView) async -> CGFloat? {
        let value = try? await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        return (value as? NSNumber).map { CGFloat($0.doubleValue) }
    }
}

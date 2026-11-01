import SwiftUI
import WebKit

/// The tab's own web view. The page owns it, so a tab keeps its place when the screen changes.
#if os(iOS)
struct WebPageHost: UIViewRepresentable {
    let page: WebPage

    func makeUIView(context: Context) -> WKWebView { page.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct WebPageHost: NSViewRepresentable {
    let page: WebPage

    func makeNSView(context: Context) -> WKWebView { page.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

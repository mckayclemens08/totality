import SwiftUI
import TotalityUI

/// The browser: one box at the top for an address or a search, the page, and its controls.
public struct WebHomeView: View {
    let model: WebModel
    let onClose: (() -> Void)?

    @State private var typed = ""
    @FocusState private var isTyping: Bool
    @AppStorage(SafeSearch.key) private var safety = SafeSearch.moderate.rawValue

    public init(model: WebModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    private var tab: WebTab { model.current }
    private var page: WebPage? { tab.showing == .page ? tab.page : nil }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            addressBar
            progress
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .background(theme.bg.color)
        .onChange(of: tab.id) { showAddress() }
        .onChange(of: page?.url) { showAddress() }
        .onChange(of: tab.showing) { showAddress() }
        .onChange(of: isTyping) { if !isTyping { showAddress() } }
        .onChange(of: safety) { model.safety = SafeSearch(rawValue: safety) ?? .moderate }
        .onAppear {
            model.safety = SafeSearch(rawValue: safety) ?? .moderate
            showAddress()
        }
        .modifier(WebPageAlerts(page: page))
    }

    /// The site's name, until the box is tapped, when it's the whole address to edit.
    private func showAddress() {
        guard !isTyping else { return }
        switch tab.showing {
        case .start: typed = ""
        case .results: typed = tab.search.query
        case .page: typed = page?.url?.host()?.replacing(/^www\./, with: "") ?? ""
        }
    }

    private var addressBar: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s2) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "circle.hexagongrid")
                        .font(Typeface.body)
                        .foregroundStyle(theme.accent.color)
                        .frame(width: Space.s7, height: Space.s7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Home")
            }
            HStack(spacing: Space.s2) {
                if let page, !page.isSecure {
                    Label("Not secure", systemImage: "lock.open")
                        .labelStyle(.iconOnly)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .accessibilityLabel("Not secure")
                }
                TextField("Search or enter address", text: $typed)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    #endif
                    .focused($isTyping)
                    .onSubmit {
                        model.submit(typed)
                        isTyping = false
                    }
                    .accessibilityLabel("Search or enter address")
                if isTyping, !typed.isEmpty {
                    Button {
                        typed = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                } else if let page {
                    Button {
                        if page.isLoading { page.stop() } else { page.reload() }
                    } label: {
                        Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(page.isLoading ? "Stop" : "Reload")
                }
            }
            .padding(.horizontal, Space.s4)
            .frame(height: Space.s7)
            .neumorphic(.pressed, in: Capsule())
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .onChange(of: isTyping) {
            if isTyping, let url = page?.url { typed = url.absoluteString }
        }
    }

    @ViewBuilder private var progress: some View {
        let theme = Theme.current
        if let page, page.isLoading {
            GeometryReader { proxy in
                Rectangle()
                    .fill(theme.accent.color)
                    .frame(width: proxy.size.width * page.progress)
            }
            .frame(height: Space.hairline * 2)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var content: some View {
        switch tab.showing {
        case .start:
            WebMessage(systemImage: "globe", title: "Search the web", detail: WebCopy.notEncrypted)
        case .results:
            WebResultsView(model: model, tab: tab)
        case .page:
            if let page {
                if let failure = page.failure {
                    WebMessage(
                        systemImage: failure == .insecure ? "lock.slash" : "exclamationmark.triangle",
                        title: failure.title, detail: failure.detail,
                        action: failure.canRetry ? WebMessageAction(label: "Try again") { page.reload() } : nil
                    )
                } else {
                    WebPageHost(page: page).id(page.webView.hashValue)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            control("chevron.backward", label: "Back", enabled: model.canGoBack, action: model.goBack)
                .keyboardShortcut("[", modifiers: .command)
            control("chevron.forward", label: "Forward", enabled: model.canGoForward, action: model.goForward)
                .keyboardShortcut("]", modifiers: .command)
            Spacer(minLength: 0)
            if let url = page?.url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(Typeface.body)
                        .frame(width: Space.s7, height: Space.s7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
            }
        }
        .foregroundStyle(Theme.current.textPrimary.color)
        .padding(.horizontal, Space.s3)
    }

    private func control(_ systemImage: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.body)
                .frame(width: Space.s7, height: Space.s7)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// What a page can ask the person: its own alerts, and whether to leave for another app.
private struct WebPageAlerts: ViewModifier {
    let page: WebPage?

    @Environment(\.openURL) private var openURL

    private var dialogShown: Binding<Bool> {
        Binding { page?.dialog != nil } set: { shown in
            // A page is waiting on the answer, so dismissing it can't leave it hanging.
            if !shown, let page, let dialog = page.dialog { page.answer(dialog, false) }
        }
    }

    private var leavingShown: Binding<Bool> {
        Binding { page?.leaving != nil } set: { if !$0 { page?.leaving = nil } }
    }

    func body(content: Content) -> some View {
        content
            .alert(page?.dialog?.site ?? "", isPresented: dialogShown, presenting: page?.dialog) { dialog in
                WebDialogButtons(page: page, dialog: dialog)
            } message: { dialog in
                Text(dialog.message)
            }
            .alert("Open another app?", isPresented: leavingShown, presenting: page?.leaving) { url in
                Button("Open") {
                    page?.leaving = nil
                    openURL(url)
                }
                Button("Cancel", role: .cancel) { page?.leaving = nil }
            } message: { url in
                Text(url.absoluteString)
            }
    }
}

/// The buttons for a dialog a page raised.
private struct WebDialogButtons: View {
    let page: WebPage?
    let dialog: WebDialog

    @State private var text = ""

    var body: some View {
        switch dialog.kind {
        case .alert:
            Button("OK") { page?.answer(dialog, true) }
        case .confirm:
            Button("OK") { page?.answer(dialog, true) }
            Button("Cancel", role: .cancel) { page?.answer(dialog, false) }
        case .prompt(let placeholder):
            TextField(placeholder, text: $text)
            Button("OK") { page?.answer(dialog, true, text: text) }
            Button("Cancel", role: .cancel) { page?.answer(dialog, false) }
        }
    }
}

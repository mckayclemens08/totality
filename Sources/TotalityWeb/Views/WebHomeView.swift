import SwiftUI
import TotalityUI

/// The browser: one box at the top for an address or a search, the page, and its controls.
public struct WebHomeView: View {
    let model: WebModel
    let onClose: (() -> Void)?

    @State private var typed = ""
    @FocusState private var isTyping: Bool
    @State private var showingTabs = false
    @State private var showingLibrary = false
    @State private var showingSettings = false
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
            ZStack {
                content
                if isTyping, !suggestions.isEmpty { suggestionList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(isPresented: $showingTabs) { WebTabsView(model: model) { showingTabs = false } }
        .sheet(isPresented: $showingLibrary) { WebLibraryView(model: model) { showingLibrary = false } }
        .sheet(isPresented: $showingSettings) { WebSettingsView(model: model) { showingSettings = false } }
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

    private var suggestions: [WebSuggestion] {
        model.suggestions(for: typed)
    }

    private var suggestionList: some View {
        let theme = Theme.current
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        isTyping = false
                        model.open(suggestion.url)
                    } label: {
                        HStack(spacing: Space.s3) {
                            Image(systemName: suggestion.isBookmark ? "bookmark" : "clock")
                                .font(Typeface.body)
                                .foregroundStyle(theme.textSecondary.color)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(suggestion.title)
                                    .font(Typeface.body)
                                    .foregroundStyle(theme.textPrimary.color)
                                    .lineLimit(1)
                                Text(suggestion.url.host() ?? "")
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.textSecondary.color)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(theme.bg.color)
    }

    private var addressBar: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s2) {
            // The usual way to reach the box from a keyboard.
            Button("Go to address") { isTyping = true }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
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
                if tab.isPrivate {
                    Image(systemName: "eye.slash")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.accent.color)
                        .accessibilityLabel("Private tab")
                }
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
                    .keyboardShortcut("r", modifiers: .command)
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
            WebStartView(model: model, isPrivate: tab.isPrivate)
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
                Spacer(minLength: 0)
            }
            control("book", label: "Bookmarks and history", enabled: true) { showingLibrary = true }
                .keyboardShortcut("y", modifiers: .command)
            Spacer(minLength: 0)
            Button {
                showingTabs = true
            } label: {
                Image(systemName: "\(min(model.tabs.count, 50)).square")
                    .font(Typeface.body)
                    .frame(width: Space.s7, height: Space.s7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tabs, \(model.tabs.count) open")
            menu
        }
        .foregroundStyle(Theme.current.textPrimary.color)
        .padding(.horizontal, Space.s3)
    }

    private var menu: some View {
        Menu {
            Button("New Tab", systemImage: "plus.square") { startTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Private Tab", systemImage: "eye.slash") { startTab(isPrivate: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Tab", systemImage: "xmark.square") { model.close(tab) }
                .keyboardShortcut("w", modifiers: .command)
            if let url = page?.url {
                Divider()
                if let saved = model.bookmark(for: url) {
                    Button("Remove Bookmark", systemImage: "bookmark.slash") { Task { await model.remove(saved) } }
                } else {
                    Button("Add Bookmark", systemImage: "bookmark") {
                        Task { await model.addBookmark(title: page?.title ?? "", url: url) }
                    }
                    .keyboardShortcut("d", modifiers: .command)
                }
            }
            Divider()
            Button("Web Settings", systemImage: "gearshape") { showingSettings = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Typeface.body)
                .frame(width: Space.s7, height: Space.s7)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    private func startTab(isPrivate: Bool = false) {
        model.newTab(isPrivate: isPrivate)
        isTyping = true
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

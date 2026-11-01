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
    @State private var showingDownloads = false
    @State private var finding = false
    @State private var findText = ""
    @State private var findMissed = false
    @FocusState private var isFinding: Bool
    @Environment(\.openURL) private var openURL
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
            if finding { findBar }
            controls
        }
        .background(theme.bg.color)
        .background(shortcuts)
        .overlay(alignment: .bottom) { noticeBar }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { model.notice = nil }
        }
        .onChange(of: findText) { Task { await find() } }
        .onChange(of: page?.url) { finding = false }
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
        .sheet(isPresented: $showingDownloads) { WebDownloadsView(model: model) { showingDownloads = false } }
    }

    /// The Mac's usual keys, in one place. A keyboard on an iPhone gets them too.
    private var shortcuts: some View {
        ZStack {
            Button("New Tab") { startTab() }.keyboardShortcut("t", modifiers: .command)
            Button("New Private Tab") { startTab(isPrivate: true) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Tab") { model.close(tab) }.keyboardShortcut("w", modifiers: .command)
            Button("Go to Address") { isTyping = true }.keyboardShortcut("l", modifiers: .command)
            Button("Reload") { page?.reload() }.keyboardShortcut("r", modifiers: .command)
            Button("Find on Page") { startFinding() }.keyboardShortcut("f", modifiers: .command)
            Button("Back", action: model.goBack).keyboardShortcut("[", modifiers: .command)
            Button("Forward", action: model.goForward).keyboardShortcut("]", modifiers: .command)
            Button("Bookmarks and History") { showingLibrary = true }.keyboardShortcut("y", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var noticeBar: some View {
        let theme = Theme.current
        if let notice = model.notice {
            Text(notice)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)
                .neumorphic(.raised, in: Capsule())
                .padding(.bottom, Space.s8)
        }
    }

    private func startFinding() {
        guard let page else { return }
        #if os(iOS)
        page.showFindBar()
        #else
        finding = true
        isFinding = true
        #endif
    }

    private func find(backwards: Bool = false) async {
        guard let page, !findText.isEmpty else {
            findMissed = false
            return
        }
        findMissed = await !page.find(findText, backwards: backwards)
    }

    private var findBar: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                TextField("Find on page", text: $findText)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($isFinding)
                    .onSubmit { Task { await find() } }
                if findMissed {
                    Text("No matches")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .padding(.horizontal, Space.s4)
            .frame(height: Space.s7)
            .neumorphic(.pressed, in: Capsule())
            control("chevron.up", label: "Previous match", enabled: !findText.isEmpty) { Task { await find(backwards: true) } }
            control("chevron.down", label: "Next match", enabled: !findText.isEmpty) { Task { await find() } }
            Button("Done") {
                finding = false
                findText = ""
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.accent.color)
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .foregroundStyle(theme.textPrimary.color)
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s1)
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
            control("chevron.forward", label: "Forward", enabled: model.canGoForward, action: model.goForward)
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
            Button("New Private Tab", systemImage: "eye.slash") { startTab(isPrivate: true) }
            Button("Close Tab", systemImage: "xmark.square") { model.close(tab) }
            if let page, let url = page.url {
                Divider()
                pageMenu(page, url: url)
            }
            Divider()
            Button("Downloads", systemImage: "arrow.down.circle") { showingDownloads = true }
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

    @ViewBuilder private func pageMenu(_ page: WebPage, url: URL) -> some View {
        if let saved = model.bookmark(for: url) {
            Button("Remove Bookmark", systemImage: "bookmark.slash") { Task { await model.remove(saved) } }
        } else {
            Button("Add Bookmark", systemImage: "bookmark") {
                Task { await model.addBookmark(title: page.title, url: url) }
            }
        }
        Button("Save to Reader", systemImage: "text.book.closed") { Task { await model.saveToReader() } }
        Button("Find on Page", systemImage: "magnifyingglass") { startFinding() }
        Menu("Text Size", systemImage: "textformat.size") {
            Button("Larger", systemImage: "plus") { page.zoom(in: true) }
            Button("Smaller", systemImage: "minus") { page.zoom(in: false) }
        }
        #if os(iOS)
        Button(page.wantsDesktopSite ? "Request Mobile Site" : "Request Desktop Site", systemImage: "desktopcomputer") {
            page.wantsDesktopSite.toggle()
            page.reload()
        }
        #endif
        Button("Print", systemImage: "printer") { page.printPage() }
        Button("Open in Safari", systemImage: "safari") { openURL(url) }
        if let site = WebSite.key(url) {
            let isOn = model.isBlocking(url)
            Button(isOn ? "Turn Off Blocking Here" : "Turn On Blocking Here", systemImage: "shield.lefthalf.filled") {
                model.setBlocking(!isOn, for: site)
            }
        }
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

import SwiftUI
import TotalityCore
import TotalityUI

/// Bookmarks and history.
struct WebLibraryView: View {
    let model: WebModel
    let onClose: () -> Void

    private enum Section: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks", history = "History"
        var id: Self { self }
    }

    @State private var section = Section.bookmarks
    @State private var filter = ""
    @State private var editing: WebBookmark?
    @State private var clearing = false

    var body: some View {
        WebSheet(title: section.rawValue, onClose: onClose) {
            VStack(spacing: 0) {
                Picker("Show", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Space.s4)
                RefreshStatusLine(model.refresher)
                switch section {
                case .bookmarks: bookmarks
                case .history: history
                }
            }
            .pullsToRefresh(with: model.refresher)
        }
        .sheet(item: $editing) { bookmark in
            WebBookmarkEditor(model: model, bookmark: bookmark) { editing = nil }
        }
        .confirmationDialog("Clear which history?", isPresented: $clearing, titleVisibility: .visible) {
            ForEach(WebClearing.allCases) { reach in
                Button(reach.label, role: .destructive) { model.clearHistory(reach) }
            }
        }
    }

    @ViewBuilder private var bookmarks: some View {
        if model.bookmarks.isEmpty {
            WebMessage(systemImage: "bookmark", title: "No bookmarks yet", detail: "Open a page, then choose Add Bookmark from the menu. Bookmarks sync between your devices, sealed with your key.")
        } else {
            List {
                let folders = [""] + model.folders
                ForEach(folders, id: \.self) { folder in
                    let inside = model.bookmarks.filter { $0.folder == folder }
                    if !inside.isEmpty {
                        SwiftUI.Section {
                            ForEach(inside) { bookmark in
                                row(bookmark.displayTitle, url: bookmark.url, image: "bookmark")
                                    .contextMenu {
                                        Button("Edit") { editing = bookmark }
                                        Button("Remove", role: .destructive) { Task { await model.remove(bookmark) } }
                                    }
                            }
                            .onDelete { rows in
                                let removed = rows.map { inside[$0] }
                                Task { for bookmark in removed { await model.remove(bookmark) } }
                            }
                        } header: {
                            if !folder.isEmpty { Text(folder) }
                        }
                    }
                }
                .listRowBackground(Theme.current.bg.color)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var visits: [WebVisit] {
        let terms = SearchText.terms(in: filter)
        guard !terms.isEmpty else { return model.history }
        return model.history.filter { visit in
            terms.allSatisfy { SearchText.find($0, in: visit.title) != nil || SearchText.find($0, in: visit.url.absoluteString) != nil }
        }
    }

    @ViewBuilder private var history: some View {
        let theme = Theme.current
        if model.history.isEmpty {
            WebMessage(systemImage: "clock", title: "No history", detail: "Pages you open appear here, sealed and kept only on this device. Private tabs never do.")
        } else {
            TextField("Search history", text: $filter)
                .font(Typeface.body)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(.horizontal, Space.s4)
                .frame(height: Space.s7)
                .neumorphic(.pressed, in: Capsule())
                .padding(Space.s4)
            List {
                ForEach(visits) { visit in
                    row(visit.displayTitle, url: visit.url, image: "clock", detail: visit.date.formatted(date: .abbreviated, time: .shortened))
                }
                .onDelete { rows in
                    let shown = visits
                    for row in rows { model.forget(shown[row]) }
                }
                .listRowBackground(theme.bg.color)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            Button("Clear History") { clearing = true }
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .buttonStyle(.plain)
                .padding(Space.s4)
        }
    }

    private func row(_ title: String, url: URL, image: String, detail: String? = nil) -> some View {
        let theme = Theme.current
        return Button {
            model.open(url)
            onClose()
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: image)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Text(detail.map { "\(url.host() ?? "") · \($0)" } ?? url.host() ?? "")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct WebBookmarkEditor: View {
    let model: WebModel
    let bookmark: WebBookmark
    let onClose: () -> Void

    @State private var title = ""
    @State private var folder = ""

    var body: some View {
        WebSheet(title: "Edit Bookmark", onClose: onClose) {
            VStack(spacing: Space.s3) {
                field("Title", text: $title)
                field("Folder", text: $folder)
                Button("Save") {
                    var changed = bookmark
                    changed.title = title
                    changed.folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await model.save(changed)
                        onClose()
                    }
                }
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.accent.color)
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(Space.s4)
        }
        .onAppear {
            title = bookmark.title
            folder = bookmark.folder
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .font(Typeface.body)
            .textFieldStyle(.plain)
            .padding(.horizontal, Space.s4)
            .frame(height: Space.s7)
            .neumorphic(.pressed, in: Capsule())
    }
}

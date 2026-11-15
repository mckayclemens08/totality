import SwiftUI
import TotalityCore
import TotalityUI

/// Picks a doc to link to. The link names its title, as `[[Title]]`.
struct DocLinkPicker: View {
    let docs: [ReaderItem]
    let onPick: (String) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var linkable: [ReaderItem] {
        docs.filter { $0.kind == .note && WikiLinks.linkable($0.title) }
    }

    private var shown: [ReaderItem] {
        let terms = SearchText.terms(in: query)
        guard !terms.isEmpty else { return linkable }
        return linkable.filter { doc in terms.allSatisfy { SearchText.find($0, in: doc.title) != nil } }
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(spacing: Space.s3) {
                if linkable.isEmpty {
                    ReaderMessage(
                        systemImage: "doc.text",
                        title: "No other docs yet",
                        detail: "Give another doc a title and it can be linked from here. You can also type [[ and a title, and the doc is made when you follow the link."
                    )
                } else {
                    SearchBox("Doc title", text: $query)
                        .padding(.horizontal, Space.s4)
                    if shown.isEmpty {
                        ReaderMessage(systemImage: "magnifyingglass", title: "No matches", detail: "No doc's title matches that.")
                    } else {
                        List(shown) { doc in
                            Button {
                                onPick(doc.title)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: Space.s1) {
                                    Text(doc.title)
                                        .font(Typeface.body)
                                        .foregroundStyle(theme.textPrimary.color)
                                        .lineLimit(2)
                                    Text(doc.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textSecondary.color)
                                }
                            }
                            .listRowBackground(theme.bg.color)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .padding(.top, Space.s3)
            .background(theme.bg.color)
            .navigationTitle("Link to a doc")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// The docs whose links lead to this one, each with the words around its link.
struct BacklinksSheet: View {
    let item: ReaderItem
    let model: ReaderModel

    private enum Phase {
        case loading
        case loaded([WikiLinks.Backlink])
        case failed
    }

    @State private var phase = Phase.loading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Looking through your docs")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ReaderMessage(
                        systemImage: "exclamationmark.triangle",
                        title: "Links couldn't be checked",
                        detail: "Some docs didn't open. Try again in a moment."
                    )
                case .loaded(let links) where links.isEmpty:
                    ReaderMessage(
                        systemImage: "link",
                        title: "Nothing links here yet",
                        detail: "Type [[\(item.displayTitle)]] in another doc, or use Link to a doc in its format bar, and it shows up here."
                    )
                case .loaded(let links):
                    List(links) { link in
                        Button {
                            model.linkedItem = link.item.id
                            dismiss()
                        } label: {
                            BacklinkRow(link: link)
                        }
                        .listRowBackground(theme.bg.color)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.bg.color)
            .navigationTitle("Linked from")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            do {
                phase = .loaded(try await model.backlinks(to: item.id))
            } catch is CancellationError {
                // The sheet closed first.
            } catch {
                phase = .failed
            }
        }
    }
}

/// A doc's earlier versions on this device. One can be read, and put back.
struct VersionHistorySheet: View {
    let item: ReaderItem
    let model: ReaderModel
    /// Called after a version is put back, so the open editor can load it.
    let onRestored: () async -> Void

    private enum Phase {
        case loading
        case loaded([DocVersion])
        case failed
    }

    @State private var phase = Phase.loading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ReaderMessage(
                        systemImage: "lock.slash",
                        title: "Versions didn't open",
                        detail: "They may have been damaged, or made under another key."
                    )
                case .loaded(let versions) where versions.isEmpty:
                    ReaderMessage(
                        systemImage: "clock.arrow.circlepath",
                        title: "No earlier versions yet",
                        detail: "A version is kept each time you stop writing for a moment, and when you close the doc. They're sealed, and stay on this device."
                    )
                case .loaded(let versions):
                    List {
                        Section {
                            ForEach(versions) { version in
                                NavigationLink {
                                    VersionView(item: item, version: version, model: model) {
                                        await onRestored()
                                        dismiss()
                                    }
                                } label: {
                                    VersionRow(version: version, current: item)
                                }
                                .listRowBackground(theme.surface.color)
                            }
                        } footer: {
                            Text("Versions are sealed and kept on this device. Recent ones are all here. Further back, fewer are kept.")
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.bg.color)
            .navigationTitle("Version history")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            do {
                phase = .loaded(try await model.versions(of: item.id))
            } catch {
                phase = .failed
            }
        }
    }

    static func detail(_ version: DocVersion, current: ReaderItem) -> String {
        let words = version.words == 1 ? "1 word" : "\(version.words.formatted()) words"
        return version.title == current.title || version.title.isEmpty ? words : "\(words) · titled \(version.title)"
    }
}

/// A doc that links here, with the words around its first link.
struct BacklinkRow: View {
    let link: WikiLinks.Backlink

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(link.item.displayTitle)
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            if !link.snippet.isEmpty {
                Text(link.snippet)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(3)
            }
            if link.count > 1 {
                Text("\(link.count) links")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
    }
}

/// When a version was kept, and how long it was.
struct VersionRow: View {
    let version: DocVersion
    let current: ReaderItem

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(version.savedAt.formatted(date: .abbreviated, time: .shortened))
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
            Text(VersionHistorySheet.detail(version, current: current))
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
    }
}

/// One version's words, as they'll read, with the choice to put it back.
private struct VersionView: View {
    let item: ReaderItem
    let version: DocVersion
    let model: ReaderModel
    let onRestored: () async -> Void

    @State private var text: String?
    @State private var failed = false
    @State private var confirming = false
    @State private var restoring = false

    var body: some View {
        let theme = Theme.current
        Group {
            if failed {
                ReaderMessage(systemImage: "lock.slash", title: "This version didn't open", detail: "It may have been damaged.")
            } else if let text {
                ScrollView {
                    Text(MarkdownText.plainText(text))
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s4)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.bg.color)
        .navigationTitle(version.savedAt.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Restore") { confirming = true }
                    .disabled(text == nil || restoring)
            }
        }
        .confirmationDialog("Restore this version?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Restore") {
                restoring = true
                Task {
                    if await model.restoreVersion(version, of: item.id) { await onRestored() }
                    restoring = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The doc goes back to these words. What it says now is kept as a version first, so you can come back to it.")
        }
        .task {
            do {
                text = try await model.versionText(version, of: item.id)
            } catch {
                failed = true
            }
        }
    }
}

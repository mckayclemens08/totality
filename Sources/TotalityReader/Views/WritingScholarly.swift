import SwiftUI
import TotalityCore
import TotalityUI

/// Picks a reference to cite. The list comes from every reference library in the Reader.
struct CitationPicker: View {
    let references: [References.Summary]
    let onPick: (References.Summary) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [References.Summary] {
        let terms = SearchText.terms(in: query)
        guard !terms.isEmpty else { return references }
        return references.filter { reference in
            terms.allSatisfy { term in
                [reference.author, reference.year, reference.title, reference.id].contains { SearchText.find(term, in: $0) != nil }
            }
        }
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(spacing: Space.s3) {
                if references.isEmpty {
                    ReaderMessage(
                        systemImage: "books.vertical",
                        title: "No references yet",
                        detail: "Import a .bib or CSL JSON file from Zotero or another reference manager into the Reader. It's sealed like any file, and every doc can cite it."
                    )
                } else {
                    SearchBox("Author, year or title", text: $query)
                        .padding(.horizontal, Space.s4)
                    if shown.isEmpty {
                        ReaderMessage(systemImage: "magnifyingglass", title: "No matches", detail: "Nothing in your references matches that.")
                    } else {
                        List(shown) { reference in
                            Button {
                                onPick(reference)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: Space.s1) {
                                    Text(reference.title.isEmpty ? reference.id : reference.title)
                                        .font(Typeface.body)
                                        .foregroundStyle(theme.textPrimary.color)
                                        .lineLimit(2)
                                    Text([reference.author, reference.year, "@" + reference.id].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textSecondary.color)
                                        .lineLimit(1)
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
            .navigationTitle("Cite")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Picks a section, figure or table to refer to. A heading without a label gets one when it's picked.
struct CrossReferencePicker: View {
    let labels: [WritingLabel]
    let headings: [WritingHeading]
    let onPick: (String) -> Void
    let onLabel: (WritingHeading) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = Theme.current
        let labelled = Set(labels.filter { $0.kind == "sec" }.map(\.caption))
        let unlabelled = headings.filter { !labelled.contains($0.text) }
        NavigationStack {
            Group {
                if labels.isEmpty && unlabelled.isEmpty {
                    ReaderMessage(
                        systemImage: "arrow.turn.down.right",
                        title: "Nothing to refer to yet",
                        detail: "Add a heading, or a figure with an image, and it can be referred to by name or number. The reference updates if it moves."
                    )
                } else {
                    List {
                        if !labels.isEmpty {
                            Section("Labelled") {
                                ForEach(labels) { label in
                                    row(label.title, detail: "@" + label.id) {
                                        onPick(label.id)
                                    }
                                }
                            }
                        }
                        if !unlabelled.isEmpty {
                            Section {
                                ForEach(unlabelled) { heading in
                                    row(heading.text, detail: "Heading \(heading.level)") {
                                        onLabel(heading)
                                    }
                                }
                            } header: {
                                Text("Headings")
                            } footer: {
                                Text("Picking one gives it a label, such as {#sec:method}, at the end of its line.")
                            }
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
            .navigationTitle("Refer to")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        let theme = Theme.current
        return Button {
            action()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title).font(Typeface.body).foregroundStyle(theme.textPrimary.color).lineLimit(2)
                Text(detail).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
        }
        .listRowBackground(theme.surface.color)
    }
}

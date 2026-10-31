import SwiftUI
import TotalityUI

/// Everything deleted in the last 30 days, here or on another device.
struct ReaderTrashView: View {
    let model: ReaderModel
    @State private var confirmingEmpty = false
    @State private var deleting: ReaderItem?

    /// Rounds up, so something deleted just now shows the whole 30 days.
    static func left(_ entry: TrashedItem, now: Date = Date()) -> String {
        let remaining = entry.deletedAt.addingTimeInterval(ReaderVault.trashLifetime).timeIntervalSince(now)
        let days = max(0, Int((remaining / 86_400).rounded(.up)))
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if model.trash.isEmpty {
                ReaderMessage(systemImage: "trash", title: "Nothing here", detail: "Anything you delete stays here for 30 days, then it's gone for good.")
            } else {
                List {
                    Text("Items stay here for 30 days, then they're gone for good. A folder brings back what was inside it.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(model.trash) { entry in
                        ReaderRow(item: entry.item, snippet: Self.left(entry))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading) {
                                Button("Restore", systemImage: "arrow.uturn.backward") { restore(entry) }
                                    .tint(theme.accent.color)
                            }
                            .swipeActions {
                                Button("Delete now", systemImage: "trash", role: .destructive) { deleting = entry.item }
                            }
                            .contextMenu {
                                Button("Restore", systemImage: "arrow.uturn.backward") { restore(entry) }
                                Button("Delete now", systemImage: "trash", role: .destructive) { deleting = entry.item }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.bg.color)
        .navigationTitle("Recently Deleted")
        .toolbar {
            if !model.trash.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty", role: .destructive) { confirmingEmpty = true }
                }
            }
        }
        .confirmationDialog("Delete everything here for good?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Delete for good", role: .destructive) {
                Task { await model.emptyTrash() }
            }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Delete \(deleting?.displayTitle ?? "this") for good?", isPresented: isDeleting, titleVisibility: .visible, presenting: deleting
        ) { item in
            Button("Delete for good", role: .destructive) {
                Task { await model.deleteForever(item) }
            }
        } message: { _ in
            Text("This can't be undone.")
        }
        .task { await model.load() }
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func restore(_ entry: TrashedItem) {
        Task { await model.restore(entry.item) }
    }
}

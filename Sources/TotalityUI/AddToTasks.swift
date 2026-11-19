import SwiftUI
import TotalityCore

/// "Add to Tasks" from any module (issue 123, step 4). The module hands over a draft and the registry's
/// task maker; nothing is made until Add, and only the title kept here and the link go to Tasks.
public struct AddToTasksSheet: View {
    private let draft: TaskDraft
    private let maker: (any TaskMaker)?
    private let onDone: (TaskMade?) -> Void
    @State private var title: String
    @State private var isSaving = false
    @State private var failed = false
    @FocusState private var isFocused: Bool

    public init(draft: TaskDraft, maker: (any TaskMaker)?, onDone: @escaping (TaskMade?) -> Void) {
        self.draft = draft
        self.maker = maker
        self.onDone = onDone
        _title = State(initialValue: draft.title)
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    TextField("What to do", text: $title, axis: .vertical)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .focused($isFocused)
                        .lineLimit(1...4)
                        .raisedField()
                    if let quote = draft.source.quote {
                        Text("“\(quote)”")
                            .font(Typeface.callout.weight(.regular))
                            .italic()
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(6)
                    }
                    Text(note)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                    if failed {
                        Text("The task couldn't be added. Try again.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Add to Tasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(isSaving || maker == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(theme.accent.color)
        .presentationDetents([.medium, .large])
        .onAppear { isFocused = true }
    }

    /// What the task keeps, said plainly, as on the boards.
    private var note: String {
        switch draft.source.module {
        case .messages: "The task keeps a link to this message. The message's words stay in Messages; the task holds only its title."
        case .photos: "The photo stays in Photos and the task links to it."
        case .reader: "Saved with a link back to this item in the Reader."
        default: "Saved to the Inbox with a link back."
        }
    }

    private func add() async {
        guard let maker else { return }
        isSaving = true
        defer { isSaving = false }
        var draft = draft
        draft.title = title
        do {
            onDone(try await maker.makeTask(draft))
        } catch {
            failed = true
        }
    }
}

extension View {
    /// Shows the Add to Tasks sheet while `draft` is set, and says what happened with `onAdded`.
    public func addToTasksSheet(
        _ draft: Binding<TaskDraft?>, maker: (any TaskMaker)?, onAdded: @escaping (TaskMade) -> Void
    ) -> some View {
        sheet(item: draft) { item in
            AddToTasksSheet(draft: item, maker: maker) { made in
                draft.wrappedValue = nil
                if let made { onAdded(made) }
            }
        }
    }
}

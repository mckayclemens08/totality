import SwiftUI
import TotalityCore
import TotalityUI

/// A shared list or project: who's in it, its tasks under their headings, and who has each (step 6).
struct SharedListScreen: View {
    let shared: SharedListsModel
    let model: TasksModel
    let room: String
    let onBack: () -> Void
    @State var openTask: UUID?
    @State private var sheet: Sheet?
    @State private var adding = false
    @State private var newTitle = ""

    enum Sheet: String, Identifiable {
        case people, share
        var id: String { rawValue }
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if let list = shared.list(room) {
                VStack(spacing: 0) {
                    header(list)
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s3) {
                            ForEach(Array(list.sections.enumerated()), id: \.offset) { _, section in
                                sectionView(list, heading: section.heading, tasks: section.tasks)
                            }
                            if list.liveTasks.isEmpty {
                                Text(shared.canEdit(room) ? "No tasks yet. Add the first one with +." : "No tasks yet.")
                                    .font(Typeface.callout)
                                    .foregroundStyle(theme.textSecondary.color)
                                    .padding(.top, Space.s4)
                            }
                            if let last = lastActivity(list) {
                                Text(last)
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.textSecondary.color)
                                    .padding(.horizontal, Space.s1)
                            }
                            if list.unreadable > 0 {
                                Label("\(list.unreadable) changes from before you joined can't be opened on this device.", systemImage: "lock.trianglebadge.exclamationmark")
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.textSecondary.color)
                            }
                            Color.clear.frame(height: Metric.addButton + Space.s5)
                        }
                        .padding(.horizontal, Space.s4)
                    }
                    .refreshable { await shared.refresh() }
                }
                .overlay(alignment: .bottomTrailing) {
                    if shared.canEdit(room) {
                        AddButton("New task") { adding = true }.padding(Space.s4)
                    }
                }
            } else {
                VStack(spacing: Space.s4) {
                    HStack {
                        HeaderButton("Back", systemImage: "chevron.left", action: onBack)
                        Spacer()
                    }
                    Spacer()
                    Text("This list isn't here any more.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                    Spacer()
                }
                .padding(Space.s4)
            }
        }
        .background(theme.bg.color.ignoresSafeArea())
        .edgeSwipeBack(onBack)
        .overlay {
            if let id = openTask {
                SharedTaskScreen(shared: shared, model: model, room: room, taskID: id) { openTask = nil }
                    .transition(.move(edge: .trailing))
            }
        }
        .motion(Motion.smooth, value: openTask)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .people: PeopleSheet(shared: shared, room: room, onShare: { self.sheet = .share }, onLeft: onBack) { self.sheet = nil }
            case .share: ShareSheet(shared: shared, target: .room(room)) { _ in self.sheet = nil }
            }
        }
        .alert("New task", isPresented: $adding) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) { newTitle = "" }
            Button("Add") {
                let title = newTitle
                newTitle = ""
                Task { await shared.add(title, to: room) }
            }
        }
    }

    private func header(_ list: SharedListState) -> some View {
        let people = list.members.filter { !$0.isInvited }.map(\.username).sorted { a, _ in a == shared.own }
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                HeaderButton("Back", systemImage: "chevron.left", action: onBack)
                Spacer()
                HeaderButton("People", systemImage: "person.2") { sheet = .people }
                if shared.isOwner(room) {
                    HeaderButton("Share", systemImage: "person.badge.plus") { sheet = .share }
                }
            }
            ScreenTitle(list.displayName)
            FaceStack(shared: shared, people: people, diameter: Space.s6)
            if list.isEncrypted { EncryptedLabel() }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s2)
    }

    @ViewBuilder private func sectionView(_ list: SharedListState, heading: TaskList.Heading?, tasks: [SharedTask]) -> some View {
        let theme = Theme.current
        let done = tasks.filter(\.task.isCompleted).count
        if let heading {
            HStack {
                Text(heading.title).font(Typeface.callout.weight(.semibold))
                Spacer()
                if !tasks.isEmpty { Text("\(done) of \(tasks.count) done").font(Typeface.caption) }
            }
            .foregroundStyle(theme.textSecondary.color)
            .padding(.horizontal, Space.s1)
            .padding(.top, Space.s3)
            .accessibilityAddTraits(.isHeader)
        }
        ForEach(tasks) { task in
            SharedTaskRow(shared: shared, list: list, task: task, model: model) { openTask = task.id }
        }
    }

    private func lastActivity(_ list: SharedListState) -> String? {
        guard let last = list.activity.last(where: { $0.kind != .added }), let task = list.tasks[last.taskID] else { return nil }
        return SharedActivityText.line(last, title: task.task.displayTitle, shared: shared) + " · " + last.date.formatted(.relative(presentation: .named))
    }
}

/// Words for what happened.
@MainActor enum SharedActivityText {
    static func line(_ activity: SharedActivity, title: String?, shared: SharedListsModel) -> String {
        let who = shared.shortName(of: activity.actor)
        let what = title.map { " “\($0)”" } ?? " this"
        switch activity.kind {
        case .added: return "\(who) added\(what)"
        case .ticked: return "\(who) ticked off\(what)"
        case .unticked: return "\(who) put back\(what)"
        case .dated: return "\(who) changed the date of\(what)"
        case .removed: return "\(who) removed\(what)"
        case .assigned(let to):
            guard let to else { return "\(who) unassigned\(what)" }
            return "\(who) assigned\(what) to \(to == shared.own ? "you" : shared.shortName(of: to))"
        }
    }
}

/// One task in a shared list, with its comments and what happened to it.
struct SharedTaskScreen: View {
    let shared: SharedListsModel
    let model: TasksModel
    let room: String
    let taskID: UUID
    let onBack: () -> Void
    @State private var commenting = false
    @State private var draft = ""
    @State private var assigning = false

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            HStack {
                HeaderButton("Back", systemImage: "chevron.left", action: onBack)
                Spacer()
                if shared.canEdit(room), let task = shared.list(room)?.tasks[taskID], !task.removed {
                    HeaderMenu("More", systemImage: "ellipsis") {
                        Button("Assign", systemImage: "person.crop.circle.badge.plus") { assigning = true }
                        Button("Remove from the list", systemImage: "trash", role: .destructive) {
                            onBack()
                            Task { await shared.remove(task: taskID, from: room) }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.top, Space.s2)
            if let list = shared.list(room), let task = list.tasks[taskID] {
                ScrollView {
                    content(list, task)
                        .padding(Space.s4)
                    Color.clear.frame(height: Metric.addButton + Space.s5)
                }
            } else {
                Spacer()
            }
        }
        .background(theme.bg.color.ignoresSafeArea())
        .edgeSwipeBack(onBack)
        .overlay(alignment: .bottom) {
            Button { commenting = true } label: {
                Label("Add a comment", systemImage: "bubble.left")
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .raisedField()
            }
            .buttonStyle(SoftPress())
            .padding(Space.s4)
        }
        .sheet(isPresented: $commenting) {
            CommentSheet(text: $draft) { send in
                commenting = false
                guard send else { return }
                let text = draft
                Task { if await shared.comment(text, on: taskID, in: room) { draft = "" } }
            }
        }
        .sheet(isPresented: $assigning) {
            AssignSheet(shared: shared, room: room, taskID: taskID) { assigning = false }
        }
    }

    private func content(_ list: SharedListState, _ task: SharedTask) -> some View {
        let theme = Theme.current
        let item = task.task
        let assignee = list.assignee(of: task)
        let comments = list.comments(on: taskID)
        let activity = list.activity(on: taskID)
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s3) {
                if shared.canEdit(room) {
                    TickBox(isDone: item.isCompleted, title: item.displayTitle) { Task { await shared.toggle(taskID, in: room) } }
                } else {
                    TickMark(isDone: item.isCompleted).frame(width: Space.s6, height: Space.s6)
                }
                Text(item.displayTitle)
                    .font(Typeface.title)
                    .foregroundStyle(theme.textPrimary.color)
            }
            HStack(spacing: Space.s1) {
                SharedChip(text: list.displayName)
                if let when = item.when { SharedChip(text: TaskText.day(when, today: model.today, in: model.calendar), isAccent: true) }
                if let assignee { SharedChip(text: shared.shortName(of: assignee), systemImage: "person") }
                else { SharedChip(text: "Unassigned") }
            }
            if list.isEncrypted { EncryptedLabel() }
            if item.hasNotes {
                Text(item.notes).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
            }
            Text(comments.isEmpty ? "Comments" : "Comments · \(comments.count)")
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(theme.textSecondary.color)
                .padding(.top, Space.s3)
            VStack(alignment: .leading, spacing: Space.s4) {
                if comments.isEmpty {
                    Text("No comments yet. Anyone in the list can comment.")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textSecondary.color)
                }
                ForEach(comments) { comment in
                    HStack(alignment: .top, spacing: Space.s3) {
                        SharedFace(shared: shared, username: comment.author, diameter: Space.s6)
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text("**\(shared.name(of: comment.author))** · \(comment.date.formatted(.relative(presentation: .named)))")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                            Text(comment.text)
                                .font(Typeface.body)
                                .foregroundStyle(theme.textPrimary.color)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .itemCard()
            if !activity.isEmpty {
                Text("Activity")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.top, Space.s3)
                ForEach(activity) { line in
                    Text(SharedActivityText.line(line, title: nil, shared: shared) + " · " + line.date.formatted(.relative(presentation: .named)))
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
        }
    }
}

/// Writing a comment. A sheet, so the task's screen holds no text field of its own.
struct CommentSheet: View {
    @Binding var text: String
    let onDone: (Bool) -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s3) {
                TextField("Comment", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .raisedField(.block)
                EncryptedLabel(detail: "End-to-end encrypted. Everyone in the list can read it, viewers too.")
                Spacer()
            }
            .padding(Space.s4)
            .background(theme.bg.color)
            .navigationTitle("Comment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(false) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onDone(true) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(theme.accent.color)
        .presentationDetents([.medium])
    }
}

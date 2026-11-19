import SwiftUI
import TotalityCore
import TotalityUI

/// What the Share sheet shares: a private list that becomes shared, or a shared list's room.
enum ShareTarget: Equatable {
    case list(TaskList, [TaskItem])
    case room(String)
}

/// A sheet with Cancel, a title and a main button.
private struct SharedSheetFrame<Content: View>: View {
    let title: String
    let confirm: String?
    var canConfirm = true
    let onCancel: () -> Void
    var onConfirm: () -> Void = {}
    @ViewBuilder let content: Content

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) { content }.padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                if let confirm {
                    ToolbarItem(placement: .confirmationAction) { Button(confirm, action: onConfirm).disabled(!canConfirm) }
                }
            }
        }
        .tint(theme.accent.color)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Typeface.caption.weight(.semibold))
            .foregroundStyle(Theme.current.textSecondary.color)
            .padding(.horizontal, Space.s1)
            .padding(.top, Space.s2)
    }
}

/// Share by handle or with someone you chat with, as Can edit or Can view.
struct ShareSheet: View {
    let shared: SharedListsModel
    let target: ShareTarget
    let onDone: (String?) -> Void
    @State private var handle = ""
    @State private var picked: Set<String> = []
    @State private var role = SharedRole.editor
    @State private var partners: [String] = []
    @State private var working = false

    private var people: [String] {
        var all = picked
        let typed = SharedListsModel.handle(handle)
        if !typed.isEmpty { all.insert(typed) }
        return all.sorted()
    }

    var body: some View {
        let theme = Theme.current
        SharedSheetFrame(title: "Share", confirm: working ? "Sending…" : "Send", canConfirm: !people.isEmpty && !working, onCancel: { onDone(nil) }, onConfirm: send) {
            Caption("Invite by handle")
            HStack {
                Text("@").foregroundStyle(theme.textSecondary.color)
                TextField("handle", text: $handle)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }
            .raisedField()
            if !partners.isEmpty {
                Caption("People you chat with")
                VStack(spacing: 0) {
                    ForEach(partners, id: \.self) { person in
                        Button {
                            if picked.contains(person) { picked.remove(person) } else { picked.insert(person) }
                        } label: {
                            HStack(spacing: Space.s3) {
                                SharedFace(shared: shared, username: person)
                                VStack(alignment: .leading) {
                                    Text(shared.name(of: person)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                    Text("@\(person)").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                                }
                                Spacer()
                                TickMark(isDone: picked.contains(person))
                            }
                            .padding(.vertical, Space.s2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SoftPress())
                    }
                }
                .itemCard()
            }
            Caption("They can")
            HStack(spacing: Space.s2) {
                FilterPill("Can edit", isSelected: role == .editor) { role = .editor }
                FilterPill("Can view", isSelected: role == .viewer) { role = .viewer }
            }
            Text("Can edit: add, tick off, assign and comment. Can view: read and comment.")
                .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            EncryptedLabel(detail: "End-to-end encrypted. Only the people in this list can read it; the server sees who's in it, not what's in it. Your other lists stay private.")
        }
        .task { partners = await shared.chatPartners() }
    }

    private func send() {
        working = true
        let invitees = Dictionary(uniqueKeysWithValues: people.map { ($0, role) })
        Task {
            switch target {
            case .list(let list, let tasks):
                onDone(await shared.share(list, tasks: tasks, with: invitees))
            case .room(let room):
                for person in invitees.keys.sorted() { _ = await shared.invite(person, as: role, to: room) }
                onDone(room)
            }
            working = false
        }
    }
}

/// Give a task to someone in the list who can edit.
struct AssignSheet: View {
    let shared: SharedListsModel
    let room: String
    let taskID: UUID
    let onDone: () -> Void
    @State private var choice: String?
    @State private var messageThem = false
    @State private var loaded = false

    var body: some View {
        let theme = Theme.current
        let list = shared.list(room)
        SharedSheetFrame(title: "Assign", confirm: "Done", onCancel: onDone, onConfirm: save) {
            Caption("People in this list")
            VStack(spacing: 0) {
                ForEach(list?.members.filter { !$0.isInvited } ?? []) { member in
                    Button { if member.role.canEdit { choice = choice == member.username ? nil : member.username } } label: {
                        HStack(spacing: Space.s3) {
                            SharedFace(shared: shared, username: member.username)
                            VStack(alignment: .leading) {
                                Text(shared.name(of: member.username)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                Text(member.role.name).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                            }
                            Spacer()
                            if member.role.canEdit { TickMark(isDone: choice == member.username) }
                            else { Text("View only").font(Typeface.caption).foregroundStyle(theme.textSecondary.color) }
                        }
                        .padding(.vertical, Space.s2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPress())
                    .disabled(!member.role.canEdit)
                }
            }
            .itemCard()
            Text("Only people who can edit can be given a task.").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            if let choice, choice != shared.own {
                Toggle(isOn: $messageThem) {
                    VStack(alignment: .leading) {
                        Text("Message \(shared.shortName(of: choice)) about it").font(Typeface.body)
                        Text("Sends a line in your chat with \(shared.shortName(of: choice))").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                }
                .itemCard()
            }
            EncryptedLabel(detail: "End-to-end encrypted. The assignment travels inside the list's encrypted room.")
        }
        .onAppear {
            guard !loaded, let list, let task = list.tasks[taskID] else { return }
            loaded = true
            choice = list.assignee(of: task)
        }
    }

    private func save() {
        let person = choice
        let message = messageThem
        onDone()
        Task { await shared.assign(taskID, in: room, to: person, messageThem: message) }
    }
}

/// Who's in a shared list. The owner changes roles and removes people; anyone can leave. The owner hands
/// it over before leaving, or deletes it for everyone.
struct PeopleSheet: View {
    let shared: SharedListsModel
    let room: String
    let onShare: () -> Void
    let onLeft: () -> Void
    let onDone: () -> Void
    @State private var removing: String?
    @State private var confirmLeave = false
    @State private var confirmDelete = false

    var body: some View {
        let theme = Theme.current
        let list = shared.list(room)
        let isOwner = shared.isOwner(room)
        SharedSheetFrame(title: "People", confirm: nil, onCancel: onDone) {
            Text(list?.displayName ?? "").font(Typeface.headline)
            VStack(spacing: 0) {
                ForEach(list?.members ?? []) { member in
                    HStack(spacing: Space.s3) {
                        SharedFace(shared: shared, username: member.username)
                        VStack(alignment: .leading) {
                            Text(shared.name(of: member.username)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                            Text("@\(member.username)" + (member.isInvited ? " · invited" : "")).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        }
                        Spacer()
                        if isOwner, member.username != shared.own {
                            Menu(member.role.name) {
                                Button("Can edit") { Task { await shared.setRole(.editor, for: member.username, in: room) } }
                                Button("Can view") { Task { await shared.setRole(.viewer, for: member.username, in: room) } }
                                Button("Remove", role: .destructive) { removing = member.username }
                            }
                            .font(Typeface.callout)
                        } else {
                            Text(member.role.name).font(Typeface.callout).foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    .padding(.vertical, Space.s2)
                }
            }
            .itemCard()
            if isOwner {
                HeaderPill("Invite someone", systemImage: "person.badge.plus") { onShare() }
                Menu("Make someone else the owner and leave") {
                    ForEach(list?.members.filter { $0.role.canEdit && !$0.isInvited && $0.username != shared.own } ?? []) { member in
                        Button(shared.name(of: member.username)) {
                            Task { if await shared.handOverAndLeave(room, to: member.username) { onDone(); onLeft() } }
                        }
                    }
                }
                .font(Typeface.callout)
                Text("To leave, make someone who can edit the owner first. Deleting removes it for all \(list?.members.count ?? 0) people.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                Button("Delete for everyone", role: .destructive) { confirmDelete = true }
            } else {
                Text("Only \(list?.owner.map { shared.shortName(of: $0.username) } ?? "the owner"), the owner, can change roles or remove people.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                Button("Leave this list", role: .destructive) { confirmLeave = true }
            }
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove \(removing.map(shared.shortName(of:)) ?? "")", role: .destructive) {
                if let person = removing { Task { await shared.remove(person, from: room) } }
                removing = nil
            }
        } message: {
            let name = removing.map(shared.shortName(of:)) ?? "They"
            Text("\(name) stops getting changes and can't read anything added after this. Their tasks go back to unassigned. What \(name) already saw stays on their phone.")
        }
        .confirmationDialog("Leave \(list?.displayName ?? "this list")?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { if await shared.leave(room) { onDone(); onLeft() } } }
        } message: {
            Text("Its tasks leave your Tasks. Your assigned tasks go back to unassigned. Your comments stay. The owner can invite you again.")
        }
        .confirmationDialog("Delete \(list?.displayName ?? "this list") for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete for everyone", role: .destructive) { Task { if await shared.deleteForEveryone(room) { onDone(); onLeft() } } }
        } message: {
            Text("It leaves everyone's Tasks. What people already saw stays on their phones.")
        }
    }

    private var removeTitle: String {
        "Remove \(removing.map(shared.shortName(of:)) ?? "")?"
    }
}

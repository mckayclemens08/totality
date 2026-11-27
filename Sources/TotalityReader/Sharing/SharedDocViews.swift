import SwiftUI
import TotalityCore
import TotalityUI

/// The Shared row at the top of the Reader (issue 228).
struct SharedDocsRow: View {
    let shared: SharedDocsModel

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Image(systemName: "person.2")
                .foregroundStyle(theme.accent.color)
                .frame(width: Space.s5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Shared")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text(detail)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            if !shared.invites.isEmpty {
                Text("\(shared.invites.count)")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.accentOn.color)
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, Space.s1 / 2)
                    .background(theme.accent.color, in: Capsule())
                    .accessibilityLabel("\(shared.invites.count) waiting")
            }
        }
        .padding(.vertical, Space.s1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task { await shared.refresh() }
    }

    private var detail: String {
        if case .unavailable = shared.phase { return "Needs Messages to connect" }
        let docs = shared.docs.count == 1 ? "1 doc" : "\(shared.docs.count) docs"
        switch shared.invites.count {
        case 0: return shared.docs.isEmpty ? "Docs you share with people" : docs
        case 1: return "\(docs) · 1 invitation"
        default: return "\(docs) · \(shared.invites.count) invitations"
        }
    }
}

struct SharedFace: View {
    let shared: SharedDocsModel
    let username: String
    var diameter: CGFloat = Space.s5 + Space.s1

    var body: some View {
        PersonFace(photo: shared.photo(of: username), name: username == shared.own ? "Me" : shared.name(of: username), diameter: diameter)
    }
}

/// The encryption line every sharing screen shows. It's literally true: the doc travels only inside
/// end-to-end encrypted room messages.
struct SharedEncryptedLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lock")
            .font(Typeface.caption)
            .foregroundStyle(Theme.current.success.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every shared doc and invitation.
struct SharedDocsView: View {
    let shared: SharedDocsModel

    var body: some View {
        let theme = Theme.current
        List {
            switch shared.phase {
            case .idle, .loading:
                ProgressView("Opening shared docs")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            case .unavailable(let reason):
                ReaderMessage(systemImage: "person.2.slash", title: "Sharing isn't available", detail: reason)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            case .ready:
                ForEach(shared.invites) { invite in
                    InviteRow(shared: shared, invite: invite)
                        .modifier(CardRow())
                }
                if shared.docs.isEmpty, shared.invites.isEmpty {
                    ReaderMessage(
                        systemImage: "person.2",
                        title: "Nothing shared yet",
                        detail: "Long press a doc and choose Share to write it with someone. Docs others share with you show up here."
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(shared.docs) { doc in
                    NavigationLink(value: ReaderRoute.sharedDoc(doc.room)) {
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(doc.isComplete ? doc.displayTitle : "Waiting for a copy")
                                .font(Typeface.headline)
                                .foregroundStyle(theme.textPrimary.color)
                            Text(shared.detail(of: doc))
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                        .padding(.vertical, Space.s1)
                    }
                    .modifier(CardRow())
                }
            }
            SharedEncryptedLine(text: "End-to-end encrypted. The server sees who a doc is shared with, never what's in it.")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .navigationTitle("Shared")
        .refreshable { await shared.refresh() }
        .task { await shared.refresh() }
    }

}

private struct InviteRow: View {
    let shared: SharedDocsModel
    let invite: SharedRoomInvite
    @State private var working = false

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(invite.inviter.map { "\(shared.name(of: $0)) shared a doc with you" } ?? "A doc was shared with you")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Accept to open it. Declining is quiet: they aren't told.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            HStack(spacing: Space.s2) {
                HeaderPill("Accept", isProminent: true) {
                    working = true
                    Task { await shared.accept(invite); working = false }
                }
                HeaderPill("Decline") {
                    working = true
                    Task { await shared.decline(invite); working = false }
                }
            }
            .disabled(working)
        }
        .padding(.vertical, Space.s1)
    }
}

/// A sheet with Cancel, a title and a main button.
struct SharedSheetFrame<Content: View>: View {
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
                ToolbarItem(placement: .cancellationAction) { Button(confirm == nil ? "Done" : "Cancel", action: onCancel) }
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

/// What the Share sheet shares: a private doc that becomes shared, or more people for a shared one.
enum ShareDocTarget: Equatable {
    case item(ReaderItem)
    case room(String)
}

/// Share by handle or with someone you chat with, each as Can edit or Can view.
struct ShareDocSheet: View {
    let model: ReaderModel
    let shared: SharedDocsModel
    let target: ShareDocTarget
    let onDone: (String?) -> Void
    @State private var handle = ""
    @State private var roles: [String: SharedRole] = [:]
    @State private var typedRole = SharedRole.editor
    @State private var partners: [String] = []
    @State private var working = false

    private var people: [String: SharedRole] {
        var all = roles
        let typed = SharedDocsModel.handle(handle)
        if !typed.isEmpty, typed != shared.own { all[typed] = all[typed] ?? typedRole }
        return all
    }

    private var title: String {
        switch target {
        case .item(let item): "Share “\(item.displayTitle)”"
        case .room: "Invite"
        }
    }

    var body: some View {
        let theme = Theme.current
        SharedSheetFrame(
            title: title, confirm: working ? "Sharing…" : "Share", canConfirm: !people.isEmpty && !working,
            onCancel: { onDone(nil) }, onConfirm: send
        ) {
            SharedEncryptedLine(text: "End-to-end encrypted. Only the people you pick can read it. The server sees who it's shared with, not what it says.")
            if !partners.isEmpty {
                Caption("People you chat with")
                VStack(spacing: 0) {
                    ForEach(partners, id: \.self) { person in
                        personRow(person)
                    }
                }
                .itemCard()
            }
            Caption("Someone else, by handle")
            HStack {
                Text("@").foregroundStyle(theme.textSecondary.color)
                TextField("handle", text: $handle)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }
            .raisedField()
            HStack(spacing: Space.s2) {
                FilterPill("Can edit", isSelected: typedRole == .editor) { typedRole = .editor }
                FilterPill("Can view", isSelected: typedRole == .viewer) { typedRole = .viewer }
            }
            Text("Can edit: write and change the doc. Can view: read it.")
                .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            if case .item = target {
                Text("Your private copy moves to Recently Deleted, where you can restore it, so there's one copy everyone writes in. Images in your Reader don't travel with the doc yet.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { partners = await shared.chatPartners() }
    }

    private func personRow(_ person: String) -> some View {
        let theme = Theme.current
        let role = roles[person]
        return HStack(spacing: Space.s3) {
            SharedFace(shared: shared, username: person)
            VStack(alignment: .leading) {
                Text(shared.name(of: person)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                Text("@\(person)").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
            Spacer()
            Menu(role?.name ?? "Add") {
                Button("Can edit") { roles[person] = .editor }
                Button("Can view") { roles[person] = .viewer }
                if role != nil { Button("Don't share", role: .destructive) { roles[person] = nil } }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.accent.color)
        }
        .padding(.vertical, Space.s2)
    }

    private func send() {
        working = true
        let invitees = people
        Task {
            switch target {
            case .item(let item):
                onDone(await model.share(item, with: invitees))
            case .room(let room):
                for (person, role) in invitees.sorted(by: { $0.key < $1.key }) { _ = await shared.invite(person, as: role, to: room) }
                onDone(room)
            }
            working = false
        }
    }
}

/// Who a doc is shared with, and the owner's controls.
struct SharedPeopleSheet: View {
    let model: ReaderModel
    let shared: SharedDocsModel
    let room: String
    let onInvite: () -> Void
    let onGone: () -> Void
    let onDone: () -> Void
    @State private var removing: String?
    @State private var confirmLeave = false
    @State private var confirmStop = false

    var body: some View {
        let theme = Theme.current
        let doc = shared.doc(room)
        let isOwner = shared.isOwner(room)
        SharedSheetFrame(title: "People", confirm: nil, onCancel: onDone) {
            Text(doc?.displayTitle ?? "").font(Typeface.headline)
            VStack(spacing: 0) {
                ForEach(doc?.members ?? []) { member in
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
                HeaderPill("Invite someone", systemImage: "person.badge.plus") { onInvite() }
                Button("Stop sharing for everyone", role: .destructive) { confirmStop = true }
                    .font(Typeface.callout)
                Text("It leaves everyone's Reader, and a private copy stays in yours.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            } else {
                Text("Only \(doc?.owner.map { shared.name(of: $0.username) } ?? "the owner"), the owner, can change who it's shared with.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                Button("Leave this doc", role: .destructive) { confirmLeave = true }
                    .font(Typeface.callout)
            }
            SharedEncryptedLine(text: "End-to-end encrypted. Removing someone stops new changes reaching them. What they already saw stays on their devices.")
        }
        .confirmationDialog(
            "Remove \(removing.map(shared.name(of:)) ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let person = removing { Task { await shared.remove(person, from: room) } }
                removing = nil
            }
        } message: {
            Text("They stop getting changes and can't read anything written after this. What they already saw stays on their devices.")
        }
        .confirmationDialog("Leave \(doc?.displayTitle ?? "this doc")?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { if await shared.leave(room) { onDone(); onGone() } } }
            Button("Keep a private copy and leave") {
                Task {
                    if let doc { await model.keepPrivateCopy(title: doc.title, text: doc.text) }
                    if await shared.leave(room) { onDone(); onGone() }
                }
            }
        } message: {
            Text("It leaves your Reader. The owner can invite you again.")
        }
        .confirmationDialog("Stop sharing \(doc?.displayTitle ?? "this doc")?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) {
                Task {
                    // The copy is made first, so a failure part way can never lose the doc.
                    guard let doc, doc.isComplete, await model.keepPrivateCopy(title: doc.title, text: doc.text) != nil else { return }
                    if await shared.stopSharing(room) != nil {
                        onDone()
                        onGone()
                    }
                }
            }
        } message: {
            Text("It leaves everyone's Reader, and a private copy goes back into yours. What people already saw stays on their devices.")
        }
    }
}

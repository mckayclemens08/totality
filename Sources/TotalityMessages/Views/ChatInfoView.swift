import SwiftUI
import TotalityCore
import TotalityUI

/// A group or broadcast channel's info screen, opened by tapping its title: name and photo, who's in it,
/// who runs it, how it's protected, and the settings that are yours to change.
struct ChatInfoView: View {
    let chat: ChatModel
    let messages: MessagesModel
    /// You left, so the chat itself should close too.
    let onLeft: () -> Void
    let onDone: () -> Void

    @State private var members: [ChatMember] = []
    @State private var loaded = false
    @State private var photo: Data?
    @State private var muted = false
    @State private var editing = false
    @State private var adding = false
    @State private var confirmingLeave = false
    @State private var reporting = false
    @State private var reported = false
    @State private var pendingSetting: Disappearing?
    @State private var problem: String?

    private var isChannel: Bool { chat.channelAccess != nil }
    private var ownID: String? { messages.userID }
    private var level: Int {
        if loaded, let own = ownID, members.contains(where: { $0.id == own }) { return ChatRoster.level(of: own, in: members) }
        return chat.channelAccess?.level ?? ChannelPower.follower
    }
    private var invitedPeople: [ChatMember] { members.filter(\.invited) }
    /// People who accepted. Invited ones aren't followers, though Matrix and the size cap count them.
    private var followerCount: Int { loaded ? ChannelCounts.followers(members: members.count, invited: invitedPeople.count) : chat.channelFollowers }
    private var permissions: ChatPermissions { ChatPermissions(isChannel: isChannel, level: level) }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    header
                    if let problem {
                        Text(problem).font(Typeface.caption).foregroundStyle(theme.danger.color)
                    }
                    if reported {
                        Banner(text: "Reported. Thank you. Nothing from this chat was sent with it.")
                    }
                    protection
                    peopleCard
                    settingsCard
                    dangerCard
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(isChannel ? "Channel info" : "Group info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
        .tint(theme.accent.color)
        .task { await reload() }
        .task(id: chat.groupPhotoLocation) {
            guard let location = chat.groupPhotoLocation else { photo = nil; return }
            photo = await messages.groupPhoto(location)
        }
        .onAppear { muted = MutedChats.isMuted(chat.chatID) }
        .sheet(isPresented: $editing, onDismiss: { Task { await reload() } }) {
            GroupDetailsView(chat: chat, messages: messages) { editing = false }
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await reload() } }) {
            InviteToChannelView(model: messages, chat: chat.chatID, members: members.isEmpty ? chat.channelMembers : members.count, invited: invitedPeople.count, isGroup: !isChannel) { adding = false }
        }
        .confirmationDialog(
            isChannel ? "Leave this channel?" : "Leave this group?", isPresented: $confirmingLeave, titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task { if await messages.leave(chat.chatID) { onLeft() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text([permissions.leaveWarning, "It goes from your list, and you won't get new messages from it unless someone adds you again."]
                .compactMap { $0 }.joined(separator: " "))
        }
        .confirmationDialog("Report this \(isChannel ? "channel" : "group")?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.label) { Task { await send(report: reason) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ChatInfoLabels.reportDetail)
        }
        .confirmationDialog(
            "Disappearing messages: \(pendingSetting?.label.lowercased() ?? "")?",
            isPresented: Binding(get: { pendingSetting != nil }, set: { if !$0 { pendingSetting = nil } }),
            titleVisibility: .visible, presenting: pendingSetting
        ) { setting in
            Button("Turn on for everyone here") { Task { await chat.setDisappearing(setting) } }
            Button("Cancel", role: .cancel) {}
        } message: { setting in
            Text("\(setting.explanation) Everyone in this chat sees that you turned it on.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s2) {
            Group {
                if let photo {
                    OpenedImage(data: photo).scaledToFill()
                } else if isChannel {
                    Image(systemName: "megaphone.fill")
                        .font(Typeface.title)
                        .foregroundStyle(theme.accent.color)
                } else {
                    Text(chat.title.first.map { String($0).uppercased() } ?? "?")
                        .font(Typeface.display)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .frame(width: Space.s8 * 1.5, height: Space.s8 * 1.5)
            .background(theme.surface.color)
            .clipShape(Circle())
            .accessibilityHidden(true)
            Text(chat.title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            if !isChannel {
                Label(GroupLabels.notEncrypted, systemImage: "lock.open")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
            }
            if permissions.canRename {
                Button("Change name and photo") { editing = true }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.s2)
    }

    private var subtitle: String {
        if isChannel { return "Broadcast channel · \(ChannelLabels.followers(followerCount))" }
        return "Group" + (loaded ? " · \(ChatInfoLabels.memberCount(members.count - invitedPeople.count))" : "")
    }

    private var protection: some View {
        let theme = Theme.current
        return card {
            Label(isChannel ? ChatInfoLabels.channelEncrypted : ChatInfoLabels.groupEncrypted, systemImage: "lock.fill")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            if isChannel { Text(ChannelLabels.nameNotEncrypted).font(Typeface.caption).foregroundStyle(theme.textSecondary.color) }
        }
    }

    @ViewBuilder private var peopleCard: some View {
        let theme = Theme.current
        let admins = ChatRoster.admins(members)
        card {
            if isChannel {
                SectionLabel("Followers")
                Text(ChannelLabels.followers(followerCount))
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                Text(ChannelLabels.followersVisible)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                if !invitedPeople.isEmpty && permissions.canAddPeople {
                    SectionLabel("Invited (\(invitedPeople.count))")
                    ForEach(invitedPeople) { member in row(member) }
                    Text("Invited people count toward the \(ChannelLimits.maxMembers)-person limit until they accept or you take the invite back.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                SectionLabel("Admins")
            } else {
                SectionLabel("Admins")
            }
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if admins.isEmpty {
                Text("No one else runs this \(isChannel ? "channel" : "group").")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            } else {
                ForEach(admins) { member in row(member) }
            }
            Text(ChatInfoLabels.adminsNote(canManage: permissions.canManageAdmins))
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            if !isChannel {
                SectionLabel("Members")
                if loaded {
                    ForEach(ChatRoster.ordered(members, name: displayName)) { member in row(member) }
                    Text(ChatInfoLabels.groupMembersVisible)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            if permissions.canAddPeople {
                Button { adding = true } label: {
                    Label(isChannel ? "Invite followers" : "Add people", systemImage: "person.badge.plus")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var settingsCard: some View {
        let theme = Theme.current
        return card {
            HStack {
                Text("Disappearing messages").font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: Space.s2)
                TimerChip(setting: chat.disappearing) { setting in
                    if setting == .off {
                        Task { await chat.setDisappearing(.off) }
                    } else if setting != chat.disappearing {
                        pendingSetting = setting
                    }
                }
            }
            Toggle(isOn: Binding(get: { muted }, set: { on in
                muted = on
                MutedChats.set(chat.chatID, muted: on)
            })) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Mute notifications").font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                    Text(ChatInfoLabels.muteDetail).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                }
            }
        }
    }

    private var dangerCard: some View {
        let theme = Theme.current
        return card {
            Button { confirmingLeave = true } label: {
                Label(isChannel ? "Leave channel" : "Leave group", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.danger.color)
            }
            .buttonStyle(.plain)
            Button { reporting = true } label: {
                Label(isChannel ? "Report channel" : "Report group", systemImage: "exclamationmark.bubble")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.danger.color)
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ member: ChatMember) -> some View {
        let theme = Theme.current
        let own = member.id == ownID
        let name = own ? "You" : displayName(member.id)
        return HStack(spacing: Space.s3) {
            PersonFace(photo: messages.people.profile(ofMatrixID: member.id)?.photo, name: name, diameter: Space.s6 + Space.s1)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(Typeface.body).foregroundStyle(theme.textPrimary.color).lineLimit(1)
                Text("@\(MessagesUsername.display(member.id))")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            }
            Spacer(minLength: Space.s2)
            Text(member.role).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            if member.invited, isChannel, permissions.canAddPeople {
                Menu {
                    Button("Cancel invite", systemImage: "xmark.circle", role: .destructive) { Task { await cancelInvite(member) } }
                } label: {
                    ToolbarGlyph(systemImage: "ellipsis")
                }
                .accessibilityLabel("Manage invite for \(name)")
            } else if permissions.canManageAdmins, !own, !member.isOwner, !member.invited {
                Menu {
                    if member.isAdmin {
                        Button("Remove as admin", systemImage: "person.badge.minus") { Task { await setAdmin(member, to: false) } }
                    } else {
                        Button("Make admin", systemImage: "person.badge.shield.checkmark") { Task { await setAdmin(member, to: true) } }
                    }
                } label: {
                    ToolbarGlyph(systemImage: "ellipsis")
                }
                .accessibilityLabel("Manage \(name)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s3, content: content)
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    // MARK: Actions

    private func displayName(_ id: String) -> String { messages.people.name(ofMatrixID: id) }

    private func reload() async {
        members = await chat.loadMembers()
        problem = chat.notice
        chat.notice = nil
        loaded = true
        await messages.people.want(matrixIDs: members.map(\.id))
    }

    private func setAdmin(_ member: ChatMember, to isAdmin: Bool) async {
        if await chat.setAdmin(member.id, to: isAdmin) {
            problem = nil
            await reload()
        } else {
            problem = chat.notice
            chat.notice = nil
        }
    }

    private func cancelInvite(_ member: ChatMember) async {
        if await chat.cancelInvite(member.id) {
            problem = nil
            await reload()
        } else {
            problem = chat.notice
            chat.notice = nil
        }
    }

    private func send(report reason: ReportReason) async {
        if await chat.report(reason.sentence) {
            reported = true
            problem = nil
        } else {
            problem = chat.notice
            chat.notice = nil
        }
    }
}

/// Why someone reports a chat. The server's admins read the sentence, nothing else.
enum ReportReason: CaseIterable, Identifiable {
    case spam, abuse, other

    var id: Self { self }
    var label: String {
        switch self {
        case .spam: "Spam"
        case .abuse: "Abuse or harassment"
        case .other: "Something else"
        }
    }
    var sentence: String {
        switch self {
        case .spam: "Reported as spam"
        case .abuse: "Reported for abuse or harassment"
        case .other: "Reported by a member"
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typeface.headline)
            .foregroundStyle(Theme.current.textPrimary.color)
            .accessibilityAddTraits(.isHeader)
    }
}

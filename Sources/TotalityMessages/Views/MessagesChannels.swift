import SwiftUI
import TotalityUI

/// What a channel's chat says at the top, in place of the usual encryption line.
struct ChannelNote: View {
    let access: ChannelAccess
    let followers: Int
    var invited = 0

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            Label("Broadcast channel · \(ChannelLabels.followers(followers))\(invited > 0 && access.canInvite ? " · \(invited) invited" : "")", systemImage: "megaphone")
                .font(Typeface.caption.weight(.semibold))
            Text(ChannelLabels.encrypted)
            Text(ChannelLabels.nameNotEncrypted)
            if access.canPost { Text(ChannelLabels.followersVisible) }
        }
        .font(Typeface.caption)
        .foregroundStyle(theme.textSecondary.color)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s3)
    }
}

/// Where the composer would be for someone who can't post: a note, and a way to reach the owner privately.
struct ChannelFollowerBar: View {
    let owner: String?
    let onMessageOwner: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            Text(ChannelLabels.followerNote)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            if let owner {
                Button(ChannelLabels.messageOwner(MessagesUsername.display(owner)), action: onMessageOwner)
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Space.s4)
        .background(theme.bg.color)
    }
}

/// Starts a channel: a name, and optionally the admins who can post with you. Followers are invited after.
struct NewChannelView: View {
    let model: MessagesModel
    let onDone: (String?) -> Void
    @State private var name = ""
    @State private var admins = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s4) {
                TextField("Channel name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Typeface.body)
                    .raisedField()
                    .accessibilityLabel("Channel name")
                UsernameField(
                    people: model.people, text: $admins, placeholder: "admins who can post too (optional)",
                    label: "Admin usernames", multiple: true, followersOnly: true
                )
                Text(ChannelInviteRule.line)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                Group {
                    Text(ChannelLabels.encrypted)
                    Text(ChannelLabels.nameNotEncrypted)
                    Text(ChannelLabels.inviteOnly)
                    Text("Up to \(ChannelLimits.maxMembers) people. \(ChannelLabels.followersVisible)")
                }
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                if let problem {
                    Text(problem).font(Typeface.caption).foregroundStyle(theme.danger.color)
                }
                Spacer()
            }
            .padding(Space.s5)
            .background(theme.bg.color)
            .navigationTitle("New channel")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Create", action: start)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .tint(theme.accent.color)
        .onChange(of: name) { problem = nil }
    }

    private func start() {
        guard !working else { return }
        working = true
        Task {
            let chat = await model.startChannel(name: name, admins: admins)
            working = false
            if let chat {
                onDone(chat)
            } else {
                problem = model.notice
                model.notice = nil
            }
        }
    }
}

/// Invite followers to a channel by username.
struct InviteToChannelView: View {
    let model: MessagesModel
    let chat: String
    /// Everyone in the room, invited ones included, as the size cap counts them.
    let members: Int
    var invited = 0
    /// A group's "add people" rather than a channel's "invite followers".
    var isGroup = false
    let onDone: () -> Void
    @State private var usernames = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s4) {
                UsernameField(
                    people: model.people, text: $usernames, placeholder: "username, username",
                    label: "Usernames to invite", multiple: true, autofocus: true, followersOnly: !isGroup
                )
                Text(summary)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                if let problem {
                    Text(problem).font(Typeface.caption).foregroundStyle(theme.danger.color)
                }
                Spacer()
            }
            .padding(Space.s5)
            .background(theme.bg.color)
            .navigationTitle(isGroup ? "Add people" : "Invite followers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(isGroup ? "Add" : "Invite", action: invite)
                            .disabled(usernames.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .tint(theme.accent.color)
        .onChange(of: usernames) { problem = nil }
    }

    private var summary: String {
        if isGroup {
            return "\(ChatInfoLabels.memberCount(members)). Room for \(max(0, GroupMembers.limit - members)) more. Each person gets a request to accept."
        }
        let pending = invited > 0 ? ", and \(invited) invited" : ""
        return "\(ChannelInviteRule.line) \(ChannelLabels.followers(ChannelCounts.followers(members: members, invited: invited)))\(pending). Room for \(ChannelLimits.room(members: members)) more, counting people invited. Each person gets a request to accept."
    }

    private func invite() {
        guard !working else { return }
        working = true
        Task {
            let ok = isGroup
                ? await model.addPeople(usernames, toGroup: chat, current: members)
                : await model.invite(usernames, toChannel: chat)
            working = false
            if ok {
                onDone()
            } else {
                problem = model.notice
                model.notice = nil
            }
        }
    }
}

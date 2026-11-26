import SwiftUI
import TotalityUI

/// What a channel's chat says at the top, in place of the usual encryption line.
struct ChannelNote: View {
    let access: ChannelAccess
    let followers: Int

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            Label("Broadcast channel · \(ChannelLabels.followers(followers))", systemImage: "megaphone")
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
                TextField("Admins who can post too (optional)", text: $admins, axis: .vertical)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .font(Typeface.body)
                    .lineLimit(1...3)
                    .raisedField()
                    .accessibilityLabel("Admin usernames")
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
    let members: Int
    let onDone: () -> Void
    @State private var usernames = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s4) {
                TextField("Usernames, separated by commas", text: $usernames, axis: .vertical)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .font(Typeface.body)
                    .lineLimit(1...4)
                    .raisedField()
                    .accessibilityLabel("Usernames to invite")
                Text("\(ChannelLabels.followers(max(0, members - 1))). Room for \(ChannelLimits.room(members: members)) more. Each person gets a request to accept.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                if let problem {
                    Text(problem).font(Typeface.caption).foregroundStyle(theme.danger.color)
                }
                Spacer()
            }
            .padding(Space.s5)
            .background(theme.bg.color)
            .navigationTitle("Invite followers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Invite", action: invite)
                            .disabled(usernames.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .tint(theme.accent.color)
        .onChange(of: usernames) { problem = nil }
    }

    private func invite() {
        guard !working else { return }
        working = true
        Task {
            let ok = await model.invite(usernames, toChannel: chat)
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

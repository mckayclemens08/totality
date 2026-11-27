import SwiftUI
import TotalityCore
import TotalityUI

/// This device's choice to hide like counts everywhere, on everyone's posts. It holds no content.
enum LikeCountsPreference {
    static let key = "social.hideLikeCounts"
}

/// Reporting a person, a post or a comment. Nothing is sent until a reason is pressed.
struct ReportSheet: View {
    let model: SocialModel
    let username: String
    let post: SocialPost?
    let comment: SocialComment?
    var backgroundKey: String? = nil
    let onClose: () -> Void
    @State private var sending = false

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text(comment != nil ? "Report comment" : post != nil ? "Report post" : "Report \(Handle.display(username))").font(Typeface.title)
                Spacer()
                HeaderButton("Close", systemImage: "xmark", action: onClose)
            }
            Text(post.map { $0.audience.isEncrypted } == true
                 ? "This post is end-to-end encrypted, so the moderator sees only who you reported and why, not the post."
                 : "Reports go to Totality's moderator. \(Handle.display(username)) isn't told who reported them.")
                .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            ScrollView {
                VStack(spacing: Space.s2) {
                    if let backgroundKey {
                        Button {
                            Task {
                                sending = true
                                if await model.reportBackground(username, key: backgroundKey) { onClose() }
                                sending = false
                            }
                        } label: {
                            Text("Background image").font(Typeface.body).foregroundStyle(theme.textPrimary.color).itemCard()
                        }
                        .buttonStyle(SoftPress())
                        .disabled(sending)
                    }
                    ForEach(ReportReason.allCases) { reason in
                        Button {
                            Task {
                                sending = true
                                if await model.report(username, post: post, comment: comment, reason: reason) { onClose() }
                                sending = false
                            }
                        } label: {
                            Text(reason.rawValue).font(Typeface.body).foregroundStyle(theme.textPrimary.color).itemCard()
                        }
                        .buttonStyle(SoftPress())
                        .disabled(sending)
                    }
                }
            }
        }
        .padding(Space.s4)
        .background(theme.bg.color.ignoresSafeArea())
    }
}

/// Your Social privacy: private account, who can comment, who can message you, and like counts.
struct PrivacySettingsView: View {
    let model: SocialModel
    let onClose: () -> Void
    @State private var draft = SocialSettings()
    @State private var saving = false
    @AppStorage(LikeCountsPreference.key) private var hideEverywhere = false

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s5) {
                HStack {
                    Button("Cancel", action: onClose).foregroundStyle(theme.textSecondary.color)
                    Spacer()
                    Text("Privacy").font(Typeface.headline)
                    Spacer()
                    HeaderPill(saving ? "Saving…" : "Save", isProminent: true) {
                        Task {
                            saving = true
                            if await model.save(draft) { onClose() }
                            saving = false
                        }
                    }
                    .disabled(saving || draft == model.settings)
                }
                SettingToggle(
                    title: "Private account", isOn: $draft.privateAccount,
                    detail: "Your public posts are seen only by followers you approve. Your profile's photo, background, name and bio stay public."
                )
                ReachPicker(title: "Who can comment on your posts", choices: Reach.allCases, selection: $draft.whoCanComment)
                ReachPicker(title: "Who can message you", choices: Reach.forMessages, selection: $draft.whoCanMessage)
                Text("Messages checks this before starting a new chat with you. Until Totality's chat server enforces it too, a modified app could still send a first message.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                SettingToggle(title: "Hide like counts on my posts", isOn: $draft.hideLikeCounts,
                              detail: "Other people won't see how many likes your public posts have. You still will.")
                SettingToggle(title: "Hide like counts everywhere", isOn: $hideEverywhere,
                              detail: "On this phone, no post shows its like count. This one is saved right away.")
            }
            .padding(Space.s4)
        }
        .background(theme.bg.color.ignoresSafeArea())
        .onAppear { draft = model.settings }
    }
}

struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s1) {
            Toggle(title, isOn: $isOn).font(Typeface.headline).tint(theme.accent.color)
            Text(detail).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
        }
        .itemCard()
    }
}

struct ReachPicker: View {
    let title: String
    let choices: [Reach]
    @Binding var selection: Reach

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            // The pills keep their whole word, so four of them are wider than a phone. Left in a plain
            // HStack they widened the whole sheet past the screen; they wrap inside the margins instead.
            ChipFlow {
                ForEach(choices) { choice in
                    FilterPill(choice.name, isSelected: selection == choice) { selection = choice }
                }
            }
            .padding(.vertical, Space.s1)
        }
    }
}

/// Lays pills out in rows, wrapping as they run out of room, so a row never pushes past the sheet's margins.
private struct ChipFlow: Layout {
    var spacing: CGFloat = Space.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// People asking to follow your private account.
struct FollowRequestsView: View {
    let model: SocialModel
    let onClose: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Follow requests").font(Typeface.title)
                Spacer()
                HeaderButton("Close", systemImage: "xmark", action: onClose)
            }
            if model.followRequests.isEmpty {
                EmptyFeed(systemImage: "person.crop.circle.badge.checkmark", title: "No requests", detail: "When someone asks to follow your private account, they show here.")
            }
            ScrollView {
                VStack(spacing: Space.s2) {
                    ForEach(model.followRequests, id: \.self) { name in
                        HStack(spacing: Space.s3) {
                            PersonFace(photo: model.photos[name], name: name, diameter: Space.s6)
                            Text(Handle.display(name)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                            Spacer()
                            HeaderPill("Decline") { Task { await model.answerRequest(name, approve: false) } }
                            HeaderPill("Approve", isProminent: true) { Task { await model.answerRequest(name, approve: true) } }
                        }
                        .itemCard()
                    }
                }
            }
        }
        .padding(Space.s4)
        .background(theme.bg.color.ignoresSafeArea())
    }
}

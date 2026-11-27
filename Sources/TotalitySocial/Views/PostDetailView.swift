import SwiftUI
import TotalityCore
import TotalityUI

/// One post, opened: the whole text, its tags, why For You showed it, likes, and the comments with replies.
struct PostDetailView: View {
    let model: SocialModel
    let id: UUID
    let open: (SocialHomeView.Route) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [SocialComment] = []
    @State private var commentsProblem: String?
    @State private var draft = ""
    @State private var replyingTo: SocialComment?
    @State private var sending = false
    @State private var reporting: SocialComment?
    /// The author's settings that matter here: whether you may comment.
    @State private var authorProfile: SocialProfile?

    var body: some View {
        let theme = Theme.current
        Group {
            if let post = model.post(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        author(post)
                        if !post.media.isEmpty { PostMediaView(model: model, post: post) }
                        VStack(alignment: .leading, spacing: Space.s3) {
                            if let title = post.title { Text(title).font(Typeface.title).foregroundStyle(theme.textPrimary.color) }
                            if !post.body.isEmpty {
                                Text(PostTags.linked(post.body)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                    .tint(theme.accent.color).textSelection(.enabled)
                            }
                            let extra = PostTags.notInText(post.tags, text: (post.title ?? "") + " " + post.body)
                            if !extra.isEmpty {
                                Text(PostTags.linked(extra.map { "#" + $0 }.joined(separator: " "))).font(Typeface.callout)
                                    .tint(theme.accent.color)
                            }
                            if post.edited { Text("Edited").font(Typeface.micro).foregroundStyle(theme.textSecondary.color) }
                            if let reason = post.reason {
                                Text("Why am I seeing this? \(reason)").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                            }
                        }
                        .itemCard()
                        .likesOnDoubleTap { Task { await model.like(post) } }
                        actions(post)
                        commentList
                    }
                    .padding(Space.s4)
                }
                .safeAreaInset(edge: .bottom) {
                    if post.audience == .everyone, let authorProfile, !authorProfile.canComment, post.author != model.me {
                        Text("\(post.displayName) has turned comments off for you.")
                            .font(Typeface.caption).foregroundStyle(Theme.current.textSecondary.color)
                            .frame(maxWidth: .infinity).padding(Space.s3)
                    } else {
                        commentBox(post)
                    }
                }
                .task(id: post.comments) { await loadComments(post) }
                .task { if post.audience == .everyone { authorProfile = try? await model.profile(post.author) } }
                .sheet(item: $reporting) { comment in
                    ReportSheet(model: model, username: comment.author, post: post, comment: comment) { reporting = nil }
                }
            } else {
                EmptyFeed(systemImage: "questionmark.circle", title: "This post isn't here any more", detail: "Its author may have deleted it.")
                    .task { await model.fetchPost(id) }
            }
        }
        .background(theme.bg.color.ignoresSafeArea())
        // The post screen shows its own notice, so "Saved to the Reader." appears where it was asked for.
        .noticeBanner(Binding(get: { model.notice }, set: { model.notice = $0 }))
    }

    private func author(_ post: SocialPost) -> some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            HeaderButton("Back", systemImage: "chevron.left") { dismiss() }
            Button { open(.profile(post.author)) } label: {
                HStack(spacing: Space.s3) {
                    PersonFace(photo: model.photos[post.author], name: post.displayName, diameter: Space.s6 + Space.s1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(post.displayName).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        Text("\(Handle.display(post.author)) · \(post.date.formatted(.relative(presentation: .numeric)))")
                            .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                }
            }
            .buttonStyle(SoftPress())
            Spacer(minLength: 0)
            PostTopIcons(model: model, post: post) { dismiss() }
        }
    }

    private func actions(_ post: SocialPost) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            PostPlainActions(model: model, post: post)
            Label(post.audience.label, systemImage: post.audience.systemImage)
                .font(Typeface.caption)
                .foregroundStyle(post.audience.isEncrypted ? theme.success.color : theme.textSecondary.color)
        }
    }

    @ViewBuilder
    private var commentList: some View {
        let theme = Theme.current
        if let commentsProblem {
            Text(commentsProblem).font(Typeface.caption).foregroundStyle(theme.danger.color)
        }
        ForEach(comments) { comment in
            HStack(alignment: .top, spacing: Space.s3) {
                PersonFace(photo: model.photos[comment.author], name: comment.authorName ?? comment.author, diameter: Space.s5 + Space.s1)
                VStack(alignment: .leading, spacing: Space.s1) {
                    (Text(comment.author).bold() + Text("  " + comment.body))
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                    HStack(spacing: Space.s3) {
                        Text(comment.date.formatted(.relative(presentation: .numeric)))
                        if comment.parent == nil {
                            Button("Reply") { replyingTo = comment }.foregroundStyle(theme.accent.color)
                        }
                        if comment.author != model.me {
                            Button("Report") { reporting = comment }
                        }
                    }
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                }
            }
            .padding(.leading, comment.parent == nil ? 0 : Space.s6)
        }
    }

    private func commentBox(_ post: SocialPost) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            if let replyingTo {
                HStack {
                    Text("Replying to \(Handle.display(replyingTo.author))").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    Button("Cancel") { self.replyingTo = nil }.font(Typeface.caption)
                }
            }
            HStack(spacing: Space.s2) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .raisedField()
                Button {
                    Task {
                        sending = true
                        if await model.comment(draft, on: post, replyingTo: replyingTo?.id) {
                            draft = ""
                            replyingTo = nil
                        }
                        sending = false
                    }
                } label: {
                    Text("Post").font(Typeface.callout).foregroundStyle(theme.accentOn.color)
                        .padding(.horizontal, Space.s4).frame(minHeight: Metric.headerButton)
                        .background(Capsule().fill(theme.accent.color))
                }
                .buttonStyle(SoftPress())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .padding(Space.s3)
        .background(theme.bg.color)
    }

    private func loadComments(_ post: SocialPost) async {
        do {
            comments = try await model.comments(on: post)
            commentsProblem = nil
        } catch {
            commentsProblem = "Comments didn't load. Pull down on the feed and try again."
        }
    }
}

/// A like count as it should show: a number, or just "Like" when it's hidden by the author or on this phone.
enum LikeText {
    static func count(_ post: SocialPost, hideEverywhere: Bool) -> String {
        if hideEverywhere || post.likesHidden { return post.liked ? "Liked" : "Like" }
        return "\(post.likes)"
    }
}

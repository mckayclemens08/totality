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
    @State private var confirmingDelete = false
    @State private var reporting: SocialComment?
    @State private var reportingPost = false
    /// The author's settings that matter here: whether you may comment.
    @State private var authorProfile: SocialProfile?
    @AppStorage(LikeCountsPreference.key) private var hideEverywhere = false
    @State private var taskDraft: TaskDraft?

    var body: some View {
        let theme = Theme.current
        Group {
            if let post = model.post(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        author(post)
                        VStack(alignment: .leading, spacing: Space.s3) {
                            if let title = post.title { Text(title).font(Typeface.title).foregroundStyle(theme.textPrimary.color) }
                            Text(post.body).font(Typeface.body).foregroundStyle(theme.textPrimary.color).textSelection(.enabled)
                            if !post.tags.isEmpty {
                                Text(post.tags.map { "#" + $0 }.joined(separator: " ")).font(Typeface.callout).foregroundStyle(theme.accent.color)
                            }
                            if post.edited { Text("Edited").font(Typeface.micro).foregroundStyle(theme.textSecondary.color) }
                            if let reason = post.reason {
                                Text("Why am I seeing this? \(reason)").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                            }
                        }
                        .itemCard()
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
                .sheet(isPresented: $reportingPost) {
                    ReportSheet(model: model, username: post.author, post: post, comment: nil) { reportingPost = false }
                }
                .sheet(item: $reporting) { comment in
                    ReportSheet(model: model, username: comment.author, post: post, comment: comment) { reporting = nil }
                }
                .confirmationDialog("Delete this post?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete for everyone", role: .destructive) {
                        Task { await model.delete(post); dismiss() }
                    }
                } message: {
                    Text(post.audience == .everyone
                         ? "It's removed from Totality's server. Anyone who already saw it may remember it."
                         : "It's removed from your encrypted room. People who already opened it keep what they saw.")
                }
            } else {
                EmptyFeed(systemImage: "questionmark.circle", title: "This post isn't here any more", detail: "Its author may have deleted it.")
                    .task { await model.fetchPost(id) }
            }
        }
        .background(theme.bg.color.ignoresSafeArea())
        .addToTasksSheet($taskDraft, maker: model.taskMaker) { _ in model.notice = "Added to Tasks." }
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
            HeaderMenu("More", systemImage: "ellipsis") {
                if model.taskMaker != nil {
                    Button("Add to Tasks", systemImage: "checklist") { taskDraft = model.taskDraft(post) }
                }
                if model.receiver != nil {
                    Button("Save to Reader", systemImage: "books.vertical") { Task { await model.saveToReader(post) } }
                }
                if post.author == model.me {
                    Button("Delete post", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } else {
                    if post.audience == .everyone {
                        Button("Not interested", systemImage: "hand.thumbsdown") {
                            Task { await model.notInterested(post); dismiss() }
                        }
                    }
                    Button("Report post", systemImage: "flag") { reportingPost = true }
                }
            }
        }
    }

    private func actions(_ post: SocialPost) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s3) {
                Button { Task { await model.toggleLike(post) } } label: {
                    Label(LikeText.count(post, hideEverywhere: hideEverywhere), systemImage: post.liked ? "heart.fill" : "heart")
                        .font(Typeface.callout)
                        .foregroundStyle(post.liked ? theme.accent.color : theme.textSecondary.color)
                        .frame(maxWidth: .infinity, minHeight: Metric.headerButton)
                        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .accessibilityLabel(post.liked ? "Unlike" : "Like")
                if post.audience == .everyone {
                    Button { Task { await model.toggleSaved(post) } } label: {
                        Label(post.saved ? "Saved" : "Save", systemImage: post.saved ? "bookmark.fill" : "bookmark")
                            .font(Typeface.callout)
                            .foregroundStyle(post.saved ? theme.accent.color : theme.textSecondary.color)
                            .frame(maxWidth: .infinity, minHeight: Metric.headerButton)
                            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                }
                Text(post.comments == 1 ? "1 comment" : "\(post.comments) comments")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(maxWidth: .infinity, minHeight: Metric.headerButton)
                    .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            .buttonStyle(SoftPress())
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

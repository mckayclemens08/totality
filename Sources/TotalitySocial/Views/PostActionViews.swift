import SwiftUI
import TotalityCore
import TotalityUI

/// The small plain icons top right of a post, as on the approved share-to-chat canvas (2026-11-26): repost
/// with its count, save, and the ... menu. The same on the card and in the post's detail.
struct PostTopIcons: View {
    let model: SocialModel
    let post: SocialPost
    /// Runs after the post is gone, such as closing its detail after Delete.
    var onGone: () -> Void = {}

    var body: some View {
        HStack(spacing: Space.s1) {
            RepostControl(model: model, post: post)
                .font(Typeface.caption)
                .buttonStyle(SoftPress())
            Button { Task { await model.toggleSaved(post) } } label: {
                Image(systemName: post.saved ? "bookmark.fill" : "bookmark")
                    .font(Typeface.callout)
                    .foregroundStyle(post.saved ? Theme.current.accent.color : Theme.current.textSecondary.color)
                    .frame(minWidth: Space.s6, minHeight: Space.s6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            .accessibilityLabel(post.saved ? "Unsave" : "Save")
            PostMoreMenu(model: model, post: post, onGone: onGone)
        }
    }
}

/// Like, comments and share, plain icons with their counts, grouped on the left under the post.
struct PostPlainActions: View {
    let model: SocialModel
    let post: SocialPost
    /// Pressing the comment icon: the card opens the post, and the post's own screen has nothing to open.
    var onComments: (() -> Void)?
    @AppStorage(LikeCountsPreference.key) private var hideEverywhere = false

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s5) {
            Button { Task { await model.toggleLike(post) } } label: {
                Label(LikeText.count(post, hideEverywhere: hideEverywhere), systemImage: post.liked ? "heart.fill" : "heart")
                    .foregroundStyle(post.liked ? theme.accent.color : theme.textSecondary.color)
                    .frame(minHeight: Space.s6)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(post.liked ? "Unlike" : "Like")
            Button { onComments?() } label: {
                Label("\(post.comments)", systemImage: "bubble.right")
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(minHeight: Space.s6)
                    .contentShape(Rectangle())
            }
            .disabled(onComments == nil)
            .accessibilityLabel(post.comments == 1 ? "1 comment" : "\(post.comments) comments")
            if model.canShare(post) {
                Button { model.share(post) } label: {
                    Image(systemName: "paperplane")
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(minWidth: Space.s6, minHeight: Space.s6)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share to a chat")
            }
            Spacer(minLength: 0)
        }
        .font(Typeface.callout)
        .lineLimit(1)
        .buttonStyle(SoftPress())
    }
}

/// The ... menu on a post, with the sheets its items open. One menu for the card and the detail.
struct PostMoreMenu: View {
    let model: SocialModel
    let post: SocialPost
    var onGone: () -> Void = {}
    @State private var confirmingDelete = false
    @State private var reportingPost = false
    @State private var taskDraft: TaskDraft?

    var body: some View {
        Menu {
            AskTotalityMenuButton(context: AIAskContext(
                id: post.id.uuidString,
                module: .social,
                title: post.headline,
                detail: "@\(post.author)",
                body: post.body,
                date: post.date
            ))
            if model.taskMaker != nil {
                Button("Add to Tasks", systemImage: "checklist") { taskDraft = model.taskDraft(post) }
            }
            if model.receiver != nil {
                Button(model.isSavedToReader(post) ? "Saved to Reader" : "Save to Reader", systemImage: "books.vertical") {
                    Task { await model.saveToReader(post) }
                }
                .disabled(model.isSavingToReader(post) || model.isSavedToReader(post))
            }
            if post.author == model.me {
                Button("Delete post", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } else {
                if post.audience == .everyone {
                    Button("Not interested", systemImage: "hand.thumbsdown") {
                        Task { await model.notInterested(post); onGone() }
                    }
                }
                Button("Report post", systemImage: "flag") { reportingPost = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textSecondary.color)
                .frame(minWidth: Space.s6, minHeight: Space.s6)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("More")
        .sheet(isPresented: $reportingPost) {
            ReportSheet(model: model, username: post.author, post: post, comment: nil) { reportingPost = false }
        }
        .confirmationDialog("Delete this post?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete for everyone", role: .destructive) {
                Task { await model.delete(post); onGone() }
            }
        } message: {
            Text(post.audience == .everyone
                 ? "It's removed from Totality's server. Anyone who already saw it may remember it."
                 : "It's removed from your encrypted room. People who already opened it keep what they saw.")
        }
        .addToTasksSheet($taskDraft, maker: model.taskMaker) { _ in model.notice = "Added to Tasks." }
    }
}

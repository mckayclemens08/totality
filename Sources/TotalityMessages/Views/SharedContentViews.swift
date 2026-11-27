import SwiftUI
import TotalityCore
import TotalityUI

/// A shared post inside a chat, as on the approved share-to-chat canvas (2026-11-26). The message holds only the
/// post's ID; this device asks the owning module what to show, with this person's own access. A post they can't
/// open shows a placeholder with nothing from the post in it.
struct SharedContentBubble: View {
    let shared: SharedContentLink.Shared
    let hooks: SharedContentHooks?
    @State private var state: SharedCardState?
    @State private var attempt = 0

    var body: some View {
        let theme = Theme.current
        Group {
            switch state {
            case nil:
                skeleton
            case .card(let content)?:
                Button { hooks?.open(shared.ref) } label: { card(content) }
                    .buttonStyle(SoftPress())
                    .accessibilityHint("Opens the post")
            case .unavailable(let author)?:
                placeholder(
                    systemImage: "lock", title: "You can't see this post",
                    detail: author.map { "It may be limited to @\($0)'s friends or approved followers, or it was deleted." }
                        ?? "It may be limited to its author's friends or approved followers, or it was deleted.",
                    button: author.map { name in ("View profile", { hooks?.openAuthor(name) }) }
                )
            case .failed?:
                placeholder(
                    systemImage: "exclamationmark.circle", title: "Couldn't load this post", detail: "Check your connection.",
                    button: ("Try again", { attempt += 1 })
                )
            }
        }
        .frame(width: Self.width)
        .task(id: "\(shared.ref.id)-\(attempt)") {
            state = nil
            guard let hooks else { state = .unavailable(author: shared.author); return }
            state = await hooks.resolve(shared.ref, shared.author)
        }
        .foregroundStyle(theme.textPrimary.color)
    }

    static let width: CGFloat = 260

    private func card(_ content: SharedCardContent) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            Label("Shared post", systemImage: "paperplane")
                .font(Typeface.micro.weight(.bold))
                .foregroundStyle(theme.accent.color)
            HStack(spacing: Space.s2) {
                PersonFace(photo: nil, name: content.authorName, diameter: Space.s6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(content.authorName).font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.textPrimary.color).lineLimit(1)
                    Text("@\(content.author) · \(content.audience)").font(Typeface.micro).foregroundStyle(theme.textSecondary.color).lineLimit(1)
                }
            }
            if let data = content.thumbnail {
                OpenedImage(data: data)
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .accessibilityHidden(true)
            }
            if !content.text.isEmpty {
                Text(content.text).font(Typeface.caption).foregroundStyle(theme.textPrimary.color).lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: Space.s3) {
                if let likes = content.likes { Label("\(likes)", systemImage: "heart") }
                Label("\(content.comments)", systemImage: "bubble.right")
            }
            .font(Typeface.micro)
            .foregroundStyle(theme.textSecondary.color)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func placeholder(systemImage: String, title: String, detail: String, button: (String, () -> Void)?) -> some View {
        let theme = Theme.current
        return VStack(spacing: Space.s2) {
            Image(systemName: systemImage)
                .font(Typeface.headline)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s7, height: Space.s7)
                .neumorphic(.raised, in: Circle())
                .accessibilityHidden(true)
            Text(title).font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.textPrimary.color).multilineTextAlignment(.center)
            Text(detail).font(Typeface.micro).foregroundStyle(theme.textSecondary.color).multilineTextAlignment(.center)
            if let button {
                Button(button.0, action: button.1)
                    .font(Typeface.caption.weight(.bold))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                    .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .buttonStyle(SoftPress())
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var skeleton: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            RoundedRectangle(cornerRadius: Radius.sm).fill(theme.textTertiary.color.opacity(0.25)).frame(width: 120, height: 10)
            RoundedRectangle(cornerRadius: Radius.sm).fill(theme.textTertiary.color.opacity(0.25)).frame(height: 90)
            RoundedRectangle(cornerRadius: Radius.sm).fill(theme.textTertiary.color.opacity(0.25)).frame(height: 10)
            RoundedRectangle(cornerRadius: Radius.sm).fill(theme.textTertiary.color.opacity(0.25)).frame(width: 150, height: 10)
        }
        .padding(Space.s3)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityLabel("Loading the shared post")
    }
}

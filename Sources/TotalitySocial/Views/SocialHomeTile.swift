import SwiftUI
import TotalityCore
import TotalityUI

/// What the Social home tile shows and what its buttons ask for. Plain functions so they can be tested.
enum SocialTileLogic {
    /// The newest posts from people you follow, never your own, newest first.
    static func recent(_ following: [SocialPost], me: String?, count: Int) -> [SocialPost] {
        Array(following.filter { $0.author != me }.sorted { $0.date > $1.date }.prefix(count))
    }

    /// The badge: follow requests waiting. Nil at zero, so the badge hides; "9+" past nine.
    static func badge(_ count: Int) -> String? {
        count <= 0 ? nil : count > 9 ? "9+" : "\(count)"
    }
}

/// Social's home tile at each size (approved mockup, 2026-11-21). The avatar opens your profile, the
/// newest post from someone you follow opens that post, and the two pills open the composer and Search.
public struct SocialHomeTile: View {
    private let model: SocialModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    public init(model: SocialModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private var posts: [SocialPost] {
        SocialTileLogic.recent(model.following, me: model.me, count: size == .large ? 3 : 1)
    }

    private var isLoading: Bool { model.phase == .loading && model.following.isEmpty }

    public var body: some View {
        Group {
            switch size {
            case .small: small
            case .medium, .large: list
            }
        }
        .tilePadding()
    }

    private func go(_ request: SocialModel.HomeRequest) {
        model.homeRequest = request
        onOpen()
    }

    private func openProfile() {
        guard let me = model.me else { return onOpen() }
        model.requestedProfile = me
        onOpen()
    }

    private func open(_ post: SocialPost) {
        model.requestedPost = post.id
        onOpen()
    }

    private var avatar: some View { TileAvatar(photo: model.me.flatMap { model.photos[$0] }, name: model.me ?? "Social", diameter: size == .small ? 72 : 36) }

    private var badge: some View {
        let theme = Theme.current
        return Group {
            if let text = SocialTileLogic.badge(model.followRequests.count) {
                Text(text)
                    .font(Typeface.micro.weight(.bold))
                    .foregroundStyle(theme.accentOn.color)
                    .padding(.horizontal, Space.s2)
                    .frame(minWidth: Space.s5, minHeight: Space.s5)
                    .background(Capsule().fill(theme.accent.color))
                    .accessibilityLabel("\(model.followRequests.count) follow requests")
            }
        }
    }

    // MARK: Small

    private var small: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s2) {
            TileHeader("Social", systemImage: "person.2")
            Spacer(minLength: 0)
            avatar
                .overlay(alignment: .topTrailing) { badge.offset(x: Space.s2, y: -Space.s1) }
                .tileLink("Your profile") { openProfile() }
            Spacer(minLength: 0)
            Text("+ Post")
                .font(Typeface.tileDetail.weight(.semibold))
                .foregroundStyle(theme.accentOn.color)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s1 + Space.s1 / 2)
                .background(Capsule().fill(theme.accent.color))
                .tileLink("New post") { go(.compose) }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Medium and large

    private var list: some View {
        VStack(alignment: .leading, spacing: Metric.tileRowGap) {
            HStack(spacing: Space.s2) {
                avatar.tileLink("Your profile") { openProfile() }
                Text("Social")
                    .font(Typeface.headline)
                    .foregroundStyle(Theme.current.textPrimary.color)
                Spacer(minLength: 0)
                badge
            }
            content
            Spacer(minLength: 0)
            HStack(spacing: Space.s2) {
                pill("+ Post", "plus") { go(.compose) }
                pill("Search", "magnifyingglass") { go(.search) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let theme = Theme.current
        if isLoading {
            VStack(alignment: .leading, spacing: Metric.tileRowGap) {
                ForEach(0..<(size == .large ? 3 : 1), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Radius.sm).fill(theme.textSecondary.color.opacity(0.12)).frame(height: 36)
                }
            }
            .accessibilityLabel("Loading Social")
        } else if posts.isEmpty {
            HStack(spacing: Space.s3) {
                Image(systemName: "person.2")
                    .font(Typeface.title)
                    .foregroundStyle(theme.accent.color)
                Text("Find people to follow")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: 0)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
            .tileLink("Find people to follow") { go(.search) }
        } else {
            ForEach(posts) { post in
                HStack(spacing: Space.s3) {
                    TileAvatar(photo: model.photos[post.author], name: post.displayName, diameter: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(post.displayName).font(Typeface.tileRow.weight(.semibold))
                                .foregroundStyle(theme.textPrimary.color)
                            Text(post.date.formatted(.relative(presentation: .numeric)))
                                .font(Typeface.micro)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                        Text(post.headline)
                            .font(Typeface.tileDetail)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .tileLink("\(post.displayName): \(post.headline)") { open(post) }
            }
        }
    }

    private func pill(_ title: String, _ icon: String, action: @escaping @MainActor () -> Void) -> some View {
        Label(title, systemImage: icon)
            .labelStyle(.titleOnly)
            .font(Typeface.tileDetail.weight(.semibold))
            .foregroundStyle(Theme.current.accent.color)
            .frame(maxWidth: .infinity, minHeight: Space.s6)
            .neumorphic(.raised, in: Capsule())
            .tileLink(title, action: action)
    }
}

/// A person's picture, or their initial on the accent when they have none.
private struct TileAvatar: View {
    let photo: Data?
    let name: String
    let diameter: CGFloat

    var body: some View {
        let theme = Theme.current
        if photo != nil {
            PersonFace(photo: photo, name: name, diameter: diameter)
        } else {
            Text(PublicProfile.initials(of: name))
                .font(diameter > 50 ? Typeface.title : Typeface.callout.weight(.semibold))
                .foregroundStyle(theme.accentOn.color)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(theme.accent.color))
                .accessibilityHidden(true)
        }
    }
}

import SwiftUI
import TotalityCore
import TotalityUI

/// Where Social opens: For You, a two-column grid of public posts, and Following, everyone you follow
/// newest first, with Friends and Close-friends posts mixed in (the approved canvas, issue 149).
public struct SocialHomeView: View {
    @Bindable var model: SocialModel
    let onClose: () -> Void
    @State private var path = NavigationPath()
    @State private var composing = false
    @State private var searching = false

    public init(model: SocialModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    enum Route: Hashable {
        case post(UUID)
        case profile(String)
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                content
            }
            .background(theme.bg.color.ignoresSafeArea())
            .addButton("New post") { composing = true }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .post(let id): PostDetailView(model: model, id: id, open: open)
                case .profile(let name): SocialProfileView(model: model, username: name, open: open)
                }
            }
            .hidesNavigationBar()
        }
        .sheet(isPresented: $composing) { ComposeView(model: model) { composing = false } }
        .sheet(isPresented: $searching) {
            PeopleSearchView(model: model) { name in
                searching = false
                open(.profile(name))
            } onClose: { searching = false }
        }
        .overlay(alignment: .bottom) { NoticeBanner(text: $model.notice) }
        .task { if model.phase == .loading { await model.load() } }
        .onDisappear { Task { await model.flushShown() } }
        .onChange(of: model.requestedProfile) { _, name in
            guard let name else { return }
            model.requestedProfile = nil
            open(.profile(name))
        }
    }

    func open(_ route: Route) { path.append(route) }

    private var header: some View {
        HStack(spacing: Space.s3) {
            HeaderButton("Home", systemImage: "square.grid.2x2", action: onClose)
            Spacer(minLength: 0)
            ForEach(SocialModel.Feed.allCases) { feed in
                FeedTab(title: feed.name, isSelected: model.feed == feed) { model.feed = feed }
            }
            Spacer(minLength: 0)
            HeaderButton("Search", systemImage: "magnifyingglass") { searching = true }
            if let me = model.me {
                HeaderButton("Your profile", systemImage: "person") { open(.profile(me)) }
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s3)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.posts.isEmpty:
            LoadingGrid()
        case .failed(let message) where model.posts.isEmpty:
            ProblemView(systemImage: "exclamationmark.triangle", title: "Social didn't load", detail: message) { Task { await model.refresh() } }
        case .unavailable(let message):
            ProblemView(systemImage: "person.crop.circle.badge.exclamationmark", title: "Sign in to use Social", detail: message, retry: nil)
        default:
            ScrollView {
                VStack(spacing: Space.s3) {
                    if model.phase == .offline { OfflineLine { Task { await model.refresh() } } }
                    if model.feed == .forYou {
                        if !model.tags.isEmpty { tagChips }
                        if model.forYou.isEmpty {
                            EmptyFeed(
                                systemImage: "sparkles", title: "Nothing new right now",
                                detail: model.tag == nil ? "You've seen every recent public post. Check back later, or post something yourself." : "No new posts tagged #\(model.tag!)."
                            )
                        } else {
                            PostGrid(posts: model.forYou, photos: model.photos, onShow: model.didShow) { open(.post($0.id)) }
                        }
                    } else if model.following.isEmpty {
                        EmptyFeed(
                            systemImage: "person.badge.plus", title: "Nothing here yet",
                            detail: "Follow people from For You or search, and their posts show up here, newest first."
                        )
                    } else {
                        ForEach(model.following) { post in
                            FollowingCard(post: post, photo: model.photos[post.author], onAuthor: { open(.profile(post.author)) }) {
                                open(.post(post.id))
                            } onLike: {
                                Task { await model.toggleLike(post) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.bottom, Metric.addButton + Space.s6)
            }
            .refreshable { await model.refresh() }
        }
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                FilterPill("All", isSelected: model.tag == nil) { model.tag = nil }
                ForEach(model.tags, id: \.self) { tag in
                    FilterPill("#" + tag, isSelected: model.tag == tag) { model.tag = tag }
                }
            }
            .padding(.vertical, Space.s2)
            .padding(.horizontal, Space.s1)
        }
    }
}

/// A feed's name in the header, underlined in the accent when it's the one showing.
struct FeedTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Text(title)
                .font(Typeface.headline)
                .foregroundStyle(isSelected ? theme.textPrimary.color : theme.textSecondary.color)
                .padding(.vertical, Space.s1)
                .overlay(alignment: .bottom) {
                    if isSelected { Capsule().fill(theme.accent.color).frame(height: Metric.selectionOutline).offset(y: Space.s1) }
                }
                .frame(minHeight: Metric.headerButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The Lemon8-style two columns. Posts alternate between them, so the newest stay near the top of both.
struct PostGrid: View {
    let posts: [SocialPost]
    let photos: [String: Data]
    let onShow: (SocialPost) -> Void
    let onOpen: (SocialPost) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            ForEach(0..<2, id: \.self) { column in
                LazyVStack(spacing: Space.s3) {
                    ForEach(Array(posts.enumerated()).filter { $0.offset % 2 == column }.map(\.element)) { post in
                        GridCard(post: post) { onOpen(post) }
                            .onAppear { onShow(post) }
                    }
                }
            }
        }
    }
}

/// One post in the grid: its headline, the start of its text, who wrote it and its likes.
struct GridCard: View {
    let post: SocialPost
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s2) {
                if post.audience != .everyone { AudienceTag(audience: post.audience) }
                if let title = post.title, !title.isEmpty {
                    Text(title).font(Typeface.headline).foregroundStyle(theme.textPrimary.color).lineLimit(3)
                    if !post.body.isEmpty {
                        Text(post.body).font(Typeface.caption).foregroundStyle(theme.textSecondary.color).lineLimit(4)
                    }
                } else {
                    Text(post.body).font(Typeface.body).foregroundStyle(theme.textPrimary.color).lineLimit(8)
                }
                HStack {
                    Text(Handle.display(post.author)).lineLimit(1)
                    Spacer(minLength: Space.s1)
                    Label("\(post.likes)", systemImage: post.liked ? "heart.fill" : "heart")
                        .labelStyle(.titleAndIcon)
                }
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(SoftPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the post")
    }
}

/// One post in Following: author, audience, text, and the like and comment counts.
struct FollowingCard: View {
    let post: SocialPost
    let photo: Data?
    let onAuthor: () -> Void
    let onOpen: () -> Void
    let onLike: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Button(action: onAuthor) {
                    HStack(spacing: Space.s3) {
                        PersonFace(photo: photo, name: post.displayName, diameter: Space.s6 + Space.s1)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(post.displayName).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                            Text("\(Handle.display(post.author)) · \(post.date.formatted(.relative(presentation: .numeric)))")
                                .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        }
                    }
                }
                .buttonStyle(SoftPress())
                Spacer(minLength: 0)
                AudienceTag(audience: post.audience)
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if let title = post.title { Text(title).font(Typeface.headline).foregroundStyle(theme.textPrimary.color) }
                    Text(post.body).font(Typeface.body).foregroundStyle(theme.textPrimary.color).lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            HStack(spacing: Space.s5) {
                Button(action: onLike) {
                    Label("\(post.likes)", systemImage: post.liked ? "heart.fill" : "heart")
                        .foregroundStyle(post.liked ? theme.accent.color : theme.textSecondary.color)
                }
                .accessibilityLabel(post.liked ? "Unlike, \(post.likes) likes" : "Like, \(post.likes) likes")
                Button(action: onOpen) {
                    Text(post.comments == 1 ? "1 comment" : "\(post.comments) comments").foregroundStyle(theme.textSecondary.color)
                }
            }
            .font(Typeface.callout)
            .buttonStyle(SoftPress())
        }
        .itemCard()
    }
}

/// Who can see a post, with the lock for the encrypted two.
struct AudienceTag: View {
    let audience: Audience

    var body: some View {
        let theme = Theme.current
        Label(audience.name, systemImage: audience.systemImage)
            .font(Typeface.micro)
            .foregroundStyle(audience.isEncrypted ? theme.success.color : theme.textSecondary.color)
            .accessibilityLabel(audience.label)
    }
}

/// The loading state: soft blank cards in the grid's shape, never a spinner over everything.
struct LoadingGrid: View {
    var body: some View {
        let theme = Theme.current
        HStack(alignment: .top, spacing: Space.s3) {
            ForEach([[200.0, 120.0], [140.0, 180.0]], id: \.self) { heights in
                VStack(spacing: Space.s3) {
                    ForEach(heights, id: \.self) { height in
                        VStack(alignment: .leading, spacing: Space.s2) {
                            RoundedRectangle(cornerRadius: Radius.sm).fill(theme.highlight.color).frame(height: height)
                            Capsule().fill(theme.highlight.color).frame(height: Space.s2).padding(.trailing, Space.s6)
                        }
                        .padding(Space.s3)
                        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                }
            }
        }
        .padding(.horizontal, Space.s4)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("Loading posts")
    }
}

struct EmptyFeed: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(Typeface.title)
                .foregroundStyle(theme.accent.color)
                .frame(width: Space.s8, height: Space.s8)
                .neumorphic(.raised, in: Circle())
            Text(title).font(Typeface.title).foregroundStyle(theme.textPrimary.color)
            Text(detail).font(Typeface.body).foregroundStyle(theme.textSecondary.color).multilineTextAlignment(.center)
        }
        .padding(.top, Space.s7)
        .padding(.horizontal, Space.s5)
    }
}

struct ProblemView: View {
    let systemImage: String
    let title: String
    let detail: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.s4) {
            EmptyFeed(systemImage: systemImage, title: title, detail: detail)
            if let retry { HeaderPill("Try again", isProminent: true, action: retry) }
            Spacer()
        }
    }
}

struct OfflineLine: View {
    let retry: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Image(systemName: "wifi.slash").foregroundStyle(theme.textSecondary.color)
            Text("You're offline. Showing posts already on this phone.").font(Typeface.caption).foregroundStyle(theme.textPrimary.color)
            Spacer(minLength: 0)
            Button("Retry", action: retry).font(Typeface.callout).foregroundStyle(theme.accent.color)
        }
        .padding(Space.s3)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

/// A short note at the bottom after something didn't go through. It leaves after a few seconds.
struct NoticeBanner: View {
    @Binding var text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textPrimary.color)
                .padding(Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .padding(Space.s4)
                .onTapGesture { self.text = nil }
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    self.text = nil
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

extension View {
    /// Social draws its own headers, so the system bar is hidden where there is one.
    func hidesNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

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
    @State private var tab = SocialTab.feed
    @State private var newStory = false
    /// The stories open in the viewer, taken when it opened, and whose to start with.
    @State private var watching: StoryWatch?

    public init(model: SocialModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    enum Route: Hashable {
        case post(UUID)
        case profile(String)
        /// Someone's Followers (or Following) list.
        case people(String, followers: Bool)
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack(path: $path) {
            tabScreen
            .background(theme.bg.color.ignoresSafeArea())
            // Inside the tab bar's inset, so the note sits just above the bar rather than over it.
            .noticeBanner($model.notice)
            // Swiping in from the left edge goes back to the app's home, as in every other module.
            .edgeSwipeBack(onClose)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SocialTabBar(selected: tab, me: model.me, onSelect: select)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .post(let id): PostDetailView(model: model, id: id, open: open)
                        .edgeSwipeBack(back)
                case .profile(let name): SocialProfileView(model: model, username: name, open: open)
                        .edgeSwipeBack(back)
                        .noticeBanner($model.notice)
                case .people(let name, let followers): FollowListView(model: model, username: name, followers: followers, open: open)
                        .edgeSwipeBack(back)
                        .noticeBanner($model.notice)
                }
            }
            .hidesNavigationBar()
        }
        .sheet(isPresented: $composing) { ComposeView(model: model) { composing = false } }
        .sheet(isPresented: $newStory) { StoryComposer(model: model) { newStory = false } }
        .storyCover(item: $watching) { watch in
            StoryViewer(model: model, rings: watch.rings, start: watch.author) { watching = nil }
        }
        .onChange(of: model.requestedStories, initial: true) { _, author in
            guard let author else { return }
            model.requestedStories = nil
            openStories(author)
        }
        .task { if model.phase == .loading { await model.load() } }
        .onDisappear { Task { await model.flushShown() } }
        .onChange(of: model.homeRequest, initial: true) { _, request in
            guard let request else { return }
            model.homeRequest = nil
            switch request {
            case .compose: composing = true
            case .search: tab = .search
            }
        }
        .onChange(of: model.requestedPost, initial: true) { _, id in
            guard let id else { return }
            model.requestedPost = nil
            open(.post(id))
        }
        .onChange(of: model.requestedProfile, initial: true) { _, name in
            guard let name else { return }
            model.requestedProfile = nil
            open(.profile(name))
        }
    }

    func open(_ route: Route) { path.append(route) }

    func openStories(_ author: String) {
        let rings = model.storyRings
        guard rings.contains(where: { $0.author == author }) else { return }
        watching = StoryWatch(rings: rings, author: author)
    }

    /// One screen back. The hidden navigation bar turns off the system's own swipe, so this replaces it.
    func back() { if !path.isEmpty { path.removeLast() } }

    /// A tab in the bottom bar: the + opens the composer, the others become the screen showing.
    func select(_ picked: SocialTab) {
        switch picked.destination(me: model.me) {
        case .show(let next): tab = next
        case .compose: composing = true
        case nil: break
        }
    }

    @ViewBuilder
    private var tabScreen: some View {
        switch tab {
        case .feed, .newPost:
            VStack(spacing: 0) {
                header
                content
            }
        case .search:
            PeopleSearchView(model: model) { name in open(.profile(name)) }
        case .saved:
            SavedPostsView(model: model, open: open)
        case .profile:
            if let me = model.me { SocialProfileView(model: model, username: me, open: open, isTab: true) }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            HeaderButton("Home", systemImage: "square.grid.2x2", action: onClose)
            Spacer(minLength: 0)
            ForEach(SocialModel.Feed.allCases) { feed in
                FeedTab(title: feed.name, isSelected: model.feed == feed) { model.feed = feed }
            }
            Spacer(minLength: 0)
            // Search and your profile moved to the bottom bar; this keeps the feed names centred.
            Color.clear.frame(width: Metric.headerButton, height: Metric.headerButton)
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
                        if !model.tags.isEmpty || model.tag != nil { tagChips }
                        if model.forYou.isEmpty && model.isLoading {
                            LoadingGrid()
                        } else if model.forYou.isEmpty {
                            EmptyFeed(
                                systemImage: "sparkles", title: "Nothing new right now",
                                detail: model.tag == nil ? "You've seen every recent public post. Check back later, or post something yourself." : "No new posts tagged #\(model.tag!)."
                            )
                        } else {
                            PostGrid(model: model, posts: model.forYou, photos: model.photos, onShow: model.didShow) { open(.post($0.id)) }
                        }
                    } else {
                        // Stories sit in a row of rings at the top of Following (owner, 2026-11-17).
                        StoryRowView(model: model, onOpen: openStories) { newStory = true }
                        if model.following.isEmpty && model.isLoading {
                            LoadingGrid()
                        } else if model.following.isEmpty {
                            EmptyFeed(
                                systemImage: "person.badge.plus", title: "Nothing here yet",
                                detail: "Follow people from For You or search, and their posts show up here, newest first."
                            )
                        } else {
                            ForEach(model.following) { post in
                                FollowingCard(model: model, post: post, photo: model.photos[post.author], ring: model.ring(for: post.author),
                                              onAuthor: { open(.profile(post.author)) }) {
                                    open(.post(post.id))
                                } onDoubleTap: {
                                    Task { await model.like(post) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.bottom, Space.s4)
            }
            .refreshable { await model.refresh() }
        }
    }

    /// The top tags, plus the one being filtered when a tapped #tag isn't among them.
    private var chipTags: [String] {
        guard let tag = model.tag, !model.tags.contains(tag) else { return model.tags }
        return [tag] + model.tags
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                FilterPill("All", isSelected: model.tag == nil) { model.tag = nil }
                ForEach(chipTags, id: \.self) { tag in
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
    let model: SocialModel
    let posts: [SocialPost]
    let photos: [String: Data]
    let onShow: (SocialPost) -> Void
    let onOpen: (SocialPost) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            ForEach(0..<2, id: \.self) { column in
                LazyVStack(spacing: Space.s3) {
                    ForEach(Array(posts.enumerated()).filter { $0.offset % 2 == column }.map(\.element)) { post in
                        GridCard(model: model, post: post) { onOpen(post) }
                            .onAppear { onShow(post) }
                    }
                }
            }
        }
    }
}

/// One post in the grid: its headline, the start of its text, who wrote it and its likes.
struct GridCard: View {
    let model: SocialModel
    let post: SocialPost
    let action: () -> Void
    @AppStorage(LikeCountsPreference.key) private var hideEverywhere = false

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
                if !post.media.isEmpty { GridCover(model: model, post: post) }
                if let by = post.repostedBy { RepostedLine(by: by, me: model.me) }
                if post.audience != .everyone { AudienceTag(audience: post.audience) }
                if let title = post.title, !title.isEmpty {
                    Text(title).font(Typeface.headline).foregroundStyle(theme.textPrimary.color).lineLimit(3)
                    if !post.body.isEmpty {
                        Text(post.body).font(Typeface.caption).foregroundStyle(theme.textSecondary.color).lineLimit(4)
                    }
                } else if !post.body.isEmpty || post.media.isEmpty {
                    Text(post.body).font(Typeface.body).foregroundStyle(theme.textPrimary.color).lineLimit(post.media.isEmpty ? 8 : 3)
                }
                HStack {
                    Text(Handle.display(post.author)).lineLimit(1)
                    Spacer(minLength: Space.s1)
                    Label(LikeText.count(post, hideEverywhere: hideEverywhere), systemImage: post.liked ? "heart.fill" : "heart")
                        .labelStyle(.titleAndIcon)
                }
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .likesOnDoubleTap(onOpen: action) { Task { await model.like(post) } }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the post. Double tap likes it.")
    }
}

/// One post in Following: author, audience, text, and the like and comment counts.
struct FollowingCard: View {
    let model: SocialModel
    let post: SocialPost
    let photo: Data?
    /// Their live stories, which ring their photo; tapping the photo then plays them.
    var ring: StoryRing?
    let onAuthor: () -> Void
    let onOpen: () -> Void
    /// A double tap on the text: only ever adds the like.
    let onDoubleTap: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            if let by = post.repostedBy { RepostedLine(by: by, me: model.me) }
            HStack(spacing: Space.s3) {
                Button(action: onAuthor) {
                    HStack(spacing: Space.s3) {
                        StoryFace(photo: photo, name: post.displayName, ring: ring, diameter: Space.s6 + Space.s1)
                            .onTapGesture { if ring != nil { model.requestedStories = post.author } else { onAuthor() } }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(post.displayName).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                            Text("\(Handle.display(post.author)) · \(post.date.formatted(.relative(presentation: .numeric)))\(post.audience == .everyone ? "" : " · " + post.audience.name)")
                                .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                                .accessibilityLabel("\(Handle.display(post.author)), \(post.audience.label)")
                        }
                    }
                }
                .buttonStyle(SoftPress())
                Spacer(minLength: 0)
                PostTopIcons(model: model, post: post)
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                if let title = post.title { Text(title).font(Typeface.headline).foregroundStyle(theme.textPrimary.color) }
                if !post.body.isEmpty {
                    Text(post.body).font(Typeface.body).foregroundStyle(theme.textPrimary.color).lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .likesOnDoubleTap(onOpen: onOpen, onLike: onDoubleTap)
            if !post.media.isEmpty { PostMediaView(model: model, post: post, photoHeight: 260) }
            PostPlainActions(model: model, post: post, onComments: onOpen)
        }
        .itemCard()
    }
}

/// "Maya Chen reposted" above a post that's in a feed or profile because someone reposted it.
struct RepostedLine: View {
    let by: Reposter
    let me: String?

    var body: some View {
        Label(by.line(me: me), systemImage: "arrow.2.squarepath")
            .font(Typeface.caption)
            .foregroundStyle(Theme.current.textSecondary.color)
    }
}

/// The repost button with its count, which undoes a repost when pressed again. On your own post, and on
/// anything that isn't public, there's nothing to press: it only shows how many reposted yours.
struct RepostControl: View {
    let model: SocialModel
    let post: SocialPost

    var body: some View {
        let theme = Theme.current
        if post.canRepost(by: model.me) {
            Button { Task { await model.toggleRepost(post) } } label: {
                Label(post.reposts == 0 ? "Repost" : "\(post.reposts)", systemImage: "arrow.2.squarepath")
                    .labelStyle(RepostLabelStyle(iconOnly: post.reposts == 0))
                    .lineLimit(1)
                    .foregroundStyle(post.reposted ? theme.accent.color : theme.textSecondary.color)
            }
            .accessibilityLabel(post.reposted ? "Undo repost" : "Repost")
            .accessibilityValue(post.reposts == 1 ? "1 repost" : "\(post.reposts) reposts")
        } else if post.reposts > 0 {
            Label("\(post.reposts)", systemImage: "arrow.2.squarepath")
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityLabel(post.reposts == 1 ? "1 repost" : "\(post.reposts) reposts")
        }
    }
}

/// "Repost" is the icon alone when there's no count yet; the accessibility label still says it.
private struct RepostLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: Space.s1) { configuration.icon; configuration.title }
        }
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
        .frame(maxWidth: .infinity)
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
    /// The notice at the bottom of this screen. Each screen carries its own, so on the tab screens it
    /// lands above the bottom bar, and on pushed screens (no bar) at the usual bottom spot.
    func noticeBanner(_ text: Binding<String?>) -> some View {
        overlay(alignment: .bottom) { NoticeBanner(text: text) }
    }

    /// Social draws its own headers, so the system bar is hidden where there is one.
    func hidesNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

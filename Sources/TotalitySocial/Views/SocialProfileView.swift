import SwiftUI
import TotalityCore
import TotalityUI

/// "Add to Contacts" on someone's profile (issue 205, section 5): keeps a private, sealed card linked to their
/// handle in Contacts, through the registry. It never changes their profile.
struct AddToContactsButton: View {
    let maker: any ContactMaker
    let username: String
    let displayName: String?
    @State private var isIn = false
    @State private var failed = false

    var body: some View {
        HeaderPill(isIn ? "In Contacts" : (failed ? "Try again" : "Add to Contacts"), systemImage: isIn ? "checkmark" : "person.crop.circle.badge.plus", iconOnly: true) {
            Task {
                do {
                    _ = try await maker.addContact(username: username, displayName: displayName)
                    isIn = true
                    failed = false
                } catch {
                    failed = true
                }
            }
        }
        .disabled(isIn)
        .task(id: username) { isIn = await maker.hasContact(username: username) }
    }
}

/// Someone's profile: the one public profile (owner, 2026-11-17). Photo, name, @handle, bio, counts,
/// Follow, and their posts. On your own, Close friends is here too.
struct SocialProfileView: View {
    let model: SocialModel
    let username: String
    let open: (SocialHomeView.Route) -> Void
    /// Your own profile shown as the Profile tab, where there is nothing to go back to.
    var isTab = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var profile: SocialProfile?
    @State private var fetched: [SocialPost] = []
    @State private var postsLoaded = false
    @State private var problem: String?
    /// Whether the server may have older posts than the ones shown.
    @State private var hasMore = false
    @State private var loadingMore = false
    @State private var busy = false
    @State private var confirmingUnfollow = false
    @State private var editingCloseFriends = false
    @State private var editingPrivacy = false
    @State private var showingRequests = false
    @State private var reporting = false
    @State private var editingBackground = false
    @State private var backgroundImage: CGImage?
    @State private var loadedBackgroundKey: String?
    @State private var backgroundFailed = false
    @State private var backgroundRetry = 0
    @State private var confirmingBlock = false
    /// On your own profile: your posts, or the public posts you saved. Only you see your saves.
    @State private var showingSaved = false
    /// The Photos or Audio tab: only posts that carry that kind of media.
    @State private var mediaTab: PostMedia.Kind?

    /// What this profile showed last time while the new page is fetched, or what was just fetched.
    private var posts: [SocialPost] { postsLoaded ? fetched : (model.cachedPosts(by: username) ?? []) }
    private var hasPosts: Bool { postsLoaded || model.cachedPosts(by: username) != nil }

    private var shownPosts: [SocialPost] {
        guard let mediaTab else { return posts }
        return posts.filter { $0.media.contains { $0.kind == mediaTab } }
    }

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                if let profile {
                    if profile.backgroundKey != nil {
                        VStack(alignment: .leading, spacing: Space.s4) {
                            navigationRow(profile)
                            header(profile)
                        }
                        .padding(Space.s4)
                        .background { photoBackdrop }
                    } else {
                        navigationRow(profile)
                        header(profile)
                    }
                    if isMe {
                        Text("Your profile is public: anyone signed in to Totality can see your photo, background, name, bio and public posts. Edit them from Account.")
                            .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                    HStack(spacing: Space.s2) {
                        FilterPill("Posts", isSelected: !showingSaved && mediaTab == nil) { showingSaved = false; mediaTab = nil }
                        FilterPill("Photos", isSelected: !showingSaved && mediaTab == .photo) { showingSaved = false; mediaTab = .photo }
                        FilterPill("Audio", isSelected: !showingSaved && mediaTab == .audio) { showingSaved = false; mediaTab = .audio }
                        if isMe {
                            FilterPill("Saved", isSelected: showingSaved) { showingSaved = true; Task { await model.loadSaved() } }
                        }
                    }
                    if profile.isClosed && !isMe {
                        EmptyFeed(systemImage: "lock", title: "This account is private",
                                  detail: profile.requested ? "You asked to follow \(profile.name). Once they accept, you'll see their posts."
                                                            : "Once \(profile.name) accepts your request, you'll see their posts.")
                    } else if isMe && showingSaved {
                        if !model.savedLoaded && model.saved.isEmpty {
                            LoadingGrid()
                        } else if model.saved.isEmpty {
                            EmptyFeed(systemImage: "bookmark", title: "Nothing saved yet", detail: "Tap Save on a public post to keep it here. Only you can see what you saved.")
                        } else {
                            PostGrid(model: model, posts: model.saved, photos: model.photos, onShow: { _ in }) { open(.post($0.id)) }
                        }
                    } else if !hasPosts {
                        LoadingGrid()
                    } else if shownPosts.isEmpty, let mediaTab {
                        EmptyFeed(systemImage: mediaTab == .photo ? "photo" : "mic", title: mediaTab == .photo ? "No photos yet" : "No audio yet",
                                  detail: isMe ? "Posts with \(mediaTab == .photo ? "photos" : "audio") show here." : "When \(profile.name) posts \(mediaTab == .photo ? "photos" : "audio"), they show here.")
                    } else if posts.isEmpty {
                        EmptyFeed(systemImage: "square.and.pencil", title: "No posts yet",
                                  detail: isMe ? "Your posts show here, whoever you share them with." : "When \(profile.name) posts, it shows here.")
                    } else {
                        PostGrid(model: model, posts: shownPosts, photos: model.photos, onShow: { post in
                            if post.id == posts.last?.id { Task { await loadMore() } }
                        }) { open(.post($0.id)) }
                    }
                } else if let problem {
                    navigationRow(nil)
                    ProblemView(systemImage: "person.crop.circle.badge.questionmark", title: "This profile didn't open", detail: problem) {
                        Task { await load() }
                    }
                } else {
                    navigationRow(nil)
                    LoadingGrid()
                }
            }
            .padding(Space.s4)
        }
        .background(theme.bg.color.ignoresSafeArea())
        .hidesNavigationBar()
        .refreshable { await load() }
        .task { await load() }
        .task(id: "\(profile?.backgroundKey ?? "")/\(backgroundRetry)") { await loadBackground() }
        .sheet(isPresented: $editingBackground, onDismiss: { Task { await load() } }) {
            if let store = model.backgroundStore, let profile {
                ProfileBackgroundEditor(store: store, key: profile.backgroundKey, name: profile.name) {
                    self.profile?.backgroundKey = $0
                }
            }
        }
        .confirmationDialog("Unfollow \(Handle.display(username))?", isPresented: $confirmingUnfollow, titleVisibility: .visible) {
            Button("Unfollow", role: .destructive) { Task { await follow(false) } }
        } message: {
            Text("Their posts leave your Following. If you were friends, they stop getting your new Friends posts.")
        }
        .sheet(isPresented: $editingCloseFriends) { CloseFriendsView(model: model) { editingCloseFriends = false } }
        .sheet(isPresented: $editingPrivacy) { PrivacySettingsView(model: model) { editingPrivacy = false; Task { await load() } } }
        .sheet(isPresented: $showingRequests) { FollowRequestsView(model: model) { showingRequests = false; Task { await load() } } }
        .sheet(isPresented: $reporting) { ReportSheet(model: model, username: username, post: nil, comment: nil, backgroundKey: profile?.backgroundKey) { reporting = false } }
        .confirmationDialog("Block \(Handle.display(username))?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task { if let profile, await model.setBlocked(true, profile) { dismiss() } }
            }
        } message: {
            Text("Neither of you will see the other's posts, likes, comments or follows, here or in Messages. They aren't told.")
        }
    }

    private func navigationRow(_ profile: SocialProfile?) -> some View {
        HStack {
            if !isTab {
                if profile?.backgroundKey != nil {
                    Button { dismiss() } label: { glassIcon("chevron.left") }
                        .buttonStyle(SoftPress()).accessibilityLabel("Back")
                } else {
                    HeaderButton("Back", systemImage: "chevron.left") { dismiss() }
                }
            }
            Spacer()
            if let profile { menu(profile) }
        }
    }

    private func glassIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(Typeface.headline)
            .foregroundStyle(ProfileBackgroundStyle.ink.color)
            .frame(width: Metric.headerButton, height: Metric.headerButton)
            .background(ProfileBackgroundStyle.glass.color, in: Circle())
    }

    private var photoBackdrop: some View {
        let theme = Theme.current
        return GeometryReader { geometry in
            let actionMidline = max(0, 1 - (Space.s4 + Metric.headerButton / 2) / max(1, geometry.size.height))
            ZStack {
                theme.highlight.color
                if loadedBackgroundKey == profile?.backgroundKey, let backgroundImage {
                    Image(decorative: backgroundImage, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                ProfileBackgroundStyle.scrim.color
                if loadedBackgroundKey == nil && !backgroundFailed && model.backgroundStore != nil {
                    VStack {
                        ProgressView().tint(ProfileBackgroundStyle.ink.color)
                        Spacer()
                    }
                    .padding(.top, Space.s4)
                }
                LinearGradient(stops: [
                    .init(color: .clear, location: max(0, actionMidline - 0.34)),
                    .init(color: ProfileBackgroundStyle.glass.color, location: max(0, actionMidline - 0.12)),
                    .init(color: theme.bg.color, location: actionMidline),
                    .init(color: theme.bg.color, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(.rect(cornerRadius: Radius.lg))
        .accessibilityHidden(true)
    }

    private func loadBackground() async {
        backgroundImage = nil
        loadedBackgroundKey = nil
        backgroundFailed = false
        guard let key = profile?.backgroundKey, let store = model.backgroundStore else { return }
        do {
            let data = try await store.backgroundPhoto(key)
            let image = await Task.detached { ProfileBackgroundPhoto.decode(data) }.value
            try Task.checkCancellation()
            backgroundImage = image
            loadedBackgroundKey = key
            backgroundFailed = image == nil
        } catch {
            if !Task.isCancelled { backgroundFailed = true }
        }
    }

    @ViewBuilder
    private func menu(_ profile: SocialProfile) -> some View {
        if isMe {
            if profile.backgroundKey != nil {
                Button { editingPrivacy = true } label: { glassIcon("gearshape") }
                    .buttonStyle(SoftPress()).accessibilityLabel("Settings")
            } else {
                HeaderButton("Settings", systemImage: "gearshape") { editingPrivacy = true }
            }
        } else {
            if profile.backgroundKey != nil {
                Menu {
                    otherProfileActions(profile)
                } label: {
                    glassIcon("ellipsis")
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("More")
            } else {
                HeaderMenu("More", systemImage: "ellipsis") { otherProfileActions(profile) }
            }
        }
    }

    @ViewBuilder
    private func otherProfileActions(_ profile: SocialProfile) -> some View {
        Button(profile.muted ? "Unmute" : "Mute", systemImage: profile.muted ? "speaker.wave.2" : "speaker.slash") {
            Task { if await model.setMuted(!profile.muted, profile) { await load() } }
        }
        if profile.followsMe {
            Button("Remove follower", systemImage: "person.badge.minus") {
                Task { if await model.removeFollower(username) { await load() } }
            }
        }
        Button("Report", systemImage: "flag") { reporting = true }
        Button("Block", systemImage: "hand.raised", role: .destructive) { confirmingBlock = true }
    }

    private var isMe: Bool { username == model.me }

    /// Internal so renders can draw it without the scroll view.
    func header(_ profile: SocialProfile) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s3) {
            if profile.backgroundKey != nil {
                VStack(alignment: .leading, spacing: Space.s2) {
                    avatar(profile)
                    identity(profile)
                }
            } else {
                HStack(spacing: Space.s4) {
                    avatar(profile)
                    identity(profile)
                }
            }
            if let bio = profile.bio, !bio.isEmpty {
                Text(bio).font(Typeface.body).foregroundStyle(profile.backgroundKey == nil ? theme.textPrimary.color : ProfileBackgroundStyle.ink.color)
            }
            ProfileLinkChips(stored: profile.links)
            // Three even columns, number above label. A private account's lists are only for it and its
            // approved followers; others see the same numbers without the tap.
            let canOpen = isMe || !profile.isClosed
            let hasBackground = profile.backgroundKey != nil
            let canEditBackground = isMe && hasBackground && model.backgroundStore != nil
            HStack(spacing: canEditBackground ? Space.s2 : 0) {
                stat(model.postCount(profile), Self.label(model.postCount(profile), "post", "posts"))
                stat(profile.followers, Self.label(profile.followers, "follower", "followers"), canOpen: canOpen) {
                    open(.people(username, followers: true))
                }
                stat(profile.following, "following", canOpen: canOpen) { open(.people(username, followers: false)) }
                if canEditBackground && !backgroundFailed && !typeSize.isAccessibilitySize { changeBackgroundButton }
            }
            .padding(.vertical, Space.s2)
            if canEditBackground && backgroundFailed {
                HStack {
                    Text("Background didn’t load").font(Typeface.caption)
                        .foregroundStyle(ProfileBackgroundStyle.ink.color)
                    HeaderPill("Try again") { backgroundRetry += 1 }
                }
            } else if canEditBackground && typeSize.isAccessibilitySize {
                changeBackgroundButton
            }
            let expands = profile.backgroundKey != nil
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s3))
                : AnyLayout(HStackLayout(spacing: Space.s3))
            layout {
                if isMe {
                    HeaderPill("Close friends · \(model.closeFriends.count)", systemImage: "star.circle", expands: expands) { editingCloseFriends = true }
                        .disabled(model.privateReason != nil)
                    if model.backgroundStore != nil, profile.backgroundKey == nil {
                        HeaderPill("Background", systemImage: "photo.on.rectangle") { editingBackground = true }
                    }
                    if model.settings.privateAccount {
                        HeaderPill("Requests · \(model.followRequests.count)", systemImage: "person.crop.circle.badge.questionmark", expands: expands) { showingRequests = true }
                    }
                } else if profile.iFollow {
                    HeaderPill("Following", systemImage: "checkmark", expands: expands) { confirmingUnfollow = true }.disabled(busy)
                    messageButton(profile)
                } else if profile.requested {
                    HeaderPill("Requested", systemImage: "clock", expands: expands) { Task { await follow(false) } }.disabled(busy)
                        .accessibilityHint("Takes back your request")
                } else {
                    HeaderPill(profile.privateAccount ? "Request to follow" : profile.followsMe ? "Follow back" : "Follow", isProminent: true, expands: expands) {
                        Task { await follow(true) }
                    }
                    .disabled(busy)
                    messageButton(profile)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .leading : .center)
            .padding(.top, Space.s1)
        }
    }

    private func identity(_ profile: SocialProfile) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            Text(profile.name).font(Typeface.title)
                .foregroundStyle(profile.backgroundKey == nil ? theme.textPrimary.color : ProfileBackgroundStyle.ink.color)
            Text(Handle.display(profile.username)).font(Typeface.callout)
                .foregroundStyle(profile.backgroundKey == nil ? theme.textSecondary.color : ProfileBackgroundStyle.secondaryInk.color)
            if profile.followsMe && !isMe {
                Text(profile.iFollow ? "Friends" : "Follows you").font(Typeface.micro)
                    .foregroundStyle(profile.backgroundKey == nil ? theme.success.color : ProfileBackgroundStyle.ink.color)
            }
        }
    }

    private var changeBackgroundButton: some View {
        Button { editingBackground = true } label: {
            Text("Change")
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(ProfileBackgroundStyle.ink.color)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .background(ProfileBackgroundStyle.glass.color, in: Capsule())
                .frame(minHeight: Metric.headerButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("Change background")
    }

    private func avatar(_ profile: SocialProfile) -> some View {
        let theme = Theme.current
        return StoryFace(photo: model.photos[username], name: profile.name, ring: model.ring(for: username),
                  diameter: Space.s8 + Space.s4, overPhoto: profile.backgroundKey != nil)
            .onTapGesture { if model.ring(for: username) != nil { model.requestedStories = username } }
            .overlay(alignment: .bottomTrailing) {
                if isMe {
                    Button { model.requestsStoryComposer = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.accentOn.color)
                            .frame(width: 22, height: 22)
                            .background(theme.accent.color, in: Circle())
                            .overlay {
                                Circle().strokeBorder(profile.backgroundKey == nil ? theme.bg.color : theme.surface.color, lineWidth: 2.5)
                            }
                            .frame(width: Metric.headerButton, height: Metric.headerButton, alignment: .bottomTrailing)
                            .offset(x: -2, y: -2)
                            .contentShape(Circle())
                    }
                    .buttonStyle(SoftPress())
                    .accessibilityLabel("Add to your story")
                }
            }
    }

    /// Opens your chat with them in Messages, when their "Who can message me" lets you.
    @ViewBuilder
    private func messageButton(_ profile: SocialProfile) -> some View {
        if let onMessage = model.onMessage, profile.canMessage {
            HeaderPill("Message", systemImage: "bubble.left", iconOnly: profile.backgroundKey == nil, expands: profile.backgroundKey != nil) { onMessage(profile.username) }
        }
        if let maker = model.contactMaker {
            AddToContactsButton(maker: maker, username: profile.username, displayName: profile.displayName)
        }
    }

    /// "1 post", "2 posts".
    static func label(_ value: Int, _ one: String, _ many: String) -> String { value == 1 ? one : many }

    private func statLabel(_ value: Int, _ label: String) -> some View {
        let theme = Theme.current
        return VStack(spacing: Space.s1 / 2) {
            Text("\(value)").font(Typeface.headline).foregroundStyle(profile?.backgroundKey == nil ? theme.textPrimary.color : ProfileBackgroundStyle.ink.color).monospacedDigit()
            Text(label).font(Typeface.caption).foregroundStyle(profile?.backgroundKey == nil ? theme.textSecondary.color : ProfileBackgroundStyle.secondaryInk.color)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: Metric.headerButton)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// One stat in the row. One that opens its list is the whole column as a button, which looks the same
    /// and answers a press with SoftPress's scale and fade.
    @ViewBuilder
    private func stat(_ value: Int, _ label: String, canOpen: Bool = false, action: (() -> Void)? = nil) -> some View {
        if canOpen, let action {
            Button(action: action) { statLabel(value, label) }
                .buttonStyle(SoftPress())
                .accessibilityHint("Opens the list")
        } else {
            statLabel(value, label)
        }
    }

    private func load() async {
        do {
            profile = try await model.profile(username)
            fetched = try await model.posts(by: username)
            postsLoaded = true
            hasMore = model.hasMore(after: fetched)
            model.remember(fetched)
            problem = nil
        } catch SocialError.noSuchPerson(_) {
            // The same response is used for a missing profile and for a block.
            profile = nil
            backgroundImage = nil
            loadedBackgroundKey = nil
            problem = "This profile is unavailable."
        } catch {
            problem = SocialModel.message(error)
        }
    }

    /// The next page, once the oldest post shown scrolls into view.
    private func loadMore() async {
        guard hasMore, !loadingMore, let oldest = fetched.last?.feedDate else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await model.posts(by: username, before: oldest) else { return }
        let shown = Set(fetched.map(\.id))
        fetched += page.filter { !shown.contains($0.id) }
        hasMore = model.hasMore(after: page)
        model.remember(page)
    }

    private func follow(_ on: Bool) async {
        busy = true
        if await model.setFollowing(on, username) { await load() }
        busy = false
    }
}

/// Finding people by handle or name.
struct PeopleSearchView: View {
    let model: SocialModel
    let onPick: (String) -> Void
    /// None when Search is a tab rather than a sheet.
    var onClose: (() -> Void)?
    @State private var query = ""
    @State private var results: [SocialProfile] = []
    /// The query the shown results answer, so "No one matches" never shows while a newer search is still running.
    @State private var answered = ""

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Search").font(Typeface.title)
                Spacer()
                if let onClose { HeaderButton("Close", systemImage: "xmark", action: onClose) }
            }
            SearchBox("People on Totality", text: $query)
            ScrollView {
                VStack(spacing: Space.s2) {
                    ForEach(results, id: \.username) { person in
                        Button { onPick(person.username) } label: {
                            HStack(spacing: Space.s3) {
                                PersonFace(photo: model.photos[person.username], name: person.name, diameter: Space.s6)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(person.name).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                                    Text(Handle.display(person.username)).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                                }
                                Spacer()
                            }
                            .itemCard()
                        }
                        .buttonStyle(SoftPress())
                    }
                    if results.isEmpty && !query.isEmpty && answered != query {
                        ProgressView().padding(Space.s4).accessibilityLabel("Searching")
                    } else if results.isEmpty && !query.isEmpty {
                        Text("No one matches \"\(query)\".").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                }
            }
        }
        .padding(Space.s4)
        .background(theme.bg.color.ignoresSafeArea())
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let asked = query
            results = await model.search(asked)
            answered = asked
        }
    }
}

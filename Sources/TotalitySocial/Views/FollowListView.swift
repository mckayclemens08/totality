import SwiftUI
import TotalityCore
import TotalityUI

/// Someone's Followers and Following, pushed from the counts on their profile (mockup approved
/// 2026-11-19). One tab capsule, a search box, and a row per person that opens their profile. On your own
/// lists each row has a More button: Remove follower on Followers, Close friends and Mute on Following.
struct FollowListView: View {
    let model: SocialModel
    let username: String
    let open: (SocialHomeView.Route) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var list: FollowList
    @State private var profile: SocialProfile?
    @State private var query = ""
    @State private var acting: SocialPerson?
    @State private var confirmingUnfollow: SocialPerson?

    init(model: SocialModel, username: String, followers: Bool, open: @escaping (SocialHomeView.Route) -> Void) {
        self.model = model
        self.username = username
        self.open = open
        _list = State(initialValue: FollowList(social: model, username: username, showingFollowers: followers))
    }

    /// A list already loaded, for previews and renders, which don't run `task`.
    init(model: SocialModel, list: FollowList, profile: SocialProfile?, query: String = "", open: @escaping (SocialHomeView.Route) -> Void) {
        self.model = model
        username = list.username
        self.open = open
        _list = State(initialValue: list)
        _profile = State(initialValue: profile)
        _query = State(initialValue: query)
    }

    /// Where the list shows from, so a new tab or search starts again from the top.
    private struct Request: Equatable { let followers: Bool; let query: String }

    var body: some View {
        page(scrolling: true)
        .hidesNavigationBar()
        .task { profile = try? await model.profile(username) }
        .task(id: Request(followers: list.showingFollowers, query: query)) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await list.reload(query: query)
        }
        .sheet(item: $acting) { person in
            PersonActionsSheet(list: list, person: person, onFollowers: list.showingFollowers) { acting = nil }
        }
        .confirmationDialog("Unfollow \(confirmingUnfollow.map { Handle.display($0.username) } ?? "")?",
                            isPresented: Binding(get: { confirmingUnfollow != nil }, set: { if !$0 { confirmingUnfollow = nil } }),
                            titleVisibility: .visible, presenting: confirmingUnfollow) { person in
            Button("Unfollow", role: .destructive) { Task { await list.setFollowing(false, person) } }
        } message: { _ in
            Text("Their posts leave your Following. If you were friends, they stop getting your new Friends posts.")
        }
    }

    /// The screen. Renders pass `scrolling: false`, because ImageRenderer draws a ScrollView blank.
    func page(scrolling: Bool) -> some View {
        let theme = Theme.current
        return VStack(spacing: Space.s3) {
            header
            tabs
            SearchBox(list.showingFollowers ? "Search followers" : "Search following", text: $query)
            if scrolling {
                ScrollView {
                    content.padding(.bottom, Space.s5)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await list.reload(query: query) }
            } else {
                content
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s4)
        .background(theme.bg.color.ignoresSafeArea())
    }

    private var header: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            HeaderButton("Back", systemImage: "chevron.left") { dismiss() }
            VStack(spacing: 0) {
                Text(profile?.name ?? username).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                Text(Handle.display(username)).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Color.clear.frame(width: Metric.headerButton, height: Metric.headerButton).accessibilityHidden(true)
        }
    }

    private var tabs: some View {
        HStack(spacing: Space.s1) {
            ListTab(title: count(profile?.followers, "Followers"), isSelected: list.showingFollowers) { list.showingFollowers = true }
            ListTab(title: count(profile?.following, "Following"), isSelected: !list.showingFollowers) { list.showingFollowers = false }
        }
        .padding(Space.s1)
        .neumorphic(.subtle, in: Capsule())
    }

    private func count(_ value: Int?, _ label: String) -> String {
        guard let value else { return label }
        return "\(value) \(label)"
    }

    @ViewBuilder
    private var content: some View {
        switch list.phase {
        case .loading:
            LoadingRows()
        case .failed(let problem):
            ProblemView(systemImage: "person.2.slash", title: "This list didn't load", detail: problem) {
                Task { await list.reload(query: query) }
            }
        case .ready:
            if list.people.isEmpty {
                empty
            } else {
                LazyVStack(spacing: Space.s3) {
                    if !query.isEmpty {
                        Text(list.people.count == 1 ? "1 match" : "\(list.people.count)\(list.hasMore ? "+" : "") matches")
                            .font(Typeface.caption).foregroundStyle(Theme.current.textSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(list.people) { person in
                        row(person)
                            .onAppear { if person == list.people.last { Task { await list.loadMore() } } }
                    }
                }
                // Room for the cards' shadow pair, which the scroll view would otherwise clip.
                .padding(.vertical, Space.s2)
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        let mine = list.isMine
        if !query.isEmpty {
            EmptyFeed(systemImage: "magnifyingglass",
                      title: "No one \(list.showingFollowers ? "on this list" : mine ? "you follow" : "here") matches \"\(query)\"",
                      detail: "Search looks at names and @usernames on this list. To find someone new, use Search on the Social home.")
        } else if list.showingFollowers {
            EmptyFeed(systemImage: "person.2", title: "No followers yet",
                      detail: mine ? "When someone follows you, they show here." : "When someone follows \(profile?.name ?? username), they show here.")
        } else {
            EmptyFeed(systemImage: "person.2", title: "Not following anyone yet",
                      detail: mine ? "People you follow show here. Find them with Search on the Social home." : "When \(profile?.name ?? username) follows someone, they show here.")
        }
    }

    private func row(_ person: SocialPerson) -> some View {
        let theme = Theme.current
        let relationship = Relationship(person, me: model.me)
        let tags = Self.tags(person, isMine: list.isMine, closeFriends: model.closeFriends)
        return HStack(spacing: Space.s2) {
            Button { open(.profile(person.username)) } label: {
                HStack(spacing: Space.s3) {
                    PersonFace(photo: list.photos[person.username] ?? model.photos[person.username], name: person.name, diameter: Metric.headerButton)
                    VStack(alignment: .leading, spacing: Space.s1 / 2) {
                        Text(person.name).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                        Text(Handle.display(person.username)).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !tags.isEmpty {
                            HStack(spacing: Space.s1) {
                                ForEach(tags, id: \.self) { TagBadge(tag: $0) }
                            }
                            .padding(.top, Space.s1 / 2)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            .accessibilityElement(children: .combine)
            relationshipButton(relationship, person)
            if list.isMine {
                Button { acting = person } label: {
                    Image(systemName: "ellipsis")
                        .font(Typeface.body.weight(.semibold))
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: Metric.headerButton, height: Metric.headerButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel("More for \(person.name)")
            }
        }
        .padding(.vertical, Space.s2)
        .padding(.leading, Space.s3)
        .padding(.trailing, list.isMine ? 0 : Space.s2)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    /// The small tags under a row's @username. Close friend comes only from your own Close-friends set,
    /// only on your own lists, and only for someone the server says the signed-in account follows: no one
    /// else ever sees it, and a row that doesn't match the signed-in account can't carry it.
    static func tags(_ person: SocialPerson, isMine: Bool, closeFriends: Set<String>) -> [RowTag] {
        var tags: [RowTag] = []
        if isMine && person.iFollow && closeFriends.contains(person.username) { tags.append(.closeFriend) }
        else if person.iFollow && person.followsMe { tags.append(.friends) }
        if person.muted { tags.append(.muted) }
        return tags
    }

    enum RowTag: Hashable {
        case closeFriend, friends, muted

        var title: String {
            switch self {
            case .closeFriend: "Close friend"
            case .friends: "Friends"
            case .muted: "Muted"
            }
        }

        var systemImage: String {
            switch self {
            case .closeFriend: "star.fill"
            case .friends: "person.2.fill"
            case .muted: "speaker.slash.fill"
            }
        }
    }

    @ViewBuilder
    private func relationshipButton(_ relationship: Relationship, _ person: SocialPerson) -> some View {
        switch relationship {
        case .you:
            Text(relationship.title).font(Typeface.caption.weight(.semibold)).foregroundStyle(Theme.current.textSecondary.color)
                .padding(.horizontal, Space.s2)
        case .following:
            RowButton(title: relationship.title, style: .quiet) { confirmingUnfollow = person }
                .accessibilityHint("Asks before unfollowing")
        case .requested:
            RowButton(title: relationship.title, style: .quiet) { Task { await list.setFollowing(false, person) } }
                .accessibilityHint("Takes back your request")
        case .follow:
            RowButton(title: relationship.title, style: .accentText) { Task { await list.setFollowing(true, person) } }
        case .followBack:
            RowButton(title: relationship.title, style: .filled) { Task { await list.setFollowing(true, person) } }
        }
    }
}

/// A row's small tag: an icon and a word on a soft raised capsule.
private struct TagBadge: View {
    let tag: FollowListView.RowTag

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s1) {
            Image(systemName: tag.systemImage)
                .foregroundStyle(tag == .closeFriend ? theme.accent.color : theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(tag.title).foregroundStyle(theme.textSecondary.color)
        }
        .font(Typeface.micro)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Space.s2)
        .padding(.vertical, Space.s1 / 2)
        .neumorphic(.subtle, in: Capsule())
    }
}

/// One half of the Followers | Following capsule: filled with the accent when it's showing.
private struct ListTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Text(title)
                .font(Typeface.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isSelected ? theme.accentOn.color : theme.textSecondary.color)
                .frame(maxWidth: .infinity, minHeight: Metric.headerButton - Space.s1)
                .background { if isSelected { Capsule().fill(theme.accent.color) } }
                .contentShape(Capsule())
        }
        .buttonStyle(SoftPress())
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A row's relationship button: a compact pill with a 44pt tap area. Only Follow back, for someone who
/// already follows you, is filled with the accent; Follow is a raised pill in the accent; the rest are
/// raised and quiet.
private struct RowButton: View {
    enum Style { case filled, accentText, quiet }

    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Text(title)
                .font(Typeface.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(style == .filled ? theme.accentOn.color : style == .accentText ? theme.accent.color : theme.textSecondary.color)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s1 + Space.s1 / 2)
                .background { if style == .filled { Capsule().fill(theme.accent.color) } }
                .modifier(RaisedIfPlain(isFilled: style == .filled))
                .frame(minHeight: Metric.headerButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
    }
}

private struct RaisedIfPlain: ViewModifier {
    let isFilled: Bool

    func body(content: Content) -> some View {
        if isFilled { content } else { content.neumorphic(.subtle, in: Capsule()) }
    }
}

/// The loading state: soft blank rows in the list's shape.
private struct LoadingRows: View {
    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            ForEach(0..<6, id: \.self) { i in
                HStack(spacing: Space.s3) {
                    Circle().fill(theme.highlight.color).frame(width: Metric.headerButton, height: Metric.headerButton)
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Capsule().fill(theme.highlight.color).frame(width: i.isMultiple(of: 2) ? Space.s8 * 2 : Space.s8 + Space.s6, height: Space.s3)
                        Capsule().fill(theme.highlight.color).frame(width: Space.s8 + Space.s2, height: Space.s2)
                    }
                    Spacer()
                }
                .padding(Space.s3)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
        }
        .padding(.vertical, Space.s2)
        .accessibilityElement()
        .accessibilityLabel("Loading people")
    }
}

/// What the More button on your own lists opens. On Followers: Remove follower, then a confirm. On
/// Following: Close friends and Mute, which undo from the same place, so they need no confirm.
struct PersonActionsSheet: View {
    let list: FollowList
    let person: SocialPerson
    let onFollowers: Bool
    let onClose: () -> Void
    @State private var confirmingRemove = false
    @State private var busy = false

    var body: some View {
        let theme = Theme.current
        let first = person.name.split(separator: " ").first.map(String.init) ?? person.name
        VStack(spacing: Space.s4) {
            if confirmingRemove {
                PersonFace(photo: list.photos[person.username], name: person.name, diameter: Space.s8)
                Text("Remove \(first) as a follower?").font(Typeface.title).foregroundStyle(theme.textPrimary.color)
                    .multilineTextAlignment(.center)
                Text("\(first) isn't told. You stop being Friends, so \(first) won't get your new Friends or Close-friends posts. \(first) can follow you again unless you block.")
                    .font(Typeface.body).foregroundStyle(theme.textSecondary.color).multilineTextAlignment(.center)
                SheetButton(title: "Remove follower", tint: theme.danger.color) {
                    Task { busy = true; await list.remove(person); busy = false; onClose() }
                }
                .disabled(busy)
                cancel
            } else {
                HStack(spacing: Space.s3) {
                    PersonFace(photo: list.photos[person.username], name: person.name, diameter: Space.s7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(person.name).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        Text(Handle.display(person.username)).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                    Spacer(minLength: 0)
                }
                if onFollowers {
                    ActionRow(systemImage: "person.badge.minus", title: "Remove follower",
                              detail: "\(first) stops following you. You'll be asked first.", tint: theme.danger.color) {
                        confirmingRemove = true
                    }
                } else {
                    let close = list.isCloseFriend(person)
                    ActionRow(systemImage: close ? "star.slash" : "star", title: close ? "Remove from Close friends" : "Add to Close friends",
                              detail: list.closeFriendsReason ?? (close ? "\(first) stops getting your new Close-friends posts. \(first) isn't told."
                                                                       : "\(first) gets your Close-friends posts from now on. \(first) isn't told."),
                              tint: theme.accent.color) {
                        Task { busy = true; await list.setCloseFriend(!close, person); busy = false; onClose() }
                    }
                    .disabled(list.closeFriendsReason != nil || busy)
                    ActionRow(systemImage: person.muted ? "speaker.wave.2" : "speaker.slash", title: person.muted ? "Unmute" : "Mute",
                              detail: person.muted ? "\(first)'s posts come back to your feeds." : "\(first)'s posts leave your feeds. You still follow \(first), and \(first) isn't told.",
                              tint: theme.accent.color) {
                        Task { busy = true; await list.setMuted(!person.muted, person); busy = false; onClose() }
                    }
                    .disabled(busy)
                }
                cancel
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.top, Space.s5)
        .padding(.bottom, Space.s4)
        .frame(maxWidth: .infinity)
        .background(theme.surface.color.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var cancel: some View {
        Button("Cancel", action: onClose)
            .font(Typeface.headline)
            .foregroundStyle(Theme.current.textPrimary.color)
            .frame(maxWidth: .infinity, minHeight: Space.s7)
            .contentShape(Rectangle())
            .buttonStyle(SoftPress())
    }
}

private struct ActionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Image(systemName: systemImage).font(Typeface.title).foregroundStyle(tint).frame(width: Space.s6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                    Text(detail).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
    }
}

private struct SheetButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.headline)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: Space.s7)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
    }
}

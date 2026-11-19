import SwiftUI
import TotalityCore
import TotalityUI

/// Someone's profile: the one public profile (owner, 2026-11-17). Photo, name, @handle, bio, counts,
/// Follow, and their posts. On your own, Close friends is here too.
struct SocialProfileView: View {
    let model: SocialModel
    let username: String
    let open: (SocialHomeView.Route) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profile: SocialProfile?
    @State private var posts: [SocialPost] = []
    @State private var problem: String?
    @State private var busy = false
    @State private var confirmingUnfollow = false
    @State private var editingCloseFriends = false

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                HeaderButton("Back", systemImage: "chevron.left") { dismiss() }
                if let profile {
                    header(profile)
                    if posts.isEmpty {
                        EmptyFeed(systemImage: "square.and.pencil", title: "No posts yet",
                                  detail: isMe ? "Your posts show here, whoever you share them with." : "When \(profile.name) posts, it shows here.")
                    } else {
                        PostGrid(posts: posts, photos: model.photos, onShow: { _ in }) { open(.post($0.id)) }
                    }
                } else if let problem {
                    ProblemView(systemImage: "person.crop.circle.badge.questionmark", title: "This profile didn't open", detail: problem) {
                        Task { await load() }
                    }
                } else {
                    LoadingGrid()
                }
            }
            .padding(Space.s4)
        }
        .background(theme.bg.color.ignoresSafeArea())
        .hidesNavigationBar()
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Unfollow \(Handle.display(username))?", isPresented: $confirmingUnfollow, titleVisibility: .visible) {
            Button("Unfollow", role: .destructive) { Task { await follow(false) } }
        } message: {
            Text("Their posts leave your Following. If you were friends, they stop getting your new Friends posts.")
        }
        .sheet(isPresented: $editingCloseFriends) { CloseFriendsView(model: model) { editingCloseFriends = false } }
    }

    private var isMe: Bool { username == model.me }

    private func header(_ profile: SocialProfile) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s4) {
                PersonFace(photo: model.photos[username], name: profile.name, diameter: Space.s8 + Space.s4)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(profile.name).font(Typeface.title).foregroundStyle(theme.textPrimary.color)
                    Text(Handle.display(profile.username)).font(Typeface.callout).foregroundStyle(theme.textSecondary.color)
                    if profile.followsMe && !isMe {
                        Text(profile.iFollow ? "Friends" : "Follows you").font(Typeface.micro).foregroundStyle(theme.success.color)
                    }
                }
            }
            if let bio = profile.bio, !bio.isEmpty {
                Text(bio).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
            }
            HStack(spacing: Space.s5) {
                count(profile.posts, "posts")
                count(profile.followers, profile.followers == 1 ? "follower" : "followers")
                count(profile.following, "following")
            }
            HStack(spacing: Space.s3) {
                if isMe {
                    HeaderPill("Close friends · \(model.closeFriends.count)", systemImage: "star.circle") { editingCloseFriends = true }
                        .disabled(model.privateReason != nil)
                } else if profile.iFollow {
                    HeaderPill("Following", systemImage: "checkmark") { confirmingUnfollow = true }.disabled(busy)
                } else {
                    HeaderPill(profile.followsMe ? "Follow back" : "Follow", isProminent: true) { Task { await follow(true) } }.disabled(busy)
                }
            }
            if isMe {
                Text("Your profile is public: anyone on Totality can see your photo, name, bio and public posts. Edit them from Account.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
            Text(label).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            profile = try await model.profile(username)
            posts = try await model.posts(by: username)
            problem = nil
        } catch {
            problem = SocialModel.message(error)
        }
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
    let onClose: () -> Void
    @State private var query = ""
    @State private var results: [SocialProfile] = []

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Search").font(Typeface.title)
                Spacer()
                HeaderButton("Close", systemImage: "xmark", action: onClose)
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
                    if results.isEmpty && !query.isEmpty {
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
            results = await model.search(query)
        }
    }
}

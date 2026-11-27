import SwiftUI
import TotalityUI

/// The tabs along the bottom of Social (the canvas the owner approved on 2026-11-19, recommended layout):
/// Feed, Search, the accent + for a new post in the centre, Saved and Profile. The bar shows on the four
/// tab screens, hides on pushed ones (a post, someone else's profile) and stays put while scrolling.
enum SocialTab: CaseIterable, Identifiable, Hashable {
    case feed, search, newPost, saved, profile

    var id: Self { self }

    var title: String {
        switch self {
        case .feed: "Feed"
        case .search: "Search"
        case .newPost: "New post"
        case .saved: "Saved"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .feed: "house"
        case .search: "magnifyingglass"
        case .newPost: "plus"
        case .saved: "bookmark"
        case .profile: "person"
        }
    }

    /// What tapping a tab does: the + opens the composer over the current tab, and every other tab
    /// becomes the one showing. Saved and Profile need you signed in, so they do nothing without a username.
    enum Destination: Equatable {
        case show(SocialTab)
        case compose
    }

    func destination(me: String?) -> Destination? {
        switch self {
        case .newPost: .compose
        case .saved, .profile: me == nil ? nil : .show(self)
        case .feed, .search: .show(self)
        }
    }
}

/// The raised bar itself. The chosen tab is raised and in the accent, never pressed in; the + is the
/// accent round that used to float at the bottom right.
struct SocialTabBar: View {
    let selected: SocialTab
    let me: String?
    let onSelect: (SocialTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SocialTab.allCases) { tab in
                Group {
                    if tab == .newPost {
                        AddButton(tab.title) { onSelect(tab) }
                    } else {
                        TabItem(tab: tab, isSelected: tab == selected) { onSelect(tab) }
                            .disabled(tab.destination(me: me) == nil)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Space.s1)
        .frame(height: Metric.tabBar)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s1)
    }
}

private struct TabItem: View {
    let tab: SocialTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            VStack(spacing: Space.s1) {
                Image(systemName: tab.systemImage)
                    .font(Typeface.headline.weight(isSelected ? .bold : .regular))
                Text(tab.title)
                    .font(Typeface.micro.weight(isSelected ? .bold : .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? theme.accent.color : theme.textSecondary.color)
            .frame(width: Metric.tabItemWidth, height: Metric.tabItemHeight)
            .background {
                if isSelected {
                    Color.clear.neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The public posts you saved, on their own as the Saved tab. Only you see them.
struct SavedPostsView: View {
    let model: SocialModel
    let open: (SocialHomeView.Route) -> Void

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                ScreenTitle("Saved")
                if !model.savedLoaded && model.saved.isEmpty {
                    LoadingGrid()
                } else if model.saved.isEmpty {
                    EmptyFeed(systemImage: "bookmark", title: "Nothing saved yet", detail: "Tap Save on a public post to keep it here. Only you can see what you saved.")
                        .frame(maxWidth: .infinity)
                } else {
                    PostGrid(model: model, posts: model.saved, photos: model.photos, onShow: { _ in }) { open(.post($0.id)) }
                }
            }
            .padding(Space.s4)
        }
        .background(theme.bg.color.ignoresSafeArea())
        .refreshable { await model.loadSaved() }
        .task { await model.loadSaved() }
    }
}

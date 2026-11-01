import SwiftUI
import TotalityUI

#if os(iOS)
private typealias PlatformImage = UIImage
#else
private typealias PlatformImage = NSImage
#endif

/// Search results in Totality's own design, not a web page.
struct WebResultsView: View {
    let model: WebModel
    let tab: WebTab

    var body: some View {
        VStack(spacing: 0) {
            categories
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var categories: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s2) {
            ForEach(WebCategory.allCases) { category in
                let isChosen = tab.search.category == category
                Button {
                    model.choose(category)
                } label: {
                    Text(category.label)
                        .font(Typeface.callout)
                        .foregroundStyle(isChosen ? theme.accent.color : theme.textSecondary.color)
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, Space.s2)
                        .background {
                            if isChosen { Color.clear.neumorphic(.pressed, in: Capsule()) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
    }

    @ViewBuilder private var content: some View {
        let search = tab.search
        switch search.phase {
        case .searching:
            ProgressView().accessibilityLabel("Searching")
        case .failed(let error):
            failure(error)
        case .done where search.results.isEmpty:
            WebMessage(
                systemImage: "magnifyingglass",
                title: search.partial ? "Search isn't answering" : "No matches",
                detail: search.partial ? "A search engine stopped answering, so there's nothing to show." : "Nothing came back for this search.",
                action: search.partial ? tryAgain : nil,
                alternative: publicSearch
            )
        case .done:
            results
        }
    }

    private func failure(_ error: WebSearchError) -> some View {
        let shown: (image: String, title: String, detail: String) = switch error {
        case .signedOut: ("person.crop.circle.badge.exclamationmark", "Sign in to search", "Search runs on your server, so it needs your Totality sign-in.")
        case .limitReached: ("hourglass", "That's a lot of searches", "There's a limit for each account. Try again in a little while.")
        case .offline: ("wifi.slash", "You're offline", "Check your connection and try again.")
        case .unavailable: ("exclamationmark.magnifyingglass", "Search isn't answering", "Your server didn't respond. It may be down.")
        }
        return WebMessage(
            systemImage: shown.image, title: shown.title, detail: shown.detail,
            action: error == .signedOut ? nil : tryAgain,
            alternative: error == .offline ? nil : publicSearch
        )
    }

    private var tryAgain: WebMessageAction {
        WebMessageAction(label: "Try again") { model.retry() }
    }

    private var publicSearch: WebMessageAction {
        WebMessageAction(label: "Search on DuckDuckGo", note: "DuckDuckGo's site will see your device's address.") {
            model.openOnPublicSearch()
        }
    }

    private var results: some View {
        let theme = Theme.current
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s4) {
                if tab.search.partial {
                    Text("A search engine stopped answering, so there may be fewer results.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                if tab.search.category == .images {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s3), GridItem(.flexible())], spacing: Space.s3) {
                        ForEach(tab.search.results) { imageResult($0) }
                    }
                } else {
                    ForEach(tab.search.results) { row($0) }
                }
                if tab.search.canLoadMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .onAppear { model.loadMore() }
                        .accessibilityLabel("Loading more")
                }
                Text(WebCopy.notEncrypted)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.top, Space.s3)
            }
            .frame(maxWidth: Space.s8 * 10, alignment: .leading)
            .padding(Space.s4)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ result: WebResult) -> some View {
        let theme = Theme.current
        return Button {
            model.open(result.url)
        } label: {
            HStack(alignment: .top, spacing: Space.s3) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(result.site)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                    Text(result.title)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                        .multilineTextAlignment(.leading)
                    if !result.snippet.isEmpty {
                        Text(result.snippet)
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                if tab.search.category == .videos, let thumbnail = result.thumbnail {
                    WebThumbnailView(model: model, thumbnail: thumbnail)
                        .frame(width: Space.s8 * 1.5, height: Space.s8)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func imageResult(_ result: WebResult) -> some View {
        let theme = Theme.current
        return Button {
            model.open(result.url)
        } label: {
            VStack(alignment: .leading, spacing: Space.s1) {
                Group {
                    if let thumbnail = result.thumbnail {
                        WebThumbnailView(model: model, thumbnail: thumbnail)
                    } else {
                        Rectangle().fill(theme.surfaceSunken.color)
                    }
                }
                .frame(height: Space.s8 * 2)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                Text(result.site)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.title)
    }
}

/// Loads through the server, so it can't use `AsyncImage`.
private struct WebThumbnailView: View {
    let model: WebModel
    let thumbnail: WebThumbnail

    @State private var image: Image?

    var body: some View {
        let theme = Theme.current
        ZStack {
            Rectangle().fill(theme.surfaceSunken.color)
            image?.resizable().scaledToFill()
        }
        .task(id: thumbnail) {
            guard let data = await model.thumbnail(thumbnail), let loaded = PlatformImage(data: data) else { return }
            #if os(iOS)
            image = Image(uiImage: loaded)
            #else
            image = Image(nsImage: loaded)
            #endif
        }
        .accessibilityHidden(true)
    }
}

enum WebCopy {
    static let notEncrypted = "Web searches aren't end-to-end encrypted. They go to your server through Cloudflare, and your server keeps no record of them."
    static let privateTab = "This tab keeps no history, cookies, or site data once it's closed. Sites you open still see your device's address."
}

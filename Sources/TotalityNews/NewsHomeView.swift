import SwiftUI
import TotalityCore
import TotalityUI

public struct NewsHomeView: View {
    private enum Section: String { case today = "Today", search = "Search", saved = "Saved", following = "Following" }

    private let model: NewsModel
    private let onClose: () -> Void
    private let onOpen: (ContentRef) -> Void
    @State private var section = Section.today
    @State private var topic = ""
    @State private var publisherQuery = ""
    @State private var changingPublishers = Set<URL>()

    public init(model: NewsModel, onClose: @escaping () -> Void, onOpen: @escaping (ContentRef) -> Void) {
        self.model = model
        self.onClose = onClose
        self.onOpen = onOpen
    }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s4) {
            header.padding(.horizontal, Space.s4).padding(.top, Space.s4)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if section != .search, let notice = model.notice {
                        Text(notice).font(Typeface.caption).foregroundStyle(theme.danger.color)
                    }
                    switch section {
                    case .today:
                        today
                    case .search:
                        discover
                    case .saved:
                        if model.record.saved.isEmpty {
                            Text("Articles you save will appear here.").foregroundStyle(theme.textSecondary.color)
                        }
                        rows(model.record.saved)
                    case .following:
                        sources
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.bottom, Space.s4)
            }
            .id(section)
            .refreshable { await reload() }
        }
        .background(theme.bg.color.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary.color)
        .task { await model.refreshAhead() }
        .task { await model.refreshTopStories() }
        .task(id: section) {
            if section == .search && !model.discoveryLoaded { await model.discover("") }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s2) {
                headerTitle
                Spacer(minLength: 0)
                if section == .today { headerActions }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                headerTitle
                if section == .today { headerActions }
            }
        }
    }

    private var headerTitle: some View {
        HStack(spacing: Space.s2) {
            HeaderButton(section == .today ? "Back" : "Back to Today", systemImage: "chevron.left") {
                if section == .today { onClose() } else { section = .today }
            }
            Text(section.rawValue).font(Typeface.title).accessibilityAddTraits(.isHeader)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var headerActions: some View {
        HStack(spacing: Space.s2) {
            HeaderButton("Search", systemImage: "magnifyingglass") { section = .search }
            HeaderButton("Saved", systemImage: "bookmark") { section = .saved }
            HeaderButton("Following", systemImage: "list.bullet") { section = .following }
        }
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.textSecondary.color)
            let articles = model.todayStories
            if let lead = articles.first {
                story(lead, featured: true)
                if articles.contains(where: { $0.throughGDELT == true }) {
                    Link("Some stories via the GDELT Project", destination: URL(string: "https://www.gdeltproject.org/")!)
                        .font(Typeface.caption)
                        .foregroundStyle(Theme.current.accent.color)
                }
                if articles.count > 1 {
                    Text("More stories").font(Typeface.headline).accessibilityAddTraits(.isHeader)
                    rows(articles.dropFirst())
                }
            } else if model.loading || model.loadingTopStories {
                ProgressView().accessibilityLabel("Loading headlines")
            } else if model.notice == nil {
                Text("No headlines yet. Pull to refresh or follow more sources.")
                    .foregroundStyle(Theme.current.textSecondary.color)
                HeaderPill("Following") { section = .following }
            }
            if model.notice != nil && !model.loading {
                HeaderPill("Try again", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
        }
    }

    private func reload() async {
        switch section {
        case .today:
            async let feeds: Void = model.refresh()
            async let topStories: Void = model.refreshTopStories(force: true)
            _ = await (feeds, topStories)
        case .search:
            await model.discover(topic)
        case .saved, .following:
            await model.load()
        }
    }

    private var discover: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            TextField("Search a topic", text: $topic).raisedField()
                .onSubmit { Task { await model.discover(topic) } }
            HeaderPill("Search", systemImage: "magnifyingglass") { Task { await model.discover(topic) } }
                .disabled(model.discovering)
            Link("Discovery by the GDELT Project", destination: URL(string: "https://www.gdeltproject.org/")!)
                .font(Typeface.caption).foregroundStyle(Theme.current.accent.color)
            Text("Topics go directly to GDELT.").font(Typeface.caption)
            if model.discovering { ProgressView().accessibilityLabel("Searching GDELT") }
            if let notice = model.discoveryNotice { Text(notice).foregroundStyle(Theme.current.danger.color) }
            if model.discoveryLoaded && model.discovered.isEmpty && !model.discovering { Text("No stories found.") }
            rows(model.discovered)
        }
    }

    private var sources: some View {
        let query = publisherQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let publishers = NewsSource.catalog + model.record.sources.filter { source in
            !NewsSource.catalog.contains { $0.url == source.url }
        }
        let websiteMatch = NewsSource.publisher(query)?.url
        let local = publishers.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.url.host?.localizedCaseInsensitiveContains(query) == true
                || (websiteMatch != nil && NewsSource.publisher($0.url.absoluteString)?.url == websiteMatch)
        }
        var seen = Set(local.map(\.url))
        seen.formUnion(local.compactMap { NewsSource.publisher($0.url.absoluteString)?.url })
        let matching = local + model.publisherResults.filter { seen.insert($0.url).inserted }
        return VStack(alignment: .leading, spacing: Space.s3) {
            TextField("Publisher name or website", text: $publisherQuery).raisedField()
                .submitLabel(.search)
                .onSubmit { Task { await model.searchPublishers(query) } }
                .onChange(of: publisherQuery) { _, _ in model.clearPublisherSearch() }
            if !query.isEmpty {
                HeaderPill("Search publishers", systemImage: "magnifyingglass") {
                    Task { await model.searchPublishers(query) }
                }
                .disabled(model.searchingPublishers)
                Text("Name searches use Wikidata.").font(Typeface.caption)
                    .foregroundStyle(Theme.current.textSecondary.color)
            }
            if model.searchingPublishers { ProgressView().accessibilityLabel("Searching publishers") }
            if let notice = model.publisherNotice {
                Text(notice).foregroundStyle(Theme.current.textSecondary.color)
            } else if matching.isEmpty && !model.searchingPublishers {
                Text("Search by name or enter the publisher’s website.").foregroundStyle(Theme.current.textSecondary.color)
            }
            ForEach(matching) { source in
                let followed = model.record.sources.contains { $0.url == source.url }
                HStack {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(source.name).font(Typeface.headline)
                        if source.indexedPublisher == true, let domain = source.url.host, domain != source.name {
                            Text(domain).font(Typeface.caption).foregroundStyle(Theme.current.textSecondary.color)
                        }
                    }
                    Spacer()
                    HeaderPill(followed ? "Unfollow" : "Follow", isProminent: !followed) {
                        changeFollowing(source, follow: !followed)
                    }
                    .accessibilityLabel(followed ? "Unfollow " + source.name : "Follow " + source.name)
                    .disabled(changingPublishers.contains(source.url))
                }
                .itemCard()
            }
        }
    }

    private func changeFollowing(_ source: NewsSource, follow: Bool) {
        guard changingPublishers.insert(source.url).inserted else { return }
        Task {
            defer { changingPublishers.remove(source.url) }
            if follow {
                await model.follow(source)
            } else {
                await model.remove(source)
            }
        }
    }

    private func rows(_ articles: some RandomAccessCollection<NewsArticle>) -> some View {
        LazyVStack(alignment: .leading, spacing: Space.s3) {
            ForEach(articles) { article in story(article) }
            if section == .saved && articles.contains(where: { $0.throughGDELT == true }) {
                Link("Some stories via the GDELT Project", destination: URL(string: "https://www.gdeltproject.org/")!)
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.accent.color)
            }
        }
    }

    private func story(_ article: NewsArticle, featured: Bool = false) -> some View {
        let saved = model.record.saved.contains { $0.url == article.url }
        return HStack(alignment: .top, spacing: Space.s2) {
            if !featured { NewsStoryArtwork(article: article, featured: false) }
            Button {
                onOpen(model.reference(article))
            } label: {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if featured { NewsStoryArtwork(article: article, featured: true) }
                    Text(article.source)
                        .font(Typeface.caption)
                        .foregroundStyle(Theme.current.textSecondary.color)
                    Text(article.title)
                        .font(featured ? Typeface.title : Typeface.headline)
                        .foregroundStyle(Theme.current.textPrimary.color)
                    if !article.summary.isEmpty {
                        Text(article.summary)
                            .font(featured ? Typeface.body : Typeface.caption)
                            .foregroundStyle(Theme.current.textSecondary.color)
                            .lineLimit(featured ? 4 : 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            HeaderButton(saved ? "Remove from Saved" : "Save article", systemImage: saved ? "bookmark.fill" : "bookmark") {
                Task { await model.toggleSaved(article) }
            }
        }
        .itemCard()
        .contextMenu {
            if let source = model.source(for: article) {
                let followed = model.record.sources.contains { $0.url == source.url }
                Button(followed ? "Unfollow " + source.name : "Follow " + source.name) {
                    changeFollowing(source, follow: !followed)
                }
                .disabled(changingPublishers.contains(source.url))
            }
        }
    }

}

public struct NewsHomeTile: View {
    let model: NewsModel
    let size: TileSize

    public init(model: NewsModel, size: TileSize) {
        self.model = model
        self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            TileHeader("News", systemImage: "newspaper")
            if model.record.latest.isEmpty {
                Text("Your headlines").font(Typeface.tileDetail)
            } else {
                ForEach(model.record.latest.prefix(size == .small ? 1 : size == .medium ? 2 : 4)) { article in
                    Text(article.title).font(Typeface.tileDetail).lineLimit(size == .small ? 2 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.current.textPrimary.color)
        .tilePadding()
    }
}

import SwiftUI
import TotalityCore
import TotalityUI

public struct NewsHomeView: View {
    private enum Section: String, CaseIterable { case latest = "Latest", discover = "Discover", saved = "Saved", sources = "Sources" }

    private let model: NewsModel
    private let onClose: () -> Void
    private let onOpen: (ContentRef) -> Void
    @State private var section = Section.latest
    @State private var topic = ""
    @State private var address = ""
    @State private var adding = false

    public init(model: NewsModel, onClose: @escaping () -> Void, onOpen: @escaping (ContentRef) -> Void) {
        self.model = model
        self.onClose = onClose
        self.onOpen = onOpen
    }

    public var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack {
                    HeaderButton("Back", systemImage: "chevron.left", action: onClose)
                    Text("News").font(Typeface.title)
                    Spacer()
                    HeaderPill("Sources", systemImage: "dot.radiowaves.left.and.right") { section = .sources }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s2) {
                        ForEach([Section.latest, .discover, .saved], id: \.self) { item in
                            FilterPill(item.rawValue, isSelected: section == item) { section = item }
                        }
                    }
                    .padding(.vertical, Space.s2)
                }
                if let notice = model.notice { Text(notice).font(Typeface.caption).foregroundStyle(theme.danger.color) }
                switch section {
                case .latest:
                    if model.loading { ProgressView().accessibilityLabel("Loading feeds") }
                    if model.record.latest.isEmpty && !model.loading {
                        Text("No headlines yet. Pull to refresh or add a source.").foregroundStyle(theme.textSecondary.color)
                    }
                    if model.notice != nil && !model.loading {
                        HeaderPill("Try again", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    }
                    rows(model.record.latest)
                case .discover:
                    discover
                case .saved:
                    if model.record.saved.isEmpty { Text("Articles you save will appear here.").foregroundStyle(theme.textSecondary.color) }
                    rows(model.record.saved)
                case .sources:
                    sources
                }
            }
            .padding(Space.s4)
        }
        .background(theme.bg.color.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary.color)
        .refreshable { await reload() }
        .task { await model.refreshAhead() }
        .task(id: section) {
            if section == .discover && !model.discoveryLoaded { await model.discover("") }
        }
    }

    private func reload() async {
        if section == .discover { await model.discover(topic) } else { await model.refresh() }
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
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Followed sources").font(Typeface.headline)
            ForEach(model.record.sources) { source in
                HStack {
                    Text(source.name)
                    Spacer()
                    HeaderPill("Unfollow") { Task { await model.remove(source) } }
                }
                .itemCard()
            }
            TextField("RSS or Atom URL", text: $address).raisedField()
            HeaderPill(adding ? "Checking…" : "Add feed", systemImage: "plus") {
                let input = address
                adding = true
                Task {
                    if await model.add(input) { address = "" }
                    adding = false
                }
            }
            .disabled(adding || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if NewsSource.defaults.contains(where: { !model.record.sources.contains($0) }) {
                Text("Default sources").font(Typeface.headline)
                ForEach(NewsSource.defaults.filter { !model.record.sources.contains($0) }) { source in
                    HeaderPill("Follow \(source.name)", systemImage: "plus") {
                        adding = true
                        Task {
                            _ = await model.add(source.url.absoluteString)
                            adding = false
                        }
                    }
                    .disabled(adding)
                }
            }
        }
    }

    private func rows(_ articles: [NewsArticle]) -> some View {
        LazyVStack(alignment: .leading, spacing: Space.s4) {
            ForEach(articles) { article in
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(article.source).font(Typeface.caption).foregroundStyle(Theme.current.textSecondary.color)
                    Text(article.title).font(Typeface.headline)
                    if !article.summary.isEmpty { Text(article.summary).font(Typeface.body).foregroundStyle(Theme.current.textSecondary.color) }
                    HStack {
                        HeaderPill("Open", systemImage: "arrow.up.right") { onOpen(model.reference(article)) }
                        Spacer()
                        let saved = model.record.saved.contains { $0.url == article.url }
                        HeaderPill(saved ? "Remove save" : "Save", systemImage: saved ? "bookmark.fill" : "bookmark") {
                            Task { await model.toggleSaved(article) }
                        }
                    }
                }
                .itemCard()
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

import SwiftUI
import TotalityCore

/// Search inside Totality. It opens from the home page, finds things in every module, and hands a
/// tapped result back to the app to open where it lives.
public struct SearchView: View {
    @State private var model: SearchModel
    @FocusState private var isTyping: Bool
    private let modules: [ModuleEntry]
    private let onOpen: (SearchHit) -> Void
    private let onClose: () -> Void

    public init(
        search: UniversalSearch, modules: [ModuleEntry] = ModuleEntry.all,
        onOpen: @escaping (SearchHit) -> Void, onClose: @escaping () -> Void
    ) {
        _model = State(initialValue: SearchModel(search: search))
        self.modules = modules
        self.onOpen = onOpen
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.current.bg.color)
        #if os(macOS)
        .frame(minWidth: Space.s8 * 8, minHeight: Space.s8 * 8)
        #endif
        .onAppear { isTyping = true }
    }

    private var header: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                Image(systemName: "magnifyingglass")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityHidden(true)
                TextField("Search", text: $model.query)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .focused($isTyping)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        isTyping = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Space.s4)
            .frame(height: Space.s7)
            .neumorphic(.pressed, in: Capsule())
            Button("Close", action: onClose)
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Space.s4)
    }

    @ViewBuilder private var content: some View {
        let results = model.results
        if model.phase == .waiting {
            SearchMessage(
                systemImage: "magnifyingglass", title: "Search your notes, files, and events",
                detail: "Searching happens on this device. Nothing you type is saved or sent."
            )
        } else if results.groups.isEmpty {
            if model.phase == .searching {
                ProgressView()
                    .accessibilityLabel("Searching")
            } else if results.failed.isEmpty {
                SearchMessage(
                    systemImage: "magnifyingglass", title: "No matches",
                    detail: "Nothing in your notes, files, or events has all of these words."
                )
            } else {
                SearchMessage(
                    systemImage: "exclamationmark.magnifyingglass", title: "Search didn't finish",
                    detail: missing(results.failed)
                )
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s5) {
                    if !results.failed.isEmpty {
                        Text(missing(results.failed))
                            .font(Typeface.caption)
                            .foregroundStyle(Theme.current.textSecondary.color)
                    }
                    ForEach(results.groups) { group in
                        groupView(group)
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.bottom, Space.s6)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func groupView(_ group: SearchResults.Group) -> some View {
        let entry = modules.first { $0.id == group.module }
        return VStack(alignment: .leading, spacing: Space.s2) {
            Label(entry?.name ?? "Results", systemImage: entry?.systemImage ?? "magnifyingglass")
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.textSecondary.color)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.hits) { hit in
                    SearchRow(hit: hit, terms: model.terms) { onOpen(hit) }
                }
            }
            .padding(.vertical, Space.s2)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }

    private func missing(_ failed: [ModuleID]) -> String {
        let names = failed.map { id in modules.first { $0.id == id }?.name ?? "A module" }
        return "\(names.formatted(.list(type: .and))) couldn't be searched, so results may be missing."
    }
}

private struct SearchRow: View {
    let hit: SearchHit
    let terms: [String]
    let onOpen: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(highlighted(hit.title, in: Typeface.callout))
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                if let detail = hit.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                if let snippet = hit.snippet, !snippet.isEmpty {
                    Text(highlighted(snippet, in: Typeface.caption))
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func highlighted(_ text: String, in font: Font) -> AttributedString {
        var attributed = AttributedString(text)
        for match in SearchText.matches(of: terms, in: text) {
            guard let range = Range(match, in: attributed) else { continue }
            attributed[range].font = font.weight(.bold)
            attributed[range].foregroundColor = Theme.current.textPrimary.color
        }
        return attributed
    }
}

private struct SearchMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
        }
        .multilineTextAlignment(.center)
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI
import TotalityUI

/// A new tab: bookmarks to go to, and what's true about searching here.
struct WebStartView: View {
    let model: WebModel
    let isPrivate: Bool

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(spacing: Space.s5) {
                if isPrivate {
                    message("Private tab", image: "eye.slash", detail: WebCopy.privateTab)
                } else if model.keepsNothing {
                    message("Search the web", image: "globe", detail: WebCopy.keepsNothing)
                } else if model.bookmarks.isEmpty {
                    message("Search the web", image: "globe", detail: "Type a search or an address above. Pages you bookmark appear here.")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s3), count: 3), spacing: Space.s5) {
                        ForEach(model.bookmarks.prefix(Self.shown)) { bookmark in
                            Button {
                                model.open(bookmark.url)
                            } label: {
                                VStack(spacing: Space.s2) {
                                    Image(systemName: "globe")
                                        .font(Typeface.title)
                                        .foregroundStyle(theme.textSecondary.color)
                                        .accessibilityHidden(true)
                                    Text(bookmark.displayTitle)
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textPrimary.color)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text(WebCopy.notEncrypted)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: Space.s8 * 10)
            .padding(Space.s5)
            .frame(maxWidth: .infinity)
        }
    }

    private static let shown = 12

    private func message(_ title: String, image: String, detail: String) -> some View {
        let theme = Theme.current
        return VStack(spacing: Space.s3) {
            Image(systemName: image)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Space.s7)
    }
}

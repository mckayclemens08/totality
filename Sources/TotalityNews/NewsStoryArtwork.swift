import SwiftUI
import TotalityUI

/// A local editorial illustration. No publisher imagery or tracking URL is requested.
struct NewsStoryArtwork: View {
    let article: NewsArticle
    let featured: Bool

    private var symbol: String {
        let source = article.source.lowercased()
        let headline = article.title.lowercased()
        if source.contains("weather") || headline.contains("advisory") || headline.contains("weather") { return "cloud.sun" }
        if source.contains("nasa") || headline.contains("space") { return "sparkles" }
        if source.contains("federal reserve") || headline.contains("economy") { return "chart.line.uptrend.xyaxis" }
        if source.contains("earthquake") { return "waveform.path" }
        if source.contains("census") { return "person.3" }
        return "globe.americas"
    }

    var body: some View {
        let theme = Theme.current
        ZStack {
            LinearGradient(colors: [theme.highlightStrong.color, theme.highlight.color],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if featured {
                Circle().fill(theme.highlight.color)
                    .frame(width: Space.s8 * 3, height: Space.s8 * 3)
                    .offset(x: Space.s8 * 2, y: Space.s6)
                Circle().fill(theme.highlightStrong.color)
                    .frame(width: Space.s8 * 2, height: Space.s8 * 2)
                    .offset(x: -Space.s8 * 2, y: -Space.s6)
            }
            Image(systemName: symbol)
                .font(featured ? Typeface.display : Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
        }
        .frame(width: featured ? nil : Space.s7, height: featured ? Space.s8 * 3 : Space.s7)
        .frame(maxWidth: featured ? .infinity : nil)
        .clipShape(.rect(cornerRadius: Radius.md))
        .accessibilityHidden(true)
    }
}

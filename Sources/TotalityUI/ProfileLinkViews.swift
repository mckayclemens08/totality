import SwiftUI
import TotalityCore
#if canImport(SafariServices) && canImport(UIKit)
import SafariServices
#endif

/// A profile's links as tappable chips under the bio. Each shows only the site's name, never the whole
/// address, and opens in Safari inside the app (a sheet), so the person never leaves Totality's screen
/// and Totality never loads the page itself. Links are checked again here, so nothing unsafe from the
/// server can show.
public struct ProfileLinkChips: View {
    let links: [URL]
    @State private var opened: OpenedLink?

    public init(stored: [String]?) {
        self.links = ProfileLinks.safe(stored)
    }

    public var body: some View {
        let theme = Theme.current
        if !links.isEmpty {
            ProfileChipFlow(spacing: Space.s2) {
                ForEach(links, id: \.absoluteString) { link in
                    Button { opened = OpenedLink(url: link) } label: {
                        HStack(spacing: Space.s1) {
                            Image(systemName: "link").font(Typeface.micro)
                            Text(ProfileLinks.domain(of: link)).font(Typeface.callout).lineLimit(1)
                        }
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, Space.s2)
                        .frame(minHeight: Space.s6)
                        .neumorphic(.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Link to \(ProfileLinks.domain(of: link))")
                    .accessibilityHint("Opens in Safari")
                }
            }
            .sheet(item: $opened) { link in
                SafariPage(url: link.url).ignoresSafeArea()
            }
        }
    }
}

private struct OpenedLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

#if canImport(SafariServices) && canImport(UIKit)
private struct SafariPage: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#else
private struct SafariPage: View {
    let url: URL
    var body: some View { Text(url.absoluteString) }
}
#endif

/// Chips that wrap onto the next line, centred or leading as the container asks.
struct ProfileChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in arrange(width: bounds.width, subviews).frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), frames)
    }
}

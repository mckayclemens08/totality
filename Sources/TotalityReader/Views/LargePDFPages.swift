import PDFKit
import SwiftUI
import TotalityUI

/// A PDF too big to hold whole, page after page (issue 124). Each page is drawn by CoreGraphics when it
/// comes near the screen and let go when it leaves, so a 1 GB scan never sits in memory. Read along marks
/// the words from that one page's text, as PDFKit finds them.
struct LargePDFPages: View {
    let pdf: LargePDF
    let follow: PDFFollow?
    let startPage: Int?
    let onPage: (Int) -> Void

    @State private var started = false

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.s3) {
                        ForEach(0..<pdf.pageCount, id: \.self) { index in
                            LargePDFPage(pdf: pdf, index: index, width: geometry.size.width, follow: follow)
                                .id(index)
                                .onAppear { onPage(index) }
                        }
                    }
                    .padding(.vertical, Space.s3)
                }
                .simultaneousGesture(DragGesture(minimumDistance: Space.s2).onChanged { _ in follow?.onScroll() })
                .onAppear {
                    guard !started else { return }
                    started = true
                    if let startPage { proxy.scrollTo(startPage, anchor: .top) }
                }
                .onChange(of: follow?.highlight?.sentence) {
                    guard let follow, follow.isFollowing, let highlight = follow.highlight,
                          let page = follow.map.pieces(of: highlight.range).first?.page
                    else { return }
                    withAnimation(Motion.standard) { proxy.scrollTo(page, anchor: .center) }
                }
            }
        }
    }
}

/// One page of a large PDF, drawn for its width, with any read-along marks over it.
private struct LargePDFPage: View {
    let pdf: LargePDF
    let index: Int
    let width: CGFloat
    let follow: PDFFollow?

    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL

    private var height: CGFloat {
        let size = pdf.size(of: index)
        return width * size.height / size.width
    }

    var body: some View {
        let theme = Theme.current
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(theme.surface.color)
            }
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Rectangle()
                    .fill(mark.color)
                    .frame(width: mark.rect.width, height: mark.rect.height)
                    .offset(x: mark.rect.minX, y: mark.rect.minY)
                    // Over the page like a highlighter, so the words still show through.
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { point in tapped(at: point) }
        .accessibilityLabel("Page \(index + 1)")
        .task(id: width) {
            let pixels = Int(width * displayScale)
            let pdf = pdf
            let index = index
            image = await Task.detached(priority: .userInitiated) { pdf.image(of: index, pixelWidth: pixels) }.value
        }
        // A page off screen lets go of its picture, so a long scroll doesn't add up.
        .onDisappear { image = nil }
    }

    private struct Mark {
        let rect: CGRect
        let color: Color
    }

    /// The sentence being read, and its word, wherever they fall on this page.
    private var marks: [Mark] {
        guard let follow, let highlight = follow.highlight else { return [] }
        let sentence = rects(follow.map, highlight.range).map { Mark(rect: $0, color: Theme.current.highlight.color) }
        let word = highlight.word.map { rects(follow.map, $0).map { Mark(rect: $0, color: Theme.current.highlightStrong.color) } } ?? []
        return sentence + word
    }

    private func rects(_ map: PDFPageMap, _ range: Range<Int>) -> [CGRect] {
        let here = map.pieces(of: range).filter { $0.page == index }
        guard !here.isEmpty, let page = pdf.textPage(index) else { return [] }
        return here.flatMap { piece -> [CGRect] in
            guard let selection = page.selection(for: piece.range) else { return [] }
            return selection.selectionsByLine().map { pdf.viewRect($0.bounds(for: page), page: index, width: width) }
        }
    }

    /// A link opens, once it passes the same check as a doc's. A tap on words starts Listen there.
    private func tapped(at point: CGPoint) {
        guard let onPage = pdf.pagePoint(point, page: index, width: width) else { return }
        if let link = pdf.links(on: index).first(where: { $0.rect.contains(onPage) }) {
            if DocText.isOpenable(link.url) { openURL(link.url) }
            return
        }
        guard let follow, let page = pdf.textPage(index) else { return }
        let character = page.characterIndex(at: onPage)
        guard character != NSNotFound, let offset = follow.map.offset(page: index, character: character) else { return }
        follow.onTap(offset)
    }
}

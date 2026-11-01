import SwiftUI
import TotalityUI

/// A document's text with Listen's place marked on it. Tapping a sentence moves Listen there. Notes and
/// other text open here while Read along is on, so nothing can be edited or selected: a tap means "go here".
struct ReadAlongView: View {
    /// Longer than this may not fit on a screen, so the page can't just centre the paragraph.
    private static let longParagraph = 800

    let item: ReaderItem
    let model: ReaderModel
    let text: String
    var headings: Set<String> = []
    /// A chapter to go to, cleared once the page has gone there.
    @Binding var chapter: String?

    @State private var page: ReadAlongPage?
    @State private var isFollowing = true

    private var highlight: ReadAlongHighlight? {
        guard let page, let current = model.listen.current, current.id == item.id,
              current.script.fingerprint == page.script.fingerprint
        else { return nil }
        return page.script.highlight(sentence: model.listen.sentence, spoken: model.listen.spoken)
    }

    var body: some View {
        Group {
            if let page, !page.script.sentences.isEmpty {
                pageView(page)
            } else if page != nil {
                ReaderMessage(
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    title: "Nothing to read along with",
                    detail: "There's nothing to read aloud here yet."
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: text) {
            let text = text
            let headings = headings
            // Cutting a long book into sentences takes seconds, so it stays off the main thread.
            page = await Task.detached { ReadAlongPage(text: text, headings: headings) }.value
        }
    }

    private func pageView(_ page: ReadAlongPage) -> some View {
        let highlight = highlight
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s3) {
                    ForEach(page.paragraphs) { paragraph in
                        ReadAlongParagraph(page: page, paragraph: paragraph, highlight: page.touches(paragraph, highlight) ? highlight : nil)
                            .id(paragraph.id)
                    }
                }
                .frame(maxWidth: Space.s8 * 10, alignment: .leading)
                .padding(Space.s4)
                .frame(maxWidth: .infinity)
                .background(ScrollWatcher { isFollowing = false })
            }
            .environment(\.openURL, OpenURLAction { url in
                if let sentence = ReadAlongLink.sentence(in: url) { go(to: sentence, on: page) }
                return .handled
            })
            .overlay(alignment: .bottom) {
                if highlight != nil, !isFollowing {
                    BackToReading { isFollowing = true }
                }
            }
            .task(id: FollowPlace(sentence: highlight?.sentence, isFollowing: isFollowing)) {
                follow(highlight, on: page, with: reader)
            }
            .onChange(of: chapter) {
                guard let title = chapter, let found = page.paragraph(titled: title) else { return }
                isFollowing = false
                reader.scrollTo(found.id, anchor: .top)
                chapter = nil
            }
        }
    }

    private struct FollowPlace: Equatable {
        let sentence: Int?
        let isFollowing: Bool
    }

    private func go(to sentence: Int, on page: ReadAlongPage) {
        isFollowing = true
        Task { await model.listen(to: item.id, from: page.script.sentences[sentence].offset, on: page.script) }
    }

    private func follow(_ highlight: ReadAlongHighlight?, on page: ReadAlongPage, with reader: ScrollViewProxy) {
        guard isFollowing, let highlight, let paragraph = page.paragraph(holding: highlight.range.lowerBound) else { return }
        var anchor = UnitPoint.center
        if paragraph.length > Self.longParagraph {
            // Lining up the same point of the paragraph and the screen keeps that point in view at any length.
            let middle = Double(highlight.range.lowerBound - paragraph.offset + highlight.range.count / 2)
            anchor = UnitPoint(x: 0, y: min(max(middle / Double(paragraph.length), 0), 1))
        }
        withAnimation(Motion.standard) { reader.scrollTo(paragraph.id, anchor: anchor) }
    }
}

private struct ReadAlongParagraph: View {
    let page: ReadAlongPage
    let paragraph: ReadAlongPage.Paragraph
    let highlight: ReadAlongHighlight?

    var body: some View {
        let theme = Theme.current
        Text(attributed)
            .font(paragraph.isHeading ? Typeface.title : Typeface.body)
            .foregroundStyle(theme.textPrimary.color)
            // A link would otherwise take the accent colour, and every sentence is a link.
            .tint(theme.textPrimary.color)
            .lineSpacing(Space.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(paragraph.isHeading ? .isHeader : [])
            // On iOS 17 the sentence links never receive a tap in this scroll view without a gesture here.
            .simultaneousGesture(TapGesture())
    }

    private var attributed: AttributedString {
        let theme = Theme.current
        var result = AttributedString()
        for piece in page.pieces(of: paragraph, highlight: highlight) {
            var part = AttributedString(piece.text)
            if let sentence = piece.sentence { part.link = ReadAlongLink.url(forSentence: sentence) }
            switch piece.mark {
            case .none: break
            case .sentence: part.backgroundColor = theme.highlight.color
            case .word: part.backgroundColor = theme.highlightStrong.color
            }
            result += part
        }
        return result
    }
}

/// Shown once the person has scrolled away from what Listen is reading.
struct BackToReading: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Back to reading", systemImage: "arrow.down.to.line")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textPrimary.color)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .neumorphic(.raised, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, Space.s3)
    }
}

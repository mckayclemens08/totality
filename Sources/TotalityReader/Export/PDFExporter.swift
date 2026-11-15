import CoreGraphics
import CoreText
import Foundation
import TotalityUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Lays a doc out as PDF pages with CoreText, the same on iPhone and Mac. The words stay real text, so
/// the PDF can be searched, copied and read aloud. The Doc layout uses the writing page's type tokens;
/// the essay, manuscript and thesis layouts follow their style guides.
enum PDFExporter {
    static func pdf(
        _ document: ExportDocument, template: ExportTemplate, paper: PaperSize,
        images: [String: ExportImage] = [:], serif: Bool = false
    ) -> Data? {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: paper.size.width, height: paper.size.height)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: document.meta.title,
            kCGPDFContextAuthor: document.meta.author,
            kCGPDFContextCreator: "Totality",
        ]
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)
        else { return nil }
        var layout = PDFLayout(
            context: context, page: box, template: template, style: PDFStyle(template: template, serif: serif),
            meta: document.meta, images: images
        )
        layout.render(document)
        context.closePDF()
        return output as Data
    }
}

/// Fonts, colours and spacing for one template.
struct PDFStyle {
    let template: ExportTemplate
    let size: CGFloat
    let lineHeight: CGFloat
    let regular: CTFont
    let text: CGColor
    let secondary: CGColor
    let accent: CGColor

    init(template: ExportTemplate, serif: Bool) {
        self.template = template
        if template == .doc {
            size = WritingType.printSize
            lineHeight = WritingType.lineHeight
            regular = Self.systemFont(size: WritingType.printSize, serif: serif)
        } else {
            size = template.fontSize
            lineHeight = template.lineSpacing
            regular = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, template.fontSize, nil)
        }
        let theme = Theme.current
        text = Self.color(theme.textPrimary.hex)
        secondary = Self.color(theme.textSecondary.hex)
        accent = Self.color(theme.accent.hex)
    }

    /// The face the writing page shows: the system's, or its serif when the person chose serif.
    private static func systemFont(size: CGFloat, serif: Bool) -> CTFont {
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size)
        let descriptor = serif ? base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor : base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size) as CTFont
        #else
        let base = NSFont.systemFont(ofSize: size)
        let descriptor = serif ? base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor : base.fontDescriptor
        return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
        #endif
    }

    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }

    func font(size: CGFloat? = nil, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> CTFont {
        let points = size ?? self.size
        if mono { return CTFontCreateWithName("Menlo-Regular" as CFString, points * 0.85, nil) }
        let sized = CTFontCreateCopyWithAttributes(regular, points, nil, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return sized }
        return CTFontCreateCopyWithSymbolicTraits(sized, points, nil, traits, traits) ?? sized
    }

    /// Heading sizes: the page's scale in the Doc layout, the body's size in a style guide's.
    func headingSize(_ level: Int) -> CGFloat {
        template == .doc ? size * WritingType.headingScales[min(5, max(0, level - 1))] : size
    }

    func headingSpace(_ level: Int) -> CGFloat {
        template == .doc ? WritingType.headingSpace[min(5, max(0, level - 1))] + Space.s2 : 0
    }

    /// The space between paragraphs: none where the first line is indented instead.
    var paragraphGap: CGFloat {
        template.indentsParagraphs ? 0 : Space.s2
    }
}

/// Keys this layout reads back after drawing, for what CoreText doesn't draw itself.
private enum Mark {
    static let link = NSAttributedString.Key("TotalityLink")
    static let strike = NSAttributedString.Key("TotalityStrike")
    static let underline = NSAttributedString.Key("TotalityUnderline")
}

private struct PDFLayout {
    let context: CGContext
    let page: CGRect
    let template: ExportTemplate
    let style: PDFStyle
    let meta: ExportDocument.Meta
    let images: [String: ExportImage]

    /// Where text goes on every page, in PDF space (origin at the bottom left).
    private let content: CGRect
    private var pageCount = 0
    private var isPageOpen = false
    /// How far down the current page the next block starts, from the top of the text area.
    private var used: CGFloat = 0
    private var isFirstBlock = true

    init(context: CGContext, page: CGRect, template: ExportTemplate, style: PDFStyle, meta: ExportDocument.Meta, images: [String: ExportImage]) {
        self.context = context
        self.page = page
        self.template = template
        self.style = style
        self.meta = meta
        self.images = images
        let margins = template.margins
        content = CGRect(
            x: margins.left, y: margins.bottom,
            width: page.width - margins.left - margins.right, height: page.height - margins.top - margins.bottom
        )
    }

    private var remaining: CGFloat { content.height - used }

    // MARK: Pages

    private mutating func newPage() {
        if isPageOpen { endPage() }
        context.beginPDFPage(nil)
        isPageOpen = true
        pageCount += 1
        used = 0
    }

    private mutating func endPage() {
        defer {
            context.endPDFPage()
            isPageOpen = false
        }
        // A thesis's title page counts, but shows no number.
        guard !(template.hasTitlePage && pageCount == 1) else { return }
        let number = String(pageCount)
        let font = style.font(size: template == .doc ? style.size * 0.9 : style.size)
        switch template.pageNumber {
        case .header:
            let head = template.runningHead(meta)
            let words = head.isEmpty ? number : "\(head) \(number)"
            let line = CTLineCreateWithAttributedString(attributed(words, font: font, color: style.text))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            draw(line, at: CGPoint(x: page.width - template.margins.right - width, y: page.height - 36 - style.size * 0.8))
        case .footer:
            let line = CTLineCreateWithAttributedString(attributed(number, font: font, color: style.secondary))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            draw(line, at: CGPoint(x: content.minX + (content.width - width) / 2, y: 36))
        }
    }

    private func draw(_ line: CTLine, at point: CGPoint) {
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private func attributed(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    // MARK: The whole doc

    mutating func render(_ document: ExportDocument) {
        newPage()
        opening()
        for block in document.blocks { place(block, indent: 0) }
        if !document.notes.isEmpty {
            heading("Notes", level: 1, breakBefore: template != .doc)
            // Notes come at the end as endnotes: CoreText has no footnote area to flow them into.
            for note in document.notes {
                let runs = note.blocks.flatMap { block -> [ExportDocument.Run] in
                    if case .paragraph(let runs) = block { return runs }
                    return []
                }
                let number = ExportDocument.Run("\(note.number). ")
                text([number] + runs.filter { $0.note == nil }, paragraph: Paragraph(first: 0, head: 0, spacing: 1.15, gap: Space.s1), size: style.size * 0.9)
            }
        }
        if !document.bibliography.isEmpty {
            let title = document.bibliographyHeading.isEmpty ? "References" : document.bibliographyHeading
            heading(title, level: 1, breakBefore: template != .doc, centred: template != .doc)
            for entry in document.bibliography {
                text([ExportDocument.Run(entry)], paragraph: Paragraph(first: 0, head: 36, spacing: style.lineHeight, gap: style.paragraphGap))
            }
        }
        endPage()
    }

    /// The title, and the lines a template puts with it.
    private mutating func opening() {
        let centred = Paragraph(first: 0, head: 0, spacing: style.lineHeight, gap: 0, alignment: .center)
        let plain = Paragraph(first: 0, head: 0, spacing: style.lineHeight, gap: 0)
        func line(_ words: String, _ paragraph: Paragraph, bold: Bool = false, size: CGFloat? = nil) {
            guard !words.isEmpty else { return }
            var run = ExportDocument.Run(words)
            run.bold = bold
            text([run], paragraph: paragraph, size: size)
        }
        switch template {
        case .doc:
            line(meta.title, plain, bold: true, size: style.size * WritingType.headingScales[0] * 1.2)
            used += Space.s4
        case .essay:
            for words in [meta.author, meta.instructor, meta.course, meta.date] { line(words, plain) }
            line(meta.title, centred)
        case .manuscript:
            line(meta.author, plain)
            used = max(used, content.height / 3)
            line(meta.title, centred)
            if !meta.author.isEmpty { line("by \(meta.author)", centred) }
            used += style.size * style.lineHeight
        case .thesis:
            used = content.height / 4
            line(meta.title, centred, bold: true)
            line(meta.subtitle, centred)
            used += style.size * style.lineHeight * 2
            line(meta.author, centred)
            line(meta.institute, centred)
            line(meta.date, centred)
            newPage()
        }
        isFirstBlock = true
    }

    // MARK: Blocks

    private mutating func place(_ block: ExportDocument.Block, indent: CGFloat) {
        defer { isFirstBlock = false }
        let body = Paragraph(
            first: template.indentsParagraphs ? 36 : 0, head: indent, spacing: style.lineHeight, gap: style.paragraphGap
        )
        switch block {
        case .heading(let level, let runs):
            let breakBefore = template.chaptersStartPages && level == 1 && !isFirstBlock && used > 0
            heading(runs, level: level, breakBefore: breakBefore, centred: template != .doc && level == 1)
        case .paragraph(let runs):
            text(runs, paragraph: indent > 0 ? Paragraph(first: 0, head: indent, spacing: style.lineHeight, gap: style.paragraphGap) : body)
        case .quote(let blocks):
            for inner in blocks {
                if case .paragraph(let runs) = inner {
                    text(runs, paragraph: Paragraph(first: 0, head: indent + 36, tail: 36, spacing: style.lineHeight, gap: style.paragraphGap))
                } else {
                    place(inner, indent: indent + 36)
                }
            }
        case .list(let ordered, let start, let items):
            for (index, item) in items.enumerated() {
                let marker: String = if let task = item.task { task ? "☒" : "☐" } else if ordered { "\(start + index)." } else { indent > 0 ? "◦" : "•" }
                var first = true
                for inner in item.blocks {
                    if case .paragraph(let runs) = inner {
                        let lead = first ? [ExportDocument.Run("\(marker)\t")] : []
                        let paragraph = Paragraph(
                            first: first ? indent + 18 : indent + 36, head: indent + 36, spacing: style.lineHeight,
                            gap: style.paragraphGap, tab: indent + 36
                        )
                        text(lead + runs, paragraph: paragraph)
                        first = false
                    } else {
                        place(inner, indent: indent + 36)
                    }
                }
            }
        case .code(let code):
            var run = ExportDocument.Run(code)
            run.code = true
            text([run], paragraph: Paragraph(first: 0, head: indent + 18, spacing: 1.2, gap: Space.s2))
        case .table(let header, let rows):
            table(header: header, rows: rows)
        case .figure(let alt, let number, let source):
            if let image = images[source] { picture(image) }
            let caption = ExportDocument.caption(alt: alt, number: number)
            if !caption.isEmpty {
                var run = ExportDocument.Run(caption)
                run.italic = true
                text([run], paragraph: Paragraph(first: 0, head: 0, spacing: style.lineHeight, gap: Space.s3, alignment: images[source] == nil ? .natural : .center))
            }
        case .rule:
            text([ExportDocument.Run(template == .manuscript ? "#" : "* * *")], paragraph: Paragraph(first: 0, head: 0, spacing: style.lineHeight, gap: style.paragraphGap, alignment: .center))
        case .pageBreak:
            if used > 0 { newPage() }
        }
    }

    private mutating func heading(_ words: String, level: Int, breakBefore: Bool, centred: Bool = false) {
        heading([ExportDocument.Run(words)], level: level, breakBefore: breakBefore, centred: centred)
    }

    private mutating func heading(_ runs: [ExportDocument.Run], level: Int, breakBefore: Bool, centred: Bool = false) {
        if breakBefore { newPage() }
        let size = style.headingSize(level)
        let styled = runs.map { run -> ExportDocument.Run in
            var copy = run
            copy.bold = true
            if template != .doc && level >= 3 { copy.italic = true }
            return copy
        }
        let spacing = template == .doc ? WritingType.headingLineHeight : style.lineHeight
        let before = used > 0 ? style.headingSpace(level) : 0
        let paragraph = Paragraph(first: 0, head: 0, spacing: spacing, gap: template == .doc ? Space.s2 : 0, alignment: centred ? .center : .natural)
        let string = attributed(styled, paragraph: paragraph, size: size)
        // A heading never ends a page: it moves on with at least two lines of what follows.
        let height = measure(string) + before + style.size * style.lineHeight * 2
        if used > 0, height > remaining { newPage() } else { used += before }
        flow(string, gap: paragraph.gap)
    }

    private mutating func text(_ runs: [ExportDocument.Run], paragraph: Paragraph, size: CGFloat? = nil) {
        guard !runs.isEmpty else { return }
        flow(attributed(runs, paragraph: paragraph, size: size), gap: paragraph.gap)
    }

    /// Draws text from where the page is up to, onto as many pages as it takes.
    private mutating func flow(_ string: NSAttributedString, gap: CGFloat) {
        let setter = CTFramesetterCreateWithAttributedString(string)
        var start = 0
        while start < string.length {
            if !isPageOpen { newPage() }
            let rect = CGRect(x: content.minX, y: content.minY, width: content.width, height: max(0, remaining))
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: rect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                // Nothing fits on an empty page: a line taller than the page. Leave it out rather than loop.
                if used == 0 { return }
                newPage()
                continue
            }
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            decorate(frame)
            used += height(of: frame, in: rect)
            start += visible.length
            if start < string.length { newPage() }
        }
        used = min(content.height, used + gap)
    }

    /// How much of the rect a frame's lines took, from its top.
    private func height(of frame: CTFrame, in rect: CGRect) -> CGFloat {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard let last = lines.last else { return 0 }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(last, nil, &descent, nil)
        return rect.height - (origins[lines.count - 1].y - descent)
    }

    private func measure(_ string: NSAttributedString) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil, CGSize(width: content.width, height: .greatestFiniteMagnitude), nil
        )
        return ceil(size.height)
    }

    /// Strike-throughs, underlines and links, which CoreText leaves to whoever draws.
    private func decorate(_ frame: CTFrame) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let box = CTFrameGetPath(frame).boundingBox
        for (index, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                let link = attributes[Mark.link] as? URL
                let strike = attributes[Mark.strike] != nil
                let underline = attributes[Mark.underline] != nil
                guard link != nil || strike || underline else { continue }
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
                let range = CTRunGetStringRange(run)
                let x = box.minX + origins[index].x + CTLineGetOffsetForStringIndex(line, range.location, nil)
                let baseline = box.minY + origins[index].y
                context.setStrokeColor(link != nil ? style.accent : style.text)
                context.setLineWidth(max(0.5, style.size / 20))
                if strike || underline {
                    let y = strike ? baseline + ascent * 0.3 : baseline - max(1, descent * 0.4)
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x + width, y: y))
                    context.strokePath()
                }
                if let link {
                    context.setURL(link as CFURL, for: CGRect(x: x, y: baseline - descent, width: width, height: ascent + descent))
                }
            }
        }
    }

    // MARK: Images and tables

    private mutating func picture(_ image: ExportImage) {
        let size = image.size(fitting: CGSize(width: content.width, height: content.height * 0.6))
        if used > 0, size.height + style.size * style.lineHeight > remaining { newPage() }
        let top = content.maxY - used
        let rect = CGRect(x: content.minX + (content.width - size.width) / 2, y: top - size.height, width: size.width, height: size.height)
        context.draw(image.image, in: rect)
        used += size.height + Space.s2
    }

    private mutating func table(header: [[ExportDocument.Run]], rows: [[[ExportDocument.Run]]]) {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return }
        let width = content.width / CGFloat(columns)
        let padding: CGFloat = 4
        let size = style.size * 0.9
        let cellStyle = Paragraph(first: 0, head: 0, spacing: 1.15, gap: 0)
        let all = [header.map { $0.map { run -> ExportDocument.Run in var bold = run; bold.bold = true; return bold } }] + rows
        used += Space.s2
        for row in all {
            let cells = (0..<columns).map { index in attributed(index < row.count ? row[index] : [], paragraph: cellStyle, size: size) }
            let heights = cells.map { cell -> CGFloat in
                let setter = CTFramesetterCreateWithAttributedString(cell)
                return ceil(CTFramesetterSuggestFrameSizeWithConstraints(
                    setter, CFRange(location: 0, length: 0), nil, CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude), nil
                ).height)
            }
            let rowHeight = min(content.height, (heights.max() ?? 0) + padding * 2)
            if rowHeight > remaining { newPage() }
            let top = content.maxY - used
            for (index, cell) in cells.enumerated() {
                let rect = CGRect(x: content.minX + CGFloat(index) * width, y: top - rowHeight, width: width, height: rowHeight)
                context.setStrokeColor(style.secondary)
                context.setLineWidth(0.5)
                context.stroke(rect)
                let inner = rect.insetBy(dx: padding, dy: padding)
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(cell), CFRange(location: 0, length: 0), CGPath(rect: inner, transform: nil), nil)
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                decorate(frame)
            }
            used += rowHeight
        }
        used += Space.s3
    }

    // MARK: Attributed text

    private func attributed(_ runs: [ExportDocument.Run], paragraph: Paragraph, size: CGFloat? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = size ?? style.size
        for run in runs {
            if run.lineBreak {
                result.append(NSAttributedString(string: "\u{2028}"))
                continue
            }
            var text = run.text
            var points = base
            var offset: CGFloat = 0
            if let note = run.note {
                text = String(note)
                points = base * 0.65
                offset = base * 0.35
            } else if run.superscript || run.subscripted {
                points = base * 0.7
                offset = run.superscript ? base * 0.33 : -base * 0.15
            }
            guard !text.isEmpty else { continue }
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): style.font(size: points, bold: run.bold, italic: run.italic, mono: run.code),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): run.link != nil ? style.accent : style.text,
            ]
            if offset != 0 { attributes[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = offset }
            if run.strike { attributes[Mark.strike] = true }
            if let link = run.link {
                attributes[Mark.link] = link
                attributes[Mark.underline] = true
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        result.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: paragraph.style(size: base), range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// How one paragraph sits: its indents, line spacing and the gap after it.
private struct Paragraph {
    var first: CGFloat
    var head: CGFloat
    var tail: CGFloat = 0
    var spacing: CGFloat
    var gap: CGFloat
    var alignment: CTTextAlignment = .natural
    /// Where a list's text starts after its marker.
    var tab: CGFloat? = nil

    init(first: CGFloat, head: CGFloat, tail: CGFloat = 0, spacing: CGFloat, gap: CGFloat, alignment: CTTextAlignment = .natural, tab: CGFloat? = nil) {
        self.first = first
        self.head = head
        self.tail = tail
        self.spacing = spacing
        self.gap = gap
        self.alignment = alignment
        self.tab = tab
    }

    func style(size: CGFloat) -> CTParagraphStyle {
        var alignment = self.alignment
        var first = self.first
        var head = self.head
        // CoreText counts a negative tail indent from the right edge.
        var tail = -self.tail
        var multiple = spacing
        let tabs = (tab.map { [CTTextTabCreate(.natural, Double($0), nil)] } ?? []) as CFArray
        var tabArray: CFArray = tabs
        return withUnsafeBytes(of: &alignment) { alignmentBytes in
            withUnsafeBytes(of: &first) { firstBytes in
                withUnsafeBytes(of: &head) { headBytes in
                    withUnsafeBytes(of: &tail) { tailBytes in
                        withUnsafeBytes(of: &multiple) { multipleBytes in
                            withUnsafeBytes(of: &tabArray) { tabBytes in
                                let settings = [
                                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!),
                                    CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: firstBytes.baseAddress!),
                                    CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: headBytes.baseAddress!),
                                    CTParagraphStyleSetting(spec: .tailIndent, valueSize: MemoryLayout<CGFloat>.size, value: tailBytes.baseAddress!),
                                    CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: multipleBytes.baseAddress!),
                                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tabBytes.baseAddress!),
                                ]
                                return CTParagraphStyleCreate(settings, settings.count)
                            }
                        }
                    }
                }
            }
        }
    }
}

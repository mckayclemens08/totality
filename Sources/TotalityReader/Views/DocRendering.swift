import SwiftUI
import TotalityUI
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
#else
import AppKit
typealias PlatformFont = NSFont
#endif

/// Turns a doc into what a text view shows and back. Fonts and colours only exist on screen, and the
/// custom keys below are what actually count. A list's bullet or number is real text in the view,
/// marked so it never reaches the doc.
@MainActor
enum DocRendering {
    static let styleKey = NSAttributedString.Key("totality.doc.style")
    static let boldKey = NSAttributedString.Key("totality.doc.bold")
    static let italicKey = NSAttributedString.Key("totality.doc.italic")
    static let markerKey = NSAttributedString.Key("totality.doc.marker")

    static func font(for style: DocText.Style, bold: Bool, italic: Bool) -> PlatformFont {
        let base: PlatformFont
        switch style {
        case .heading1: base = .preferredFont(forTextStyle: .title1)
        case .heading2: base = .preferredFont(forTextStyle: .title2)
        default: base = .preferredFont(forTextStyle: .body)
        }
        let heavy = bold || style == .heading1 || style == .heading2
        #if canImport(UIKit)
        var traits = base.fontDescriptor.symbolicTraits
        if heavy { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: 0)
        #else
        var traits = base.fontDescriptor.symbolicTraits
        if heavy { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 0) ?? base
        #endif
    }

    static func paragraphStyle(for style: DocText.Style) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = Space.s2
        if style == .heading1 || style == .heading2 { paragraph.paragraphSpacingBefore = Space.s3 }
        if style.isList {
            paragraph.headIndent = Space.s5
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: Space.s5)]
        }
        return paragraph
    }

    static func attributes(style: DocText.Style, bold: Bool = false, italic: Bool = false, link: URL? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style, bold: bold, italic: italic),
            .foregroundColor: Theme.current.textPrimary.platformColor,
            .paragraphStyle: paragraphStyle(for: style),
            styleKey: style.rawValue,
        ]
        if bold { attributes[boldKey] = true }
        if italic { attributes[italicKey] = true }
        if let link { attributes[.link] = link }
        return attributes
    }

    static func attributed(_ doc: DocText) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var number = 0
        for (index, paragraph) in doc.paragraphs.enumerated() {
            number = paragraph.style == .numbered ? number + 1 : 0
            if paragraph.style.isList {
                let marker = paragraph.style == .bullet ? "•\t" : "\(number).\t"
                var attributes = attributes(style: paragraph.style)
                attributes[markerKey] = true
                result.append(NSAttributedString(string: marker, attributes: attributes))
            }
            for run in paragraph.runs {
                result.append(NSAttributedString(
                    string: run.text, attributes: attributes(style: paragraph.style, bold: run.bold, italic: run.italic, link: run.link)
                ))
            }
            if index < doc.paragraphs.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attributes(style: paragraph.style)))
            }
        }
        return result
    }

    /// Each paragraph's bounds, in UTF-16, without its line ending.
    static func paragraphRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        while true {
            let found = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
            guard found.location != NSNotFound else { break }
            ranges.append(NSRange(location: start, length: found.location - start))
            start = found.location + 1
        }
        ranges.append(NSRange(location: start, length: text.length - start))
        return ranges
    }

    static func doc(from text: NSAttributedString) -> DocText {
        let string = text.string as NSString
        let paragraphs = paragraphRanges(in: string).map { range -> DocText.Paragraph in
            var style = DocText.Style.body
            var runs: [DocText.Run] = []
            if range.location < text.length {
                // A paragraph's own line ending carries its style, even when it has no words yet.
                let raw = text.attribute(styleKey, at: range.location, effectiveRange: nil) as? String
                style = raw.flatMap(DocText.Style.init(rawValue:)) ?? .body
            }
            text.enumerateAttributes(in: range, options: []) { attributes, part, _ in
                guard attributes[markerKey] == nil else { return }
                runs.append(DocText.Run(
                    string.substring(with: part),
                    bold: attributes[boldKey] != nil, italic: attributes[italicKey] != nil,
                    link: attributes[.link] as? URL
                ))
            }
            return DocText.Paragraph(style, runs: runs)
        }
        return DocText(paragraphs: paragraphs)
    }
}

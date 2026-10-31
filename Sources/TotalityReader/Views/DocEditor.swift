import SwiftUI
import TotalityUI
#if canImport(UIKit)
import UIKit
typealias PlatformTextView = UITextView
#else
import AppKit
typealias PlatformTextView = NSTextView
#endif

/// Runs one doc's text view. Typing goes straight into the view. Anything that changes a paragraph's
/// shape goes through the doc and redraws, so lists and numbers can't drift from what's stored.
@MainActor
@Observable
final class DocEditorController: NSObject {
    /// Goes up with every change, so the screen knows there's something to save.
    private(set) var revision = 0
    private(set) var activeStyle = DocText.Style.body
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var currentLink: URL?

    @ObservationIgnored private weak var textView: PlatformTextView?
    @ObservationIgnored private var loaded = DocText()
    @ObservationIgnored private var needsRedraw = false
    @ObservationIgnored private var isRedrawing = false
    /// An empty last paragraph has no text to carry its style, so it's kept here.
    @ObservationIgnored private var endingStyle = DocText.Style.body

    var document: DocText {
        guard let storage else { return loaded }
        var doc = DocRendering.doc(from: storage)
        if let last = doc.paragraphs.indices.last, doc.paragraphs[last].text.isEmpty, doc.paragraphs[last].style == .body {
            doc.paragraphs[last].style = endingStyle
        }
        return doc
    }

    func load(_ doc: DocText) {
        loaded = doc
        redraw(doc, caret: nil)
        revision += 1
    }

    func attach(_ view: PlatformTextView) {
        textView = view
        redraw(loaded, caret: nil)
    }

    // MARK: The two platforms' differences

    private var storage: NSTextStorage? {
        #if canImport(UIKit)
        textView?.textStorage
        #else
        textView?.textStorage
        #endif
    }

    private var selection: NSRange {
        get {
            #if canImport(UIKit)
            textView?.selectedRange ?? NSRange()
            #else
            textView?.selectedRange() ?? NSRange()
            #endif
        }
        set {
            #if canImport(UIKit)
            textView?.selectedRange = newValue
            #else
            textView?.setSelectedRange(newValue)
            #endif
        }
    }

    private var typing: [NSAttributedString.Key: Any] {
        get { textView?.typingAttributes ?? [:] }
        set { textView?.typingAttributes = newValue }
    }

    // MARK: Where the caret is, in doc terms

    private struct Position {
        var paragraph: Int
        var offset: Int
    }

    private func markerLength(in range: NSRange, of text: NSAttributedString) -> Int {
        guard range.length > 0, text.attribute(DocRendering.markerKey, at: range.location, effectiveRange: nil) != nil else { return 0 }
        var marker = NSRange()
        _ = text.attribute(DocRendering.markerKey, at: range.location, longestEffectiveRange: &marker, in: range)
        return marker.length
    }

    private func position(of location: Int) -> Position {
        guard let storage else { return Position(paragraph: 0, offset: 0) }
        let ranges = DocRendering.paragraphRanges(in: storage.string as NSString)
        let index = ranges.lastIndex { $0.location <= location } ?? 0
        let marker = markerLength(in: ranges[index], of: storage)
        return Position(paragraph: index, offset: max(0, location - ranges[index].location - marker))
    }

    private func location(of position: Position) -> Int {
        guard let storage else { return 0 }
        let ranges = DocRendering.paragraphRanges(in: storage.string as NSString)
        let range = ranges[min(position.paragraph, ranges.count - 1)]
        let marker = markerLength(in: range, of: storage)
        return min(range.location + marker + position.offset, NSMaxRange(range))
    }

    private func redraw(_ doc: DocText, caret: Position?) {
        guard let storage else { return }
        isRedrawing = true
        endingStyle = doc.paragraphs.last?.style ?? .body
        storage.setAttributedString(DocRendering.attributed(doc))
        // A redraw isn't one step the system can undo, so older steps can't be trusted past it.
        textView?.undoManager?.removeAllActions()
        if let caret { selection = NSRange(location: location(of: caret), length: 0) }
        isRedrawing = false
        refreshTyping()
        refreshActive()
    }

    private func refreshTyping() {
        guard let storage else { return }
        let caret = position(of: selection.location)
        let doc = document
        let style = doc.paragraphs[min(caret.paragraph, doc.paragraphs.count - 1)].style
        var attributes = DocRendering.attributes(style: style)
        if selection.location > 0, selection.location <= storage.length {
            let before = storage.attributes(at: selection.location - 1, effectiveRange: nil)
            if before[DocRendering.markerKey] == nil, !(storage.string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)).contains("\n") {
                attributes = DocRendering.attributes(
                    style: style, bold: before[DocRendering.boldKey] != nil, italic: before[DocRendering.italicKey] != nil
                )
            }
        }
        typing = attributes
    }

    private func refreshActive() {
        guard let storage else { return }
        let range = selection
        let paragraph = position(of: range.location).paragraph
        let doc = document
        activeStyle = doc.paragraphs[min(paragraph, doc.paragraphs.count - 1)].style
        if range.length > 0 {
            isBold = isEverywhere(DocRendering.boldKey, in: range)
            isItalic = isEverywhere(DocRendering.italicKey, in: range)
            currentLink = storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        } else {
            isBold = typing[DocRendering.boldKey] != nil
            isItalic = typing[DocRendering.italicKey] != nil
            let inside = range.location > 0 && range.location <= storage.length
            currentLink = inside ? storage.attribute(.link, at: range.location - 1, effectiveRange: nil) as? URL : nil
        }
    }

    private func isEverywhere(_ key: NSAttributedString.Key, in range: NSRange) -> Bool {
        guard let storage else { return false }
        var found = true
        storage.enumerateAttribute(key, in: range, options: []) { value, _, stop in
            if value == nil {
                found = false
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: Commands

    func toggleBold() {
        toggle(DocRendering.boldKey, isOn: isBold)
    }

    func toggleItalic() {
        toggle(DocRendering.italicKey, isOn: isItalic)
    }

    private func toggle(_ key: NSAttributedString.Key, isOn: Bool) {
        let range = selection
        if range.length == 0 {
            var attributes = typing
            attributes[key] = isOn ? nil : true
            attributes[.font] = DocRendering.font(
                for: activeStyle, bold: attributes[DocRendering.boldKey] != nil, italic: attributes[DocRendering.italicKey] != nil
            )
            typing = attributes
            refreshActive()
            return
        }
        guard let storage else { return }
        storage.beginEditing()
        if isOn { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: true, range: range) }
        restyle(range)
        storage.endEditing()
        changed()
    }

    private func restyle(_ range: NSRange) {
        guard let storage else { return }
        storage.enumerateAttributes(in: range, options: []) { attributes, part, _ in
            let style = (attributes[DocRendering.styleKey] as? String).flatMap(DocText.Style.init(rawValue:)) ?? .body
            let font = DocRendering.font(for: style, bold: attributes[DocRendering.boldKey] != nil, italic: attributes[DocRendering.italicKey] != nil)
            storage.addAttribute(.font, value: font, range: part)
        }
    }

    /// Applies to every paragraph the selection touches. Choosing the style it already has clears it.
    func setStyle(_ style: DocText.Style) {
        guard storage != nil else { return }
        var doc = document
        let first = position(of: selection.location)
        let last = position(of: NSMaxRange(selection))
        let next = activeStyle == style ? DocText.Style.body : style
        for index in first.paragraph...max(first.paragraph, last.paragraph) where index < doc.paragraphs.count {
            doc.paragraphs[index].style = next
        }
        redraw(doc, caret: first)
        changed()
    }

    /// An empty address removes the link. An address with no scheme is assumed to be a website.
    func setLink(address: String) {
        guard let storage, selection.length > 0 || currentLink != nil else { return }
        var range = selection
        if range.length == 0 {
            _ = storage.attribute(.link, at: range.location - 1, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            storage.removeAttribute(.link, range: range)
        } else if let url = URL(string: trimmed.contains(":") ? trimmed : "https://\(trimmed)"), DocText.isOpenable(url) {
            storage.addAttribute(.link, value: url, range: range)
        } else {
            return
        }
        changed()
    }

    // MARK: From the text view

    /// Return and Backspace do different things inside lists. Returns false when it's handled here.
    fileprivate func shouldChange(_ range: NSRange, to text: String) -> Bool {
        guard !isRedrawing, storage != nil else { return true }
        let doc = document
        let caret = position(of: range.location)
        let style = doc.paragraphs[min(caret.paragraph, doc.paragraphs.count - 1)].style
        if text == "\n", range.length == 0 {
            if style.isList, doc.paragraphs[caret.paragraph].text.isEmpty {
                setStyle(style)
                return false
            }
            if style != .body {
                var next = doc
                // At the very start of a heading, Return pushes the heading down rather than demoting it.
                if caret.offset == 0, !style.isList {
                    next.paragraphs.insert(DocText.Paragraph(), at: caret.paragraph)
                    redraw(next, caret: Position(paragraph: caret.paragraph + 1, offset: 0))
                    changed()
                    return false
                }
                next.split(paragraph: caret.paragraph, at: caret.offset, into: style.isList ? style : .body)
                redraw(next, caret: Position(paragraph: caret.paragraph + 1, offset: 0))
                changed()
                return false
            }
        }
        if text.isEmpty, range.length == 1, style.isList, caret.offset == 0,
           position(of: NSMaxRange(range)).offset == 0, position(of: NSMaxRange(range)).paragraph == caret.paragraph {
            setStyle(style)
            return false
        }
        let replaced = (storage?.string as NSString?)?.substring(with: range) ?? ""
        if text.contains("\n") || replaced.contains("\n") { needsRedraw = true }
        return true
    }

    fileprivate func textDidChange() {
        guard !isRedrawing else { return }
        if needsRedraw {
            needsRedraw = false
            let caret = position(of: selection.location)
            redraw(document, caret: caret)
        }
        changed()
    }

    /// A caret can't sit inside a bullet.
    fileprivate func selectionDidChange() {
        guard !isRedrawing, let storage else { return }
        if selection.length == 0 {
            let ranges = DocRendering.paragraphRanges(in: storage.string as NSString)
            let index = ranges.lastIndex { $0.location <= selection.location } ?? 0
            let marker = markerLength(in: ranges[index], of: storage)
            if selection.location < ranges[index].location + marker {
                selection = NSRange(location: ranges[index].location + marker, length: 0)
            }
        }
        refreshTyping()
        refreshActive()
    }

    private func changed() {
        revision += 1
        refreshActive()
    }
}

#if canImport(UIKit)
extension DocEditorController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        shouldChange(range, to: text)
    }

    func textViewDidChange(_ textView: UITextView) {
        textDidChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionDidChange()
    }
}

struct DocTextEditor: UIViewRepresentable {
    let controller: DocEditorController

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: Space.s2, left: Space.s3, bottom: Space.s4, right: Space.s3)
        view.tintColor = Theme.current.accent.platformColor
        view.linkTextAttributes = [.foregroundColor: Theme.current.accent.platformColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.allowsEditingTextAttributes = false
        view.adjustsFontForContentSizeCategory = true
        view.delegate = controller
        controller.attach(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}
#else
/// Pasted text arrives as plain text, so another app's fonts and colours can't get in.
private final class PlainPasteTextView: NSTextView {
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}

extension DocEditorController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text else { return true }
        return shouldChange(range, to: text)
    }

    func textDidChange(_ notification: Notification) {
        textDidChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionDidChange()
    }
}

struct DocTextEditor: NSViewRepresentable {
    let controller: DocEditorController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = PlainPasteTextView(frame: .zero, textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = .width
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: Space.s3, height: Space.s2)
        view.insertionPointColor = Theme.current.accent.platformColor
        view.linkTextAttributes = [.foregroundColor: Theme.current.accent.platformColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.delegate = controller
        scroll.documentView = view
        controller.attach(view)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}
#endif

/// Headings, emphasis, lists, and links, always within reach above the keyboard.
struct DocFormatBar: View {
    let controller: DocEditorController
    let onLink: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                textButton("H1", label: "Heading", isOn: controller.activeStyle == .heading1) { controller.setStyle(.heading1) }
                textButton("H2", label: "Subheading", isOn: controller.activeStyle == .heading2) { controller.setStyle(.heading2) }
                iconButton("bold", label: "Bold", isOn: controller.isBold) { controller.toggleBold() }
                iconButton("italic", label: "Italic", isOn: controller.isItalic) { controller.toggleItalic() }
                iconButton("list.bullet", label: "Bulleted list", isOn: controller.activeStyle == .bullet) { controller.setStyle(.bullet) }
                iconButton("list.number", label: "Numbered list", isOn: controller.activeStyle == .numbered) { controller.setStyle(.numbered) }
                iconButton("link", label: "Link", isOn: controller.currentLink != nil, action: onLink)
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
        }
        .background(Theme.current.bg.color)
    }

    private func textButton(_ text: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        button(label: label, isOn: isOn, action: action) {
            Text(text).font(Typeface.callout)
        }
    }

    private func iconButton(_ name: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        button(label: label, isOn: isOn, action: action) {
            Image(systemName: name).font(Typeface.callout)
        }
    }

    private func button(label: String, isOn: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        let theme = Theme.current
        return Button(action: action) {
            content()
                .foregroundStyle(isOn ? theme.accent.color : theme.textPrimary.color)
                .frame(width: Space.s6 + Space.s2, height: Space.s6 + Space.s2)
                .neumorphic(isOn ? .pressed : .subtle, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

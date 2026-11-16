import CoreGraphics
import Foundation
import PDFKit

/// A PDF's pages for reading, Listen and search. One that fits in memory opens in PDFKit as it always did.
/// A bigger one (issue 124) is read through public CoreGraphics a range at a time, as `LargePDF`.
enum PDFSource {
    case whole(PDFDocument)
    case large(LargePDF)

    /// Nil when it isn't a PDF that opens.
    static func open(_ source: any ByteSource, wholeLimit: Int = ReaderFile.wholeLimit) -> PDFSource? {
        if source.count > wholeLimit { return LargePDF(source).map(PDFSource.large) }
        if let data = source as? Data { return PDFDocument(data: data).map(PDFSource.whole) }
        return (try? ReadableText.whole(source)).flatMap(PDFDocument.init(data:)).map(PDFSource.whole)
    }

    var isLocked: Bool {
        switch self {
        case .whole(let document): document.isLocked
        case .large(let pdf): pdf.isLocked
        }
    }

    var pageCount: Int {
        switch self {
        case .whole(let document): document.pageCount
        case .large(let pdf): pdf.pageCount
        }
    }

    /// Each page's text, in order.
    var pages: [String] {
        switch self {
        case .whole(let document): (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        case .large(let pdf): pdf.pageTexts()
        }
    }

    /// All of it, as Listen and search read it.
    var text: String {
        switch self {
        case .whole(let document): document.string ?? ""
        case .large(let pdf): pdf.pageTexts().joined(separator: "\n")
        }
    }

    /// PDFKit's own document, for what only it knows, like the chapter list. Nil for a large PDF.
    var document: PDFDocument? {
        if case .whole(let document) = self { return document }
        return nil
    }
}

/// A PDF too big to hold in memory, like a 1 GB scan. CoreGraphics reads it through a data provider a
/// range at a time, so only the pieces a page needs are unsealed, and nothing is written anywhere. Its
/// pages are drawn by `LargePDFPages`. For a page's words and where each letter sits, that one page alone
/// is copied into a small PDF in memory and handed to PDFKit, which is all public API.
final class LargePDF: @unchecked Sendable {
    /// Text pages kept, so a highlight moving down a page doesn't copy it again for every word.
    static let textPagesKept = 4

    private let document: CGPDFDocument
    /// CoreGraphics may not be safe to use from two threads at once, so every use takes this.
    private let lock = NSLock()
    /// Each page's copy is kept as its document, which the page needs alive.
    private var textPages: [Int: PDFDocument] = [:]
    private var textOrder: [Int] = []

    init?(_ source: any ByteSource) {
        guard let provider = Self.provider(source), let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return nil }
        self.document = document
    }

    var isLocked: Bool {
        lock.withLock { document.isEncrypted && !document.isUnlocked }
    }

    var pageCount: Int {
        lock.withLock { document.numberOfPages }
    }

    /// How big a page is in points, turned as it's meant to be shown.
    func size(of index: Int) -> CGSize {
        lock.withLock {
            guard let page = document.page(at: index + 1) else { return CGSize(width: 612, height: 792) }
            return Self.geometry(page).size
        }
    }

    /// The page drawn `pixelWidth` pixels wide, on white.
    func image(of index: Int, pixelWidth: Int) -> CGImage? {
        lock.withLock {
            guard let page = document.page(at: index + 1), pixelWidth > 0 else { return nil }
            let geometry = Self.geometry(page)
            let scale = CGFloat(pixelWidth) / geometry.size.width
            let pixelHeight = Int(min(16_384, max(1, (geometry.size.height * scale).rounded())))
            guard let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            context.concatenate(geometry.transform)
            context.clip(to: page.getBoxRect(.cropBox))
            context.drawPDFPage(page)
            return context.makeImage()
        }
    }

    /// Where a rectangle on the page, in the page's own space, falls on a page shown `width` points wide,
    /// measured from its top left.
    func viewRect(_ rect: CGRect, page index: Int, width: CGFloat) -> CGRect {
        lock.withLock {
            guard let page = document.page(at: index + 1) else { return .zero }
            let geometry = Self.geometry(page)
            let scale = width / geometry.size.width
            let turned = rect.applying(geometry.transform)
            return CGRect(
                x: turned.minX * scale, y: (geometry.size.height - turned.maxY) * scale,
                width: turned.width * scale, height: turned.height * scale
            )
        }
    }

    /// The point on the page, in its own space, under a point on a page shown `width` points wide.
    func pagePoint(_ point: CGPoint, page index: Int, width: CGFloat) -> CGPoint? {
        lock.withLock {
            guard let page = document.page(at: index + 1) else { return nil }
            let geometry = Self.geometry(page)
            let scale = width / geometry.size.width
            let turned = CGPoint(x: point.x / scale, y: geometry.size.height - point.y / scale)
            return turned.applying(geometry.transform.inverted())
        }
    }

    /// One page copied on its own, with the document that holds it, which the page needs kept alive.
    struct TextPage {
        let document: PDFDocument
        let page: PDFPage
    }

    /// The page on its own, for PDFKit to read its words and find each letter. Its space is the page's.
    func textPage(_ index: Int) -> TextPage? {
        lock.withLock {
            let copy: PDFDocument
            if let kept = textPages[index] {
                copy = kept
            } else {
                guard let page = document.page(at: index + 1), let made = Self.copy(page) else { return nil }
                copy = made
                textPages[index] = copy
                textOrder.append(index)
                if textOrder.count > Self.textPagesKept { textPages[textOrder.removeFirst()] = nil }
            }
            return copy.page(at: 0).map { TextPage(document: copy, page: $0) }
        }
    }

    /// Every page's words, a page at a time. Nothing is kept, so a long book doesn't fill memory.
    func pageTexts() -> [String] {
        (0..<pageCount).map { index in
            autoreleasepool {
                lock.withLock {
                    guard let page = document.page(at: index + 1), Self.mayHaveText(page) else { return "" }
                    return Self.copy(page)?.string ?? ""
                }
            }
        }
    }

    /// Web links on the page, in its own space. A link to somewhere in the file isn't followed here.
    func links(on index: Int) -> [(rect: CGRect, url: URL)] {
        lock.withLock {
            guard let dictionary = document.page(at: index + 1)?.dictionary else { return [] }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return [] }
            var found: [(CGRect, URL)] = []
            for position in 0..<min(CGPDFArrayGetCount(annotations), 500) {
                var annotation: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                var action: CGPDFDictionaryRef?
                var address: CGPDFStringRef?
                var box: CGPDFArrayRef?
                guard CGPDFArrayGetDictionary(annotations, position, &annotation), let annotation,
                      CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype, String(cString: subtype) == "Link",
                      CGPDFDictionaryGetDictionary(annotation, "A", &action), let action,
                      CGPDFDictionaryGetString(action, "URI", &address), let address,
                      let text = CGPDFStringCopyTextString(address) as String?, text.count <= DocText.maxLinkLength,
                      let url = URL(string: text),
                      CGPDFDictionaryGetArray(annotation, "Rect", &box), let box, CGPDFArrayGetCount(box) == 4
                else { continue }
                var numbers = [CGPDFReal](repeating: 0, count: 4)
                guard (0..<4).allSatisfy({ CGPDFArrayGetNumber(box, $0, &numbers[$0]) }) else { continue }
                let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1]).standardized
                found.append((rect, url))
            }
            return found
        }
    }

    // MARK: Reading the file

    /// Holds the source for CoreGraphics, which releases it when it's done with the document.
    private final class Box {
        let source: any ByteSource
        init(_ source: any ByteSource) { self.source = source }
    }

    private static func provider(_ source: any ByteSource) -> CGDataProvider? {
        let box = Unmanaged.passRetained(Box(source))
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let source = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().source
                let start = Int(position)
                guard start >= 0, start < source.count, count > 0 else { return 0 }
                // A piece that won't open reads as the end of the file, so CoreGraphics stops there.
                guard let data = try? source.read(start..<(start + min(count, source.count - start))) else { return 0 }
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                return data.count
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            }
        )
        // Whether CoreGraphics calls releaseInfo when it can't make the provider isn't documented, so the
        // retain is left in place then: a source kept a little too long beats one freed twice.
        return CGDataProvider(directInfo: box.toOpaque(), size: off_t(source.count), callbacks: &callbacks)
    }

    // MARK: Pages

    /// The page's size as shown, and the transform from its own space into that, from the bottom left.
    private static func geometry(_ page: CGPDFPage) -> (size: CGSize, transform: CGAffineTransform) {
        let box = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        // A box from a hostile file can be any size, so it's held to what PDF itself allows.
        let size = CGSize(width: min(14_400, max(1, turned.width)), height: min(14_400, max(1, turned.height)))
        // At its own size it's never scaled, only turned and moved into place.
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        return (size, transform)
    }

    /// A page with no fonts has no words, like most of a scan without its words found, so it isn't copied.
    private static func mayHaveText(_ page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return true }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else {
            // Resources can come from a parent page, so this can't tell.
            return true
        }
        var fonts: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fonts) { return true }
        // Words can sit in a form drawn on the page, so a page with a form is read too. A picture alone has none.
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var hasForm = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let info = CGPDFStreamGetDictionary(stream),
               CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" {
                hasForm = true
                return false
            }
            return true
        }, nil)
        return hasForm
    }

    /// The page drawn on its own into a PDF in memory, with its media box, so the copy's space is the page's.
    private static func copy(_ page: CGPDFPage) -> PDFDocument? {
        let data = NSMutableData()
        var box = page.getBoxRect(.mediaBox)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        context.beginPDFPage(nil)
        context.drawPDFPage(page)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)
    }
}

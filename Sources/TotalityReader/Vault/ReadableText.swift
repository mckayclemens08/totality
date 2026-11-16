import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Turns a stored item into text for reading, search, and Listen.
enum ReadableText {
    static let wordMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    static let markdownMime = "text/markdown"
    static let epubMime = "application/epub+zip"

    /// A file's text. A PDF, EPUB or Word file is read a page or a part at a time, so only its words are
    /// ever held whole. Anything else is read whole, up to `ReaderFile.wholeLimit`.
    static func extract(_ source: any ByteSource, mime: String?) throws -> String {
        guard let mime else { throw ReaderError.notReadable }
        if mime == "application/pdf" {
            guard let pdf = PDFSource.open(source) else { throw ReaderError.notReadable }
            guard !pdf.isLocked else { throw ReaderError.passwordProtected }
            return pdf.text
        }
        if mime == epubMime || mime == wordMime { return try document(source, mime: mime).plainText }
        guard mime == References.mime || mime == MarkdownText.mime || mime == markdownMime || HTMLText.mimes.contains(mime)
            || mime.hasPrefix("text/")
        else { throw ReaderError.notReadable }
        let data = try whole(source)
        if mime == References.mime { return References.readableText(data) }
        if mime == MarkdownText.mime { return MarkdownText.plainText(String(decoding: data, as: UTF8.self)) }
        if mime == markdownMime { return DocText(markdown: String(decoding: data, as: UTF8.self)).plainText }
        // A web page's words, never its markup.
        if HTMLText.mimes.contains(mime) { return HTMLText.read(data).document.plainText }
        guard mime.hasPrefix("text/") else { throw ReaderError.notReadable }
        guard let text = String(data: data, encoding: .utf8) else { throw ReaderError.notReadable }
        return text
    }

    /// Where each page's text sits in the text Listen reads. It's a new copy of the file, so this can run
    /// away from the main thread while the pages are on screen.
    static func pageMap(_ source: any ByteSource) -> PDFPageMap {
        guard let pdf = PDFSource.open(source) else { return PDFPageMap(whole: "", pages: []) }
        if let document = pdf.document { return pageMap(document) }
        let pages = pdf.pages
        return PDFPageMap(whole: pages.joined(separator: "\n"), pages: pages)
    }

    static func pageMap(_ document: PDFDocument) -> PDFPageMap {
        PDFPageMap(
            whole: document.string ?? "",
            pages: (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        )
    }

    /// EPUB and Word have structure worth keeping. Anything else is one section of paragraphs.
    static func document(_ source: any ByteSource, mime: String?) throws -> ReadableDocument {
        switch mime {
        case epubMime:
            return try BookReader.epub(source).document
        case wordMime:
            return try BookReader.word(source)
        case let mime? where HTMLText.mimes.contains(mime):
            return HTMLText.read(try whole(source)).document
        default:
            let blocks = try extract(source, mime: mime)
                .split(whereSeparator: \.isNewline)
                .map { ReadableDocument.Block(text: String($0)) }
            return ReadableDocument(sections: [.init(blocks: blocks)])
        }
    }

    /// The whole file, for what can only be read whole. A big one is refused rather than filling memory.
    static func whole(_ source: any ByteSource) throws -> Data {
        if let file = source as? ReaderFile { return try file.whole() }
        if let data = source as? Data { return data }
        guard source.count <= ReaderFile.wholeLimit else { throw ReaderError.tooLargeToShow }
        return try source.read(0..<source.count)
    }

    static func mime(forFilename name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        if ext.lowercased() == "epub" { return epubMime }
        if ext.lowercased() == "docx" { return wordMime }
        if ext.lowercased() == "md" || ext.lowercased() == "markdown" { return markdownMime }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }
}

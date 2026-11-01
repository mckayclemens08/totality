import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Turns a stored item into text for reading, search, and Listen.
enum ReadableText {
    static let wordMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    static let markdownMime = "text/markdown"
    static let epubMime = "application/epub+zip"

    static func extract(_ data: Data, mime: String?) throws -> String {
        guard let mime else { throw ReaderError.notReadable }
        if mime == "application/pdf" {
            guard let document = PDFDocument(data: data) else { throw ReaderError.notReadable }
            guard !document.isLocked else { throw ReaderError.passwordProtected }
            return document.string ?? ""
        }
        if mime == epubMime || mime == wordMime { return try document(data, mime: mime).plainText }
        if mime == markdownMime { return DocText(markdown: String(decoding: data, as: UTF8.self)).plainText }
        guard mime.hasPrefix("text/") else { throw ReaderError.notReadable }
        guard let text = String(data: data, encoding: .utf8) else { throw ReaderError.notReadable }
        return text
    }

    /// Where each page's text sits in the text Listen reads. It's a new copy of the file, so this can run
    /// away from the main thread while the pages are on screen.
    static func pageMap(_ data: Data) -> PDFPageMap {
        guard let document = PDFDocument(data: data) else { return PDFPageMap(whole: "", pages: []) }
        return PDFPageMap(
            whole: document.string ?? "",
            pages: (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        )
    }

    /// EPUB and Word have structure worth keeping. Anything else is one section of paragraphs.
    static func document(_ data: Data, mime: String?) throws -> ReadableDocument {
        switch mime {
        case epubMime:
            return try BookReader.epub(data).document
        case wordMime:
            return try BookReader.word(data)
        default:
            let blocks = try extract(data, mime: mime)
                .split(whereSeparator: \.isNewline)
                .map { ReadableDocument.Block(text: String($0)) }
            return ReadableDocument(sections: [.init(blocks: blocks)])
        }
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

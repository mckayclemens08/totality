import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Turns a stored item into text for reading, search, and Listen.
enum ReadableText {
    static let wordMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    static let markdownMime = "text/markdown"

    static func extract(_ data: Data, mime: String?) throws -> String {
        guard let mime else { throw ReaderError.notReadable }
        if mime == "application/pdf" {
            guard let document = PDFDocument(data: data) else { throw ReaderError.notReadable }
            guard !document.isLocked else { throw ReaderError.passwordProtected }
            return document.string ?? ""
        }
        if mime == markdownMime { return DocText(markdown: String(decoding: data, as: UTF8.self)).plainText }
        guard mime.hasPrefix("text/") else { throw ReaderError.notReadable }
        guard let text = String(data: data, encoding: .utf8) else { throw ReaderError.notReadable }
        return text
    }

    static func mime(forFilename name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        if ext.lowercased() == "md" || ext.lowercased() == "markdown" { return markdownMime }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }
}

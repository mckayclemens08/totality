import Compression
import Foundation
import Testing
@testable import TotalityReader

/// Builds zips by hand, so hostile ones can lie in exactly the way a test needs.
private struct ZipBuilder {
    struct File {
        var name: String
        var data: Data
        var deflate = true
        var claimedSize: UInt32?
        var flags: UInt16 = 0
        var method: UInt16?
    }

    var files: [File] = []
    var claimedCount: UInt16?
    var claimedDirectoryOffset: UInt32?
    var trailer = Data()

    private static func deflated(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: data.count + 1024)
        let written = data.withUnsafeBytes { source in
            compression_encode_buffer(&output, output.count, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(output.prefix(written))
    }

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }

    func build() -> Data {
        var body = Data()
        var directory = Data()
        for file in files {
            let packed = file.deflate && !file.data.isEmpty ? Self.deflated(file.data) : file.data
            let method = file.method ?? (file.deflate && !file.data.isEmpty ? 8 : 0)
            let name = Data(file.name.utf8)
            let offset = UInt32(body.count)
            let size = file.claimedSize ?? UInt32(file.data.count)
            var common = Self.le16(20) + Self.le16(file.flags) + Self.le16(method) + Self.le32(0) + Self.le32(0)
            common += Self.le32(UInt32(packed.count)) + Self.le32(size)
            common += Self.le16(UInt16(name.count)) + Self.le16(0)
            body += Self.le32(0x0403_4B50) + common + name + packed
            directory += Self.le32(0x0201_4B50) + Self.le16(20) + common
            directory += Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le32(0) + Self.le32(offset) + name
        }
        let count = claimedCount ?? UInt16(files.count)
        var end = Self.le32(0x0605_4B50) + Self.le16(0) + Self.le16(0) + Self.le16(count) + Self.le16(count)
        end += Self.le32(UInt32(directory.count)) + Self.le32(claimedDirectoryOffset ?? UInt32(body.count)) + Self.le16(UInt16(trailer.count))
        return body + directory + end + trailer
    }
}

private func epub(chapters: [String], title: String = "The Rock Warrior's Way", base: String = "OEBPS/", spineOrder: [Int]? = nil) -> [ZipBuilder.File] {
    let manifest = chapters.indices.map { #"<item id="c\#($0)" href="text/ch\#($0).xhtml" media-type="application/xhtml+xml"/>"# }.joined()
    let spine = (spineOrder ?? Array(chapters.indices)).map { #"<itemref idref="c\#($0)"/>"# }.joined()
    let package = """
    <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>\(title)</dc:title></metadata><manifest><item id="css" href="s.css" media-type="text/css"/>\(manifest)</manifest>
    <spine><itemref idref="css"/>\(spine)</spine></package>
    """
    let container = #"<container><rootfiles><rootfile full-path="\#(base)content.opf"/></rootfiles></container>"#
    return [
        .init(name: "mimetype", data: Data("application/epub+zip".utf8), deflate: false),
        .init(name: "META-INF/container.xml", data: Data(container.utf8)),
        .init(name: "\(base)content.opf", data: Data(package.utf8)),
    ] + chapters.enumerated().map { .init(name: "\(base)text/ch\($0.offset).xhtml", data: Data($0.element.utf8)) }
}

private let chapterOne = """
<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><title>skip me</title>
<style>p { color: red }</style></head><body><h1>Chapter <em>One</em></h1><p>Climbing is a mental game.&nbsp;Most falls
happen in the head first.</p><ul><li>Commit</li><li>to the &ldquo;move&rdquo;</li></ul><script>nope()</script></body></html>
"""

@Suite struct ZipArchiveTests {
    private func zip(_ files: [ZipBuilder.File]) -> Data { ZipBuilder(files: files).build() }

    @Test("Reads both stored and compressed files")
    func reading() throws {
        let text = Data(String(repeating: "Most falls happen in the head first. ", count: 200).utf8)
        var archive = try ZipArchive(zip([
            .init(name: "stored.txt", data: Data("plain".utf8), deflate: false),
            .init(name: "packed.txt", data: text),
            .init(name: "empty.txt", data: Data()),
        ]))
        #expect(try archive.read("stored.txt") == Data("plain".utf8))
        #expect(try archive.read("packed.txt") == text)
        #expect(try archive.read("empty.txt") == Data())
        #expect(try archive.read("missing.txt") == nil)
    }

    @Test("A comment after the end marker is fine")
    func comments() throws {
        var builder = ZipBuilder(files: [.init(name: "a", data: Data("b".utf8), deflate: false)])
        builder.trailer = Data("a comment".utf8)
        var archive = try ZipArchive(builder.build())
        #expect(try archive.read("a") == Data("b".utf8))
    }

    @Test("Anything that isn't a zip is refused", arguments: [Data(), Data("not a zip".utf8), Data(repeating: 0, count: 5000), Data(repeating: 0x50, count: 100)])
    func notZips(_ data: Data) {
        #expect(throws: ReaderError.notReadable) { try ZipArchive(data) }
    }

    @Test("Every truncation fails cleanly, never crashes")
    func truncation() {
        let data = zip([.init(name: "a.txt", data: Data(String(repeating: "x", count: 500).utf8))])
        for length in 0..<data.count {
            var archive = try? ZipArchive(data.prefix(length))
            _ = try? archive?.read("a.txt")
        }
    }

    @Test("Random damage fails cleanly, never crashes")
    func damage() {
        let data = zip([.init(name: "a.txt", data: Data(String(repeating: "x", count: 500).utf8))])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            var bad = [UInt8](data)
            for _ in 0..<4 { bad[Int.random(in: 0..<bad.count, using: &generator)] = .random(in: 0...255, using: &generator) }
            var archive = try? ZipArchive(Data(bad))
            for name in archive?.names ?? [] { _ = try? archive?.read(name) }
        }
    }

    @Test("A tiny file claiming a huge size is refused before any memory is taken")
    func bombs() throws {
        var archive = try ZipArchive(zip([.init(name: "bomb", data: Data(repeating: 0, count: 1000), claimedSize: 0xFFFF_FFF0)]))
        #expect(throws: ReaderError.notReadable) { try archive.read("bomb") }
    }

    @Test("A claimed size smaller than the truth can't overrun")
    func lyingSmall() throws {
        var archive = try ZipArchive(zip([.init(name: "x", data: Data(repeating: 7, count: 100_000), claimedSize: 10)]))
        #expect(try archive.read("x")?.count == 10)
    }

    @Test("Many files can't add up past the budget")
    func budgets() throws {
        let files = (0..<5).map { ZipBuilder.File(name: "f\($0)", data: Data(repeating: 1, count: 1000)) }
        var archive = try ZipArchive(zip(files), budget: 2500)
        #expect(try archive.read("f0") != nil)
        #expect(try archive.read("f1") != nil)
        #expect(throws: ReaderError.notReadable) { try archive.read("f2") }
    }

    @Test("Encrypted entries and unknown methods are refused")
    func unsupported() throws {
        var archive = try ZipArchive(zip([
            .init(name: "locked", data: Data("x".utf8), deflate: false, flags: 1),
            .init(name: "odd", data: Data("x".utf8), deflate: false, method: 12),
        ]))
        #expect(throws: ReaderError.notReadable) { try archive.read("locked") }
        #expect(throws: ReaderError.notReadable) { try archive.read("odd") }
    }

    @Test("A stored file whose two sizes disagree is refused")
    func storedSizes() throws {
        var archive = try ZipArchive(zip([.init(name: "x", data: Data(repeating: 7, count: 100), deflate: false, claimedSize: 10)]))
        #expect(throws: ReaderError.notReadable) { try archive.read("x") }
    }

    @Test("A directory entry that points at something else is refused")
    func wrongHeader() throws {
        var data = zip([.init(name: "x", data: Data("words".utf8), deflate: false)])
        data[data.startIndex] = 0
        var archive = try ZipArchive(data)
        #expect(throws: ReaderError.notReadable) { try archive.read("x") }
    }

    @Test("One file over the limit is refused even with budget to spare")
    func entryLimit() throws {
        var archive = try ZipArchive(zip([.init(name: "x", data: Data(count: ZipArchive.maxEntryBytes + 1), deflate: false)]))
        #expect(throws: ReaderError.notReadable) { try archive.read("x") }
    }

    @Test("A real list of too many files is refused")
    func tooManyEntries() {
        let files = (0...ZipArchive.maxEntries).map { ZipBuilder.File(name: "\($0)", data: Data(), deflate: false) }
        #expect(throws: ReaderError.notReadable) { try ZipArchive(zip(files)) }
    }

    @Test("Directory numbers that point nowhere are refused")
    func lyingDirectory() {
        var count = ZipBuilder(files: [.init(name: "a", data: Data("b".utf8))])
        count.claimedCount = 900
        #expect(throws: ReaderError.notReadable) { try ZipArchive(count.build()) }
        var zip64 = ZipBuilder(files: [])
        zip64.claimedDirectoryOffset = 0xFFFF_FFFF
        #expect(throws: ReaderError.notReadable) { try ZipArchive(zip64.build()) }
        var past = ZipBuilder(files: [.init(name: "a", data: Data("b".utf8))])
        past.claimedDirectoryOffset = 0x00FF_FFFF
        #expect(throws: ReaderError.notReadable) { try ZipArchive(past.build()) }
    }
}

@Suite struct BookReaderTests {
    @Test("An EPUB reads in order, with its title and headings, and without its styles or scripts")
    func readsAnEPUB() throws {
        let second = #"<html><body><h2>Chapter Two</h2><p>Accept the fall.</p></body></html>"#
        let book = try BookReader.epub(ZipBuilder(files: epub(chapters: [chapterOne, second])).build())
        #expect(book.title == "The Rock Warrior's Way")
        #expect(book.document.sections.count == 2)
        #expect(book.document.sections.map(\.title) == ["Chapter One", "Chapter Two"])
        #expect(book.document.sections[0].blocks.map(\.text) == [
            "Chapter One", "Climbing is a mental game. Most falls happen in the head first.", "Commit", "to the \u{201C}move\u{201D}",
        ])
        #expect(!book.document.plainText.contains("skip me"))
        #expect(!book.document.plainText.contains("nope"))
        #expect(!book.document.plainText.contains("color"))
    }

    @Test("A package at the top of the archive works too")
    func packageAtTheTop() throws {
        let book = try BookReader.epub(ZipBuilder(files: epub(chapters: [chapterOne], base: "")).build())
        #expect(book.document.sections.count == 1)
    }

    @Test("A chapter that breaks partway keeps what came before it")
    func brokenChapter() throws {
        let broken = "<html><body><p>Kept this.</p><p>Then it stops<"
        let book = try BookReader.epub(ZipBuilder(files: epub(chapters: [broken])).build())
        #expect(book.document.plainText.contains("Kept this."))
    }

    @Test("Entity expansion tricks don't blow up")
    func entityBomb() throws {
        let bomb = """
        <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
        <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;"><!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">]>
        <html><body><p>Real words.</p><p>&d;</p></body></html>
        """
        let book = try BookReader.epub(ZipBuilder(files: epub(chapters: [bomb])).build())
        #expect(book.document.plainText.contains("Real words."))
        #expect(book.document.plainText.count < 1000)
    }

    @Test("An entity a file defines for itself never reaches the text")
    func planted() throws {
        let chapter = #"<?xml version="1.0"?><!DOCTYPE html [<!ENTITY a "planted words">]><html><body><p>Real words.</p><p>&a;</p></body></html>"#
        let book = try BookReader.epub(ZipBuilder(files: epub(chapters: [chapter])).build())
        #expect(book.document.plainText.contains("Real words."))
        #expect(!book.document.plainText.contains("planted"))
    }

    @Test("A doctype can't hide behind a comment, a quote, or a split in its own name")
    func hiddenDoctypes() {
        for text in [
            #"<!-- <!DOCTYPE a> --><!DOCTYPE x [<!ENTITY a "]>"><!ENTITY b "more">]><p>&a;</p>"#,
            #"<!DOC<!DOCTYPE x>TYPE y [<!ENTITY a "planted">]><p>&a;</p>"#,
            #"<!doctype x SYSTEM "file:///etc/passwd"><p>Real</p>"#,
        ] {
            #expect(!SafeXML.withoutDoctypes(text).lowercased().contains("<!doctype"), "\(text)")
        }
        #expect(SafeXML.withoutDoctypes("<p>Real</p>") == "<p>Real</p>")
    }

    @Test("Text in UTF-16 reads, and a declared encoding can't change how it's read", arguments: [
        String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf16,
    ])
    func encodings(_ encoding: String.Encoding) throws {
        let chapter = #"<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE x [<!ENTITY a "planted">]><html><body><p>Real words.</p><p>&a;</p></body></html>"#
        var files = epub(chapters: ["<html></html>"])
        files[3].data = try #require(chapter.data(using: encoding))
        let text = try BookReader.epub(ZipBuilder(files: files).build()).document.plainText
        #expect(text.contains("Real words."))
        #expect(!text.contains("planted"))
    }

    @Test("A file claiming UTF-7 is read as UTF-8")
    func declaredEncoding() throws {
        let chapter = #"<?xml version="1.0" encoding="UTF-7"?><html><body><p>Real +ADw-words.</p></body></html>"#
        let text = try BookReader.epub(ZipBuilder(files: epub(chapters: [chapter])).build()).document.plainText
        #expect(text.contains("Real +ADw-words."))
    }

    @Test("Thousands of false doctypes take no time at all")
    func manyDoctypes() throws {
        let text = String(repeating: "<!DOCTYPE ", count: 200_000)
        let start = Date()
        _ = SafeXML.withoutDoctypes(text)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("A book's title can't run on forever")
    func longTitle() throws {
        let book = try BookReader.epub(ZipBuilder(files: epub(chapters: [chapterOne], title: String(repeating: "Long ", count: 10_000))).build())
        #expect(book.title?.count == SafeXML.maxTitleLength)
    }

    @Test("A chapter listed twice reads once")
    func repeatedChapter() throws {
        let book = try BookReader.epub(ZipBuilder(files: epub(chapters: [chapterOne], spineOrder: [0, 0, 0])).build())
        #expect(book.document.sections.count == 1)
    }

    @Test("A stylesheet in the reading order isn't read as a chapter")
    func stylesheetInSpine() throws {
        let files = epub(chapters: [chapterOne]) + [.init(name: "OEBPS/s.css", data: Data("<p>p { color: red }</p>".utf8))]
        let book = try BookReader.epub(ZipBuilder(files: files).build())
        #expect(book.document.sections.count == 1)
        #expect(!book.document.plainText.contains("color"))
    }

    @Test("Paths that climb out of the book find nothing", arguments: [
        ("../../../etc/passwd", "OEBPS/content.opf", "etc/passwd"), ("text/ch%201.xhtml#part", "OEBPS/content.opf", "OEBPS/text/ch 1.xhtml"),
        ("./a.xhtml", "content.opf", "a.xhtml"), ("../b.xhtml", "a/b/content.opf", "a/b.xhtml"),
    ])
    func paths(_ href: String, _ package: String, _ expected: String) {
        #expect(BookReader.resolve(href, from: package) == expected)
    }

    @Test("A book with no readable chapters says so")
    func emptyBook() {
        #expect(throws: ReaderError.notReadable) { try BookReader.epub(ZipBuilder(files: epub(chapters: [])).build()) }
        #expect(throws: ReaderError.notReadable) { try BookReader.epub(ZipBuilder(files: [.init(name: "a", data: Data())]).build()) }
    }

    @Test("Word files read as headings and paragraphs, and leave out deleted text")
    func readsWord() throws {
        let part = """
        <?xml version="1.0"?><w:document xmlns:w="x"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Budget</w:t></w:r></w:p>
        <w:p><w:r><w:t>Rent is </w:t></w:r><w:r><w:t>due</w:t></w:r><w:r><w:tab/><w:t>Friday.</w:t></w:r><w:del><w:r><w:delText>removed</w:delText></w:r></w:del></w:p>
        <w:p/></w:body></w:document>
        """
        let document = try BookReader.word(ZipBuilder(files: [.init(name: "word/document.xml", data: Data(part.utf8))]).build())
        #expect(document.sections[0].blocks == [.init(text: "Budget", isHeading: true), .init(text: "Rent is due Friday.")])
    }

    @Test("An EPUB imports under its own title, and Listen and search reach the text")
    func vaultImport() async throws {
        let vault = try newVault()
        let data = ZipBuilder(files: epub(chapters: [chapterOne])).build()
        let item = try await vault.importFile(data, filename: "rock-warrior-v2-final.epub")
        #expect(item.title == "The Rock Warrior's Way")
        #expect(item.typeName == "EPUB")
        #expect(try await vault.text(of: item.id).contains("mental game"))
        #expect(try await vault.search("mental").count == 1)
        #expect(try await vault.document(of: item.id).sections.first?.title == "Chapter One")
    }

    @Test("A broken EPUB still imports, and says it can't be read")
    func brokenImport() async throws {
        let vault = try newVault()
        let item = try await vault.importFile(Data("not a book".utf8), filename: "broken.epub")
        #expect(item.title == "broken")
        await #expect(throws: ReaderError.notReadable) { try await vault.text(of: item.id) }
    }

    #if os(macOS)
    private func run(_ path: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("A book made by the real zip tool opens")
    func realZip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in epub(chapters: [chapterOne]) {
            let url = directory.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        try run("/usr/bin/zip", ["-q", "-r", "-X", "book.epub", "mimetype", "META-INF", "OEBPS"], in: directory)
        let book = try BookReader.epub(Data(contentsOf: directory.appendingPathComponent("book.epub")))
        #expect(book.title == "The Rock Warrior's Way")
        #expect(book.document.plainText.contains("mental game"))
    }

    @Test("A real .docx from macOS's own converter opens")
    func realWord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = "<html><body><p>Rent is due Friday.</p><p>Book the campsite.</p></body></html>"
        try Data(html.utf8).write(to: directory.appendingPathComponent("in.html"))
        try run("/usr/bin/textutil", ["-convert", "docx", "in.html", "-output", "out.docx"], in: directory)
        let document = try BookReader.word(Data(contentsOf: directory.appendingPathComponent("out.docx")))
        #expect(document.plainText.contains("Rent is due Friday."))
        #expect(document.plainText.contains("Book the campsite."))
    }
    #endif
}

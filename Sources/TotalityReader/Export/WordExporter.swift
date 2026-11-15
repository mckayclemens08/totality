import Foundation

/// Makes a Word file (.docx) on the device from an exported doc. Footnotes are Word's own, lists are
/// numbered by Word, and the template's margins, spacing and page numbers are set in the file, so it
/// keeps its shape when someone edits it. Every word goes in as escaped XML text.
enum WordExporter {
    static let mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    static func docx(_ document: ExportDocument, template: ExportTemplate, paper: PaperSize, images: [String: ExportImage] = [:]) -> Data {
        let margins = template.margins
        let space = CGSize(
            width: paper.size.width - margins.left - margins.right,
            height: (paper.size.height - margins.top - margins.bottom) * 0.6
        )
        var writer = WordBody(document: document, template: template, images: images, space: space)
        let body = writer.body()
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(packageRelationships.utf8))
        zip.add("docProps/core.xml", Data(core(document.meta).utf8))
        zip.add("word/document.xml", Data(writer.document(body: body, paper: paper).utf8))
        zip.add("word/_rels/document.xml.rels", Data(writer.relationships().utf8))
        zip.add("word/styles.xml", Data(styles(template).utf8))
        zip.add("word/numbering.xml", Data(writer.numbering().utf8))
        zip.add("word/footnotes.xml", Data(writer.footnotes().utf8))
        zip.add("word/header1.xml", Data(writer.header().utf8))
        zip.add("word/footer1.xml", Data(writer.footer().utf8))
        for picture in writer.pictures {
            zip.add("word/media/\(picture.name)", picture.image.data)
        }
        return zip.finished()
    }

    // MARK: Text

    /// XML text: escaped, and without the control characters XML can't hold.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                let value = scalar.value
                if value < 0x20 || (0xFFFE...0xFFFF).contains(value) || (0xD800...0xDFFF).contains(value) { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing""#

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Default Extension="png" ContentType="image/png"/>
    <Default Extension="jpeg" ContentType="image/jpeg"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
    <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>
    <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
    <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
    </Types>
    """

    private static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    </Relationships>
    """

    private static func core(_ meta: ExportDocument.Meta) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>\(escaped(meta.title))</dc:title>
        <dc:creator>\(escaped(meta.author))</dc:creator>
        </cp:coreProperties>
        """
    }

    // MARK: Styles

    private static func styles(_ template: ExportTemplate) -> String {
        let size = Int(template.fontSize * 2)
        let line = Int(240 * template.lineSpacing)
        let after = template.indentsParagraphs ? 0 : 160
        let font = escaped(template.fontName)
        let indent = template.indentsParagraphs ? #"<w:ind w:firstLine="720"/>"# : ""
        // An academic template keeps headings at the body's size, bold, as the style guides ask.
        let headingSizes = template == .doc ? [40, 32, 28, 24, 22, 22] : [size, size, size, size, size, size]
        let headings = (1...6).map { level in
            let centred = template != .doc && level == 1 ? #"<w:jc w:val="center"/>"# : ""
            let italic = template != .doc && level >= 3 ? "<w:i/>" : ""
            return """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
            <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="\(template == .doc ? 120 : 0)"/><w:ind w:firstLine="0"/>\(centred)<w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
            <w:rPr><w:b/>\(italic)<w:sz w:val="\(headingSizes[level - 1])"/></w:rPr></w:style>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles \(namespaces)>
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="\(font)" w:hAnsi="\(font)" w:cs="\(font)" w:eastAsia="\(font)"/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="\(after)" w:line="\(line)" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:pPr>\(indent)</w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:jc w:val="center"/><w:ind w:firstLine="0"/><w:spacing w:after="240"/></w:pPr><w:rPr>\(template == .doc ? #"<w:b/><w:sz w:val="48"/>"# : "")</w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Centered"><w:name w:val="Centered"/><w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/><w:ind w:firstLine="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Plain"><w:name w:val="Plain"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:firstLine="0"/></w:pPr></w:style>
        \(headings)
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720" w:right="720" w:firstLine="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="160" w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:firstLine="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="TableText"><w:name w:val="Table Text"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:i/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Bibliography"><w:name w:val="Bibliography"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720" w:hanging="720"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:sz w:val="20"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        </w:tblBorders><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
        </w:styles>
        """
    }
}

/// Builds the body of one Word file, keeping the links and list numbering it needs on the side.
private struct WordBody {
    let document: ExportDocument
    let template: ExportTemplate
    private var links: [URL] = []
    /// Each numbered list starts its own count, at its own first number.
    private var orderedStarts: [Int] = []
    private var isFirstContent = true
    private var afterBreak = false
    private let noteNumbers: Set<Int>
    private let images: [String: ExportImage]
    private let space: CGSize
    /// The images put in, in order, each a file in `word/media`.
    private(set) var pictures: [(name: String, image: ExportImage)] = []

    init(document: ExportDocument, template: ExportTemplate, images: [String: ExportImage], space: CGSize) {
        self.document = document
        self.template = template
        self.images = images
        self.space = space
        noteNumbers = Set(document.notes.map(\.number))
    }

    private func esc(_ text: String) -> String { WordExporter.escaped(text) }

    // MARK: Parts

    func document(body: String, paper: PaperSize) -> String {
        let size = paper.size
        let margins = template.margins
        let twips = { (points: Double) in Int((points * 20).rounded()) }
        let titlePage = template.hasTitlePage ? "<w:titlePg/>" : ""
        let reference = template.pageNumber == .header
            ? #"<w:headerReference w:type="default" r:id="rIdHeader"/>"#
            : #"<w:footerReference w:type="default" r:id="rIdFooter"/>"#
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(WordExporter.namespaces)><w:body>
        \(body)
        <w:sectPr>\(reference)<w:pgSz w:w="\(twips(size.width))" w:h="\(twips(size.height))"/>\
        <w:pgMar w:top="\(twips(margins.top))" w:right="\(twips(margins.right))" w:bottom="\(twips(margins.bottom))" w:left="\(twips(margins.left))" w:header="720" w:footer="720" w:gutter="0"/>\(titlePage)</w:sectPr>
        </w:body></w:document>
        """
    }

    func relationships() -> String {
        let fixed = [
            #"<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#,
            #"<Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>"#,
            #"<Relationship Id="rIdFootnotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>"#,
            #"<Relationship Id="rIdHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>"#,
            #"<Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>"#,
        ]
        let media = pictures.enumerated().map { index, picture in
            #"<Relationship Id="rIdImage\#(index + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\#(picture.name)"/>"#
        }
        let external = links.enumerated().map { index, url in
            #"<Relationship Id="rIdLink\#(index + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="\#(esc(url.absoluteString))" TargetMode="External"/>"#
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \((fixed + media + external).joined(separator: "\n"))
        </Relationships>
        """
    }

    func numbering() -> String {
        let bullets = ["•", "◦", "▪"]
        let bulletLevels = (0..<9).map { level in
            #"<w:lvl w:ilvl="\#(level)"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="\#(bullets[level % 3])"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="\#(720 * (level + 1))" w:hanging="360"/></w:pPr></w:lvl>"#
        }.joined()
        let formats = ["decimal", "lowerLetter", "lowerRoman"]
        let orderedLevels = (0..<9).map { level in
            #"<w:lvl w:ilvl="\#(level)"><w:start w:val="1"/><w:numFmt w:val="\#(formats[level % 3])"/><w:lvlText w:val="%\#(level + 1)."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="\#(720 * (level + 1))" w:hanging="360"/></w:pPr></w:lvl>"#
        }.joined()
        let ordered = orderedStarts.enumerated().map { index, start in
            #"<w:num w:numId="\#(index + 2)"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="\#(start)"/></w:lvlOverride></w:num>"#
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering \(WordExporter.namespaces)>
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\(bulletLevels)</w:abstractNum>
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\(orderedLevels)</w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>\(ordered)
        </w:numbering>
        """
    }

    func footnotes() -> String {
        let notes = document.notes.map { note in
            let paragraphs = note.blocks.isEmpty ? [ExportDocument.Block.paragraph([])] : note.blocks
            let body = paragraphs.enumerated().map { index, block in
                let mark = index == 0
                    ? #"<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r>"#
                    : ""
                return #"<w:p><w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>\#(mark)\#(plainRuns(flatRuns(block)))</w:p>"#
            }.joined()
            return #"<w:footnote w:id="\#(note.number)">\#(body)</w:footnote>"#
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:footnotes \(WordExporter.namespaces)>
        <w:footnote w:type="separator" w:id="-1"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:separator/></w:r></w:p></w:footnote>
        <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
        \(notes)
        </w:footnotes>
        """
    }

    private static let pageField = #"<w:fldSimple w:instr="PAGE"><w:r><w:t>1</w:t></w:r></w:fldSimple>"#

    func header() -> String {
        let head = template.runningHead(document.meta)
        let words = head.isEmpty ? "" : #"<w:r><w:t xml:space="preserve">\#(esc(head)) </w:t></w:r>"#
        let content = template.pageNumber == .header ? words + Self.pageField : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr \(WordExporter.namespaces)><w:p><w:pPr><w:pStyle w:val="Plain"/><w:jc w:val="right"/></w:pPr>\(content)</w:p></w:hdr>
        """
    }

    func footer() -> String {
        let content = template.pageNumber == .footer ? Self.pageField : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr \(WordExporter.namespaces)><w:p><w:pPr><w:pStyle w:val="Plain"/><w:jc w:val="center"/></w:pPr>\(content)</w:p></w:ftr>
        """
    }

    // MARK: Body

    mutating func body() -> String {
        var parts: [String] = [opening()]
        for block in document.blocks { parts.append(self.block(block, depth: 0, style: nil)) }
        if !document.bibliography.isEmpty {
            let heading = document.bibliographyHeading.isEmpty ? "References" : document.bibliographyHeading
            // A reference list starts its own page in an academic paper.
            let breakBefore = template == .doc ? "" : "<w:pageBreakBefore/>"
            parts.append(#"<w:p><w:pPr><w:pStyle w:val="Centered"/>\#(breakBefore)</w:pPr><w:r>\#(template == .doc ? "<w:rPr><w:b/></w:rPr>" : "")<w:t xml:space="preserve">\#(esc(heading))</w:t></w:r></w:p>"#)
            for entry in document.bibliography {
                parts.append(#"<w:p><w:pPr><w:pStyle w:val="Bibliography"/></w:pPr><w:r><w:t xml:space="preserve">\#(esc(entry))</w:t></w:r></w:p>"#)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// The title, and the lines a template puts with it.
    private mutating func opening() -> String {
        let meta = document.meta
        let line = { (text: String, style: String) -> String in
            text.isEmpty ? "" : #"<w:p><w:pPr><w:pStyle w:val="\#(style)"/></w:pPr><w:r><w:t xml:space="preserve">\#(WordExporter.escaped(text))</w:t></w:r></w:p>"#
        }
        let empty = #"<w:p><w:pPr><w:pStyle w:val="Plain"/></w:pPr></w:p>"#
        switch template {
        case .doc:
            return line(meta.title, "Title")
        case .essay:
            // MLA's heading: name, instructor, course and date, then the title centred.
            return [meta.author, meta.instructor, meta.course, meta.date].map { line($0, "Plain") }.joined() + line(meta.title, "Title")
        case .manuscript:
            let byline = meta.author.isEmpty ? "" : "by \(meta.author)"
            return line(meta.author, "Plain") + String(repeating: empty, count: 6) + line(meta.title, "Title") + line(byline, "Centered") + empty
        case .thesis:
            // The title page, then the text on the next page.
            afterBreak = true
            let lines = [line(meta.title, "Title"), line(meta.subtitle, "Centered"), empty, empty,
                         line(meta.author, "Centered"), line(meta.institute, "Centered"), line(meta.date, "Centered")]
            return String(repeating: empty, count: 8) + lines.joined() + #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
        }
    }

    private mutating func block(_ block: ExportDocument.Block, depth: Int, style: String?) -> String {
        defer { isFirstContent = false }
        switch block {
        case .heading(let level, let runs):
            let breakBefore = template.chaptersStartPages && level == 1 && !isFirstContent && !afterBreak ? "<w:pageBreakBefore/>" : ""
            afterBreak = false
            return #"<w:p><w:pPr><w:pStyle w:val="Heading\#(level)"/>\#(breakBefore)</w:pPr>\#(self.runs(runs))</w:p>"#
        case .paragraph(let runs):
            afterBreak = false
            return paragraph(runs, style: style)
        case .quote(let blocks):
            return blocks.map { self.block($0, depth: depth, style: "Quote") }.joined()
        case .list(let ordered, let start, let items):
            afterBreak = false
            return list(ordered: ordered, start: start, items: items, depth: depth)
        case .code(let text):
            afterBreak = false
            let lines = text.components(separatedBy: "\n").map { line in
                line.components(separatedBy: "\t").map { #"<w:t xml:space="preserve">\#(esc($0))</w:t>"# }.joined(separator: "<w:tab/>")
            }
            return #"<w:p><w:pPr><w:pStyle w:val="Code"/></w:pPr><w:r>\#(lines.joined(separator: "<w:br/>"))</w:r></w:p>"#
        case .table(let header, let rows):
            afterBreak = false
            return table(header: header, rows: rows)
        case .figure(let alt, let number, let source):
            afterBreak = false
            let caption = ExportDocument.caption(alt: alt, number: number)
            let picture = images[source].map { self.picture($0, alt: alt) } ?? ""
            let captionXML = caption.isEmpty ? "" : #"<w:p><w:pPr><w:pStyle w:val="Caption"/></w:pPr><w:r><w:t xml:space="preserve">\#(esc(caption))</w:t></w:r></w:p>"#
            return picture + captionXML
        case .rule:
            let mark = template == .manuscript ? "#" : "* * *"
            return #"<w:p><w:pPr><w:pStyle w:val="Centered"/></w:pPr><w:r><w:t>\#(mark)</w:t></w:r></w:p>"#
        case .pageBreak:
            afterBreak = true
            return #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
        }
    }

    /// An image on a line of its own, centred, at most the width of the text.
    private mutating func picture(_ image: ExportImage, alt: String) -> String {
        let number = pictures.count + 1
        let name = "image\(number).\(image.isPNG ? "png" : "jpeg")"
        pictures.append((name, image))
        let size = image.size(fitting: space)
        let cx = Int(size.width * 12700)
        let cy = Int(size.height * 12700)
        let description = esc(String(alt.prefix(1000)))
        return #"""
        <w:p><w:pPr><w:pStyle w:val="Centered"/><w:keepNext/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\#
        <wp:extent cx="\#(cx)" cy="\#(cy)"/><wp:docPr id="\#(number)" name="Figure \#(number)" descr="\#(description)"/>\#
        <wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>\#
        <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\#
        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\#(number)" name="\#(name)" descr="\#(description)"/><pic:cNvPicPr/></pic:nvPicPr>\#
        <pic:blipFill><a:blip r:embed="rIdImage\#(number)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\#
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\#
        </a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """#
    }

    private mutating func paragraph(_ runs: [ExportDocument.Run], style: String?, properties: String = "") -> String {
        let styleTag = style.map { #"<w:pStyle w:val="\#($0)"/>"# } ?? ""
        let pPr = styleTag.isEmpty && properties.isEmpty ? "" : "<w:pPr>\(styleTag)\(properties)</w:pPr>"
        return "<w:p>\(pPr)\(self.runs(runs))</w:p>"
    }

    private mutating func list(ordered: Bool, start: Int, items: [ExportDocument.ListItem], depth: Int) -> String {
        let level = min(depth, 8)
        var numID = 1
        if ordered {
            orderedStarts.append(start)
            numID = orderedStarts.count + 1
        }
        var parts: [String] = []
        for item in items {
            var first = true
            for block in item.blocks {
                if case .paragraph(var runs) = block, first {
                    first = false
                    if let task = item.task {
                        runs.insert(ExportDocument.Run(task ? "☒ " : "☐ "), at: 0)
                        parts.append(paragraph(runs, style: "ListParagraph", properties: #"<w:ind w:left="\#(720 * (level + 1))"/>"#))
                    } else {
                        parts.append(paragraph(runs, style: "ListParagraph", properties: #"<w:numPr><w:ilvl w:val="\#(level)"/><w:numId w:val="\#(numID)"/></w:numPr>"#))
                    }
                } else if case .list = block {
                    parts.append(self.block(block, depth: depth + 1, style: nil))
                } else if case .paragraph(let runs) = block {
                    parts.append(paragraph(runs, style: "ListParagraph", properties: #"<w:ind w:left="\#(720 * (level + 1))"/>"#))
                } else {
                    parts.append(self.block(block, depth: depth + 1, style: nil))
                }
            }
        }
        return parts.joined()
    }

    private func table(header: [[ExportDocument.Run]], rows: [[[ExportDocument.Run]]]) -> String {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        let row = { (cells: [[ExportDocument.Run]], isHeader: Bool) -> String in
            let padded = cells + Array(repeating: [], count: max(0, columns - cells.count))
            let content = padded.prefix(columns).map { cell -> String in
                var copy = cell
                if isHeader { copy = copy.map { var run = $0; run.bold = true; return run } }
                return #"<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/></w:tcPr><w:p><w:pPr><w:pStyle w:val="TableText"/></w:pPr>\#(plainRuns(copy))</w:p></w:tc>"#
            }.joined()
            return "<w:tr>\(isHeader ? "<w:trPr><w:tblHeader/></w:trPr>" : "")\(content)</w:tr>"
        }
        let grid = String(repeating: #"<w:gridCol w:w="2000"/>"#, count: columns)
        let body = ([row(header, true)] + rows.map { row($0, false) }).joined()
        return #"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="5000" w:type="pct"/></w:tblPr><w:tblGrid>\#(grid)</w:tblGrid>\#(body)</w:tbl><w:p><w:pPr><w:pStyle w:val="Plain"/></w:pPr></w:p>"#
    }

    // MARK: Runs

    private func properties(_ run: ExportDocument.Run) -> String {
        var tags = ""
        if run.link != nil { tags += #"<w:rStyle w:val="Hyperlink"/>"# }
        if run.code { tags += #"<w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/>"# }
        if run.bold { tags += "<w:b/>" }
        if run.italic { tags += "<w:i/>" }
        if run.strike { tags += "<w:strike/>" }
        if run.superscript { tags += #"<w:vertAlign w:val="superscript"/>"# } else if run.subscripted { tags += #"<w:vertAlign w:val="subscript"/>"# }
        return tags.isEmpty ? "" : "<w:rPr>\(tags)</w:rPr>"
    }

    private func textRun(_ run: ExportDocument.Run) -> String {
        if run.lineBreak { return "<w:r><w:br/></w:r>" }
        return #"<w:r>\#(properties(run))<w:t xml:space="preserve">\#(esc(run.text))</w:t></w:r>"#
    }

    /// Runs with their links and footnote references.
    private mutating func runs(_ runs: [ExportDocument.Run]) -> String {
        var xml = ""
        for run in runs {
            if let note = run.note {
                if noteNumbers.contains(note) {
                    xml += #"<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="\#(note)"/></w:r>"#
                }
            } else if let link = run.link {
                links.append(link)
                xml += #"<w:hyperlink r:id="rIdLink\#(links.count)">\#(textRun(run))</w:hyperlink>"#
            } else {
                xml += textRun(run)
            }
        }
        return xml
    }

    /// Runs without links or references, for a note or a table cell.
    private func plainRuns(_ runs: [ExportDocument.Run]) -> String {
        runs.filter { $0.note == nil }.map { run in
            var copy = run
            copy.link = nil
            return textRun(copy)
        }.joined()
    }

    private func flatRuns(_ block: ExportDocument.Block) -> [ExportDocument.Run] {
        switch block {
        case .paragraph(let runs), .heading(_, let runs): runs
        case .code(let text): [ExportDocument.Run(text)]
        case .figure(let alt, _, _): [ExportDocument.Run(alt)]
        case .quote(let blocks): blocks.flatMap(flatRuns)
        case .list(_, _, let items): items.flatMap { $0.blocks.flatMap(flatRuns) }
        case .table, .rule, .pageBreak: []
        }
    }
}

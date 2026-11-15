import Foundation

/// How an export is laid out. Each follows the common rule for its kind of writing, so a teacher or an
/// editor gets what they expect: one-inch margins, 12 point Times, and double spacing for an essay or a
/// manuscript, and a title page and a binding margin for a thesis.
public enum ExportTemplate: String, CaseIterable, Identifiable, Sendable {
    case doc, essay, manuscript, thesis

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .doc: "Doc"
        case .essay: "Essay (MLA or APA)"
        case .manuscript: "Manuscript"
        case .thesis: "Thesis"
        }
    }

    public var detail: String {
        switch self {
        case .doc: "As it reads, single spaced, with page numbers at the foot."
        case .essay: "Double spaced, 1 inch margins, your name and the page number at the top right, and the title centred."
        case .manuscript: "Standard manuscript format: a title block, double spacing, chapters on new pages, and your name, title and page number in the header."
        case .thesis: "A title page, a 1.5 inch binding margin, double spacing, chapters on new pages, and page numbers at the foot."
        }
    }

    /// Margins in points: top, left, bottom, right.
    var margins: (top: Double, left: Double, bottom: Double, right: Double) {
        switch self {
        case .thesis: (72, 108, 72, 72)
        default: (72, 72, 72, 72)
        }
    }

    var lineSpacing: Double {
        self == .doc ? 1.15 : 2
    }

    var fontName: String {
        self == .doc ? "Georgia" : "Times New Roman"
    }

    var fontSize: Double {
        self == .doc ? 11 : 12
    }

    /// Paragraphs start indented half an inch, with no gap between them, as printed prose does.
    var indentsParagraphs: Bool {
        self != .doc
    }

    var hasTitlePage: Bool {
        self == .thesis
    }

    /// Each top-level heading starts a new page.
    var chaptersStartPages: Bool {
        self == .thesis || self == .manuscript
    }

    enum PageNumber {
        /// At the top right, after the author's surname (and the title, for a manuscript).
        case header
        case footer
    }

    var pageNumber: PageNumber {
        switch self {
        case .essay, .manuscript: .header
        case .doc, .thesis: .footer
        }
    }

    /// The header beside the page number, from the author's surname and the title.
    func runningHead(_ meta: ExportDocument.Meta) -> String {
        let surname = meta.author.split(separator: ",").first.flatMap { $0.split(separator: " ").last }.map { String($0) } ?? ""
        switch self {
        case .essay: return surname
        case .manuscript:
            let title = meta.title.split(separator: " ").prefix(4).joined(separator: " ")
            return [surname, title].filter { !$0.isEmpty }.joined(separator: " / ")
        default: return ""
        }
    }
}

/// The paper an export is printed on.
public enum PaperSize: String, CaseIterable, Identifiable, Sendable {
    case letter, a4

    public var id: String { rawValue }
    public var name: String { self == .letter ? "US Letter" : "A4" }

    /// Points.
    var size: (width: Double, height: Double) {
        self == .letter ? (612, 792) : (595.28, 841.89)
    }

    /// Letter where it's the custom, A4 everywhere else.
    public static var local: PaperSize {
        let region = Locale.current.region?.identifier ?? "US"
        return ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "CR", "PA", "DO", "PR", "SV"].contains(region) ? .letter : .a4
    }
}

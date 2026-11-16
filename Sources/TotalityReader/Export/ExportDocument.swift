import Foundation

/// A doc read for export: blocks of styled words, with citations, cross-references, wiki links and
/// footnote numbers already worked out by the writing page (`web/reader-editor/src/exportModel.js`).
/// The page sends it as plain data, and it's checked here like any message: only known shapes, and
/// nothing larger than a doc can be.
public struct ExportDocument: Equatable, Sendable {
    public struct Run: Equatable, Sendable {
        public var text = ""
        public var bold = false
        public var italic = false
        public var strike = false
        public var code = false
        public var superscript = false
        public var subscripted = false
        /// Only web and mail addresses.
        public var link: URL?
        /// A footnote's number, for a run that marks where it's referred to.
        public var note: Int?
        public var lineBreak = false

        public init(_ text: String = "") { self.text = text }
    }

    public struct ListItem: Equatable, Sendable {
        /// Nil for an ordinary item, true or false for a ticked or unticked task.
        public var task: Bool?
        public var blocks: [Block]
    }

    public indirect enum Block: Equatable, Sendable {
        case heading(level: Int, runs: [Run])
        case paragraph([Run])
        case quote([Block])
        case list(ordered: Bool, start: Int, items: [ListItem])
        case code(String)
        case table(header: [[Run]], rows: [[[Run]]])
        /// An image and its caption. `source` is the address as written. Export finds the image in the
        /// Reader or in the address itself, and never fetches one from the internet.
        case figure(alt: String, number: Int, source: String)
        case rule
        case pageBreak
    }

    public struct Note: Equatable, Sendable {
        public var number: Int
        public var blocks: [Block]
    }

    public struct Meta: Equatable, Sendable {
        public var title = ""
        public var subtitle = ""
        public var author = ""
        public var date = ""
        public var institute = ""
        public var course = ""
        public var instructor = ""
    }

    public var meta = Meta()
    public var blocks: [Block] = []
    public var notes: [Note] = []
    public var bibliographyHeading = ""
    public var bibliography: [String] = []

    public init() {}

    static let maxBlocks = 50_000
    static let maxDepth = 8
    static let maxText = ReaderVault.maxTextBytes

    // MARK: Reading what the page sent

    /// Nil when it isn't the shape the page makes. `title` stands in when the doc names none.
    public init?(page value: Any, title: String) {
        guard let root = value as? [String: Any], let blocks = root["blocks"] as? [Any] else { return nil }
        var budget = Budget()
        let metaValues = root["meta"] as? [String: Any] ?? [:]
        let field = { (key: String) in String((metaValues[key] as? String ?? "").prefix(300)) }
        meta = Meta(
            title: field("title").isEmpty ? String(title.prefix(300)) : field("title"),
            subtitle: field("subtitle"), author: field("author"), date: field("date"),
            institute: field("institute"), course: field("course"), instructor: field("instructor")
        )
        self.blocks = Self.blocks(blocks, depth: 0, budget: &budget)
        notes = (root["notes"] as? [Any] ?? []).prefix(Self.maxBlocks).compactMap { value in
            guard let note = value as? [String: Any], let number = note["number"] as? Int, number > 0 else { return nil }
            return Note(number: number, blocks: Self.blocks(note["blocks"] as? [Any] ?? [], depth: 1, budget: &budget))
        }
        let bibliography = root["bibliography"] as? [String: Any] ?? [:]
        bibliographyHeading = String((bibliography["heading"] as? String ?? "").prefix(100))
        self.bibliography = (bibliography["entries"] as? [Any] ?? []).prefix(5000).compactMap { $0 as? String }.map { String($0.prefix(5000)) }
        guard budget.characters <= Self.maxText else { return nil }
    }

    private struct Budget {
        var blocks = 0
        var characters = 0
    }

    private static func blocks(_ values: [Any], depth: Int, budget: inout Budget) -> [Block] {
        guard depth <= maxDepth else { return [] }
        var found: [Block] = []
        for value in values {
            guard budget.blocks < maxBlocks, let block = value as? [String: Any], let type = block["t"] as? String else { continue }
            budget.blocks += 1
            switch type {
            case "h":
                let level = min(6, max(1, block["level"] as? Int ?? 1))
                found.append(.heading(level: level, runs: runs(block["runs"], budget: &budget)))
            case "p":
                found.append(.paragraph(runs(block["runs"], budget: &budget)))
            case "quote":
                found.append(.quote(blocks(block["blocks"] as? [Any] ?? [], depth: depth + 1, budget: &budget)))
            case "list":
                let items = (block["items"] as? [Any] ?? []).compactMap { value -> ListItem? in
                    guard let item = value as? [String: Any] else { return nil }
                    return ListItem(task: item["task"] as? Bool, blocks: blocks(item["blocks"] as? [Any] ?? [], depth: depth + 1, budget: &budget))
                }
                let start = min(1_000_000, max(0, block["start"] as? Int ?? 1))
                found.append(.list(ordered: block["ordered"] as? Bool ?? false, start: start, items: items))
            case "code":
                let text = block["text"] as? String ?? ""
                budget.characters += text.count
                found.append(.code(text))
            case "table":
                let header = (block["header"] as? [Any] ?? []).prefix(64).map { runs($0, budget: &budget) }
                let rows = (block["rows"] as? [Any] ?? []).prefix(10_000).map { row in
                    (row as? [Any] ?? []).prefix(64).map { runs($0, budget: &budget) }
                }
                found.append(.table(header: Array(header), rows: Array(rows)))
            case "figure":
                let alt = String((block["alt"] as? String ?? "").prefix(2000))
                let source = String((block["src"] as? String ?? "").prefix(2_000_000))
                found.append(.figure(alt: alt, number: max(0, block["number"] as? Int ?? 0), source: source))
            case "rule":
                found.append(.rule)
            case "pagebreak":
                found.append(.pageBreak)
            default:
                continue
            }
        }
        return found
    }

    private static func runs(_ value: Any?, budget: inout Budget) -> [Run] {
        (value as? [Any] ?? []).compactMap { value -> Run? in
            guard let values = value as? [String: Any] else { return nil }
            var run = Run(values["text"] as? String ?? "")
            budget.characters += run.text.count
            run.bold = values["b"] as? Bool ?? false
            run.italic = values["i"] as? Bool ?? false
            run.strike = values["s"] as? Bool ?? false
            run.code = values["code"] as? Bool ?? false
            run.superscript = values["sup"] as? Bool ?? false
            run.subscripted = values["sub"] as? Bool ?? false
            run.lineBreak = values["br"] as? Bool ?? false
            if let number = values["note"] as? Int, number > 0 { run.note = number }
            if let address = values["href"] as? String, address.count <= DocText.maxLinkLength,
               let url = URL(string: address), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                run.link = url
            }
            return run
        }
    }

    // MARK: Chapters

    /// Joins chapter docs into one manuscript, each starting a new page. Only the first chapter's front
    /// matter is kept, since it names the whole work.
    public static func manuscript(_ chapters: [String]) -> String {
        chapters.enumerated().map { index, text in
            index == 0 ? text : withoutFrontMatter(text)
        }
        .joined(separator: "\n\n\\newpage\n\n")
    }

    static func withoutFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let close = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return text }
        return lines[(close + 1)...].joined(separator: "\n")
    }
}

extension ExportDocument {
    /// Every figure's address, including those inside quotes and lists.
    public var imageSources: Set<String> {
        func sources(_ blocks: [Block]) -> [String] {
            blocks.flatMap { block -> [String] in
                switch block {
                case .figure(_, _, let source): source.isEmpty ? [] : [source]
                case .quote(let inner): sources(inner)
                case .list(_, _, let items): items.flatMap { sources($0.blocks) }
                default: []
                }
            }
        }
        return Set(sources(blocks))
    }

    /// The caption under a figure.
    static func caption(alt: String, number: Int) -> String {
        number > 0 ? (alt.isEmpty ? "Figure \(number)" : "Figure \(number). \(alt)") : alt
    }
}

extension ExportDocument.Run {
    /// The words of some runs, without styling, as a caption or a list needs them.
    static func words(_ runs: [ExportDocument.Run]) -> String {
        runs.map { $0.lineBreak ? " " : $0.text }.joined()
    }
}

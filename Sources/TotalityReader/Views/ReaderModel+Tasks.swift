import Foundation
import TotalityCore

// MARK: - Tasks (issue 123, step 4)

extension ReaderModel {
    /// The longest quote a task keeps. Anything longer is cut at a word, with an ellipsis.
    static let quoteLimit = 600

    /// Opens Add to Tasks for an item, with the words chosen in it, if any. Nothing is made until Add.
    public func addToTasks(_ item: ReaderItem, quote: String?) {
        guard taskMaker != nil else { return }
        let words = quote.map(Self.trimmedQuote)
        taskDraft = TaskDraft(
            title: "",
            source: TaskSource(module: .reader, itemID: item.id.uuidString, title: item.title, quote: words?.isEmpty == false ? words : nil)
        )
    }

    static func trimmedQuote(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > quoteLimit else { return flat }
        let cut = flat.prefix(quoteLimit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord + "…"
    }

    /// Whether a task's item is still in the Reader, outside the trash. Unknown until the Reader has loaded.
    public func hasItem(_ id: String) -> Bool? {
        guard phase == .ready else { return nil }
        guard let uuid = UUID(uuidString: id) else { return false }
        return items.contains { $0.id == uuid }
    }
}

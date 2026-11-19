import Foundation
import TotalityCore

// MARK: - Tasks (issue 123, step 4)

extension WebModel {
    /// Adds the page to Tasks' Inbox straight away, titled from the page, with its address to open it
    /// again (decision 7). A private window's page is never kept.
    public func addPageToTasks(title: String, url: URL) async {
        guard let taskMaker else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = TaskSource(module: .web, itemID: url.absoluteString, title: name.isEmpty ? (url.host() ?? url.absoluteString) : name, detail: url.host())
        do {
            notice = try await taskMaker.makeTask(TaskDraft(title: source.title, source: source)).line
        } catch {
            notice = "That didn't make it to Tasks. Try again."
        }
    }
}

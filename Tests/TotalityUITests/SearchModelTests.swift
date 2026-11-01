import Foundation
import Testing
import TotalityCore
@testable import TotalityUI

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var queries: [String] { lock.withLock { entries } }
    func add(_ query: String) { lock.withLock { entries.append(query) } }
}

private struct Searcher: ModuleSearcher {
    let module = ModuleID.reader
    let kinds: Set<ContentKind> = []
    let log = Log()

    /// Keeps going when cancelled for "slow", which is what a module partway through its work can do.
    func search(_ query: String) async throws -> [SearchHit] {
        log.add(query)
        if query == "slow" { try? await Task.sleep(for: .milliseconds(150)) }
        return query == "nothing" ? [] : [SearchHit(module: module, itemID: query, title: query)]
    }
}

@MainActor
@Suite struct SearchModelTests {
    private let searcher = Searcher()

    private func model(pause: Duration = .zero) -> SearchModel {
        SearchModel(search: UniversalSearch(searchers: [searcher]), pause: pause)
    }

    private func finished(_ model: SearchModel) async {
        for _ in 0..<400 where model.phase != .finished {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func titles(_ model: SearchModel) -> [String] {
        model.results.groups.flatMap(\.hits).map(\.title)
    }

    @Test("It waits for something to look for")
    func waits() async {
        let model = model()
        #expect(model.phase == .waiting)
        model.query = "   "
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.phase == .waiting)
        #expect(searcher.log.queries.isEmpty)
    }

    @Test("Typing searches, and the results arrive")
    func searches() async {
        let model = model()
        model.query = "lisbon"
        #expect(model.phase == .searching)
        await finished(model)
        #expect(titles(model) == ["lisbon"])
    }

    @Test("Clearing the box clears the results")
    func clears() async {
        let model = model()
        model.query = "lisbon"
        await finished(model)
        model.query = ""
        #expect(model.phase == .waiting)
        #expect(model.results == SearchResults())
    }

    @Test("Clearing the box stops a search still running, so its results can't come back")
    func clearingStops() async {
        let model = model()
        model.query = "slow"
        model.query = ""
        try? await Task.sleep(for: .milliseconds(250))
        #expect(model.phase == .waiting)
        #expect(model.results == SearchResults())
    }

    @Test("Old results stay on screen while the next search runs")
    func keepsResults() async {
        let model = model()
        model.query = "lisbon"
        await finished(model)
        model.query = "lisbon tram"
        #expect(model.phase == .searching)
        #expect(titles(model) == ["lisbon"])
    }

    @Test("Finding nothing finishes with nothing, instead of leaving the old results")
    func nothing() async {
        let model = model()
        model.query = "lisbon"
        await finished(model)
        model.query = "nothing"
        await finished(model)
        #expect(model.phase == .finished)
        #expect(model.results == SearchResults())
    }

    @Test("Fast typing searches once, for what was finally typed")
    func waitsForAPause() async {
        let model = model(pause: .milliseconds(300))
        for query in ["l", "li", "lis", "lisb"] {
            model.query = query
            try? await Task.sleep(for: .milliseconds(5))
        }
        await finished(model)
        #expect(searcher.log.queries == ["lisb"])
    }

    @Test("A slow search can't replace a newer one when it finally answers")
    func staleResultsLose() async {
        let model = model()
        model.query = "slow"
        for _ in 0..<400 where searcher.log.queries.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
        model.query = "fast"
        await finished(model)
        #expect(titles(model) == ["fast"])
        try? await Task.sleep(for: .milliseconds(250))
        #expect(titles(model) == ["fast"])
    }

    @Test("Setting the same words again doesn't search again")
    func sameQuery() async {
        let model = model()
        model.query = "lisbon"
        await finished(model)
        model.query = "lisbon"
        #expect(model.phase == .finished)
        #expect(searcher.log.queries == ["lisbon"])
    }
}

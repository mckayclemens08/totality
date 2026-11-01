import Foundation
import Testing
@testable import TotalityCore

private struct Plain: ContentHandler {
    let module: ModuleID
    let kinds: Set<ContentKind> = []
}

private struct Searcher: ModuleSearcher {
    let module: ModuleID
    let kinds: Set<ContentKind> = []
    var titles: [String] = []
    var fails = false

    func search(_ query: String) async throws -> [SearchHit] {
        if fails { throw CocoaError(.fileReadCorruptFile) }
        return titles.map { SearchHit(module: module, itemID: $0, title: $0) }
    }
}

@Suite("Universal search")
struct UniversalSearchTests {
    @Test("Results come back by module, in the registry's order, and a module with none is left out")
    func groups() async {
        let search = UniversalSearch(searchers: [
            Searcher(module: .reader, titles: ["Lisbon notes"]),
            Searcher(module: .photos),
            Searcher(module: .calendar, titles: ["Flight to Lisbon", "Lisbon dinner"]),
        ])
        let results = await search.run("lisbon")
        #expect(results.groups.map(\.module) == [.reader, .calendar])
        #expect(results.groups[1].hits.map(\.title) == ["Flight to Lisbon", "Lisbon dinner"])
        #expect(results.failed.isEmpty)
    }

    @Test("A module that fails is named, and the others still show")
    func failure() async {
        let search = UniversalSearch(searchers: [
            Searcher(module: .reader, fails: true),
            Searcher(module: .calendar, titles: ["Flight to Lisbon"]),
        ])
        let results = await search.run("lisbon")
        #expect(results.groups.map(\.module) == [.calendar])
        #expect(results.failed == [.reader])
    }

    @Test("Only spaces searches nothing, so a module can't fail on it")
    func blank() async {
        let results = await UniversalSearch(searchers: [Searcher(module: .reader, fails: true)]).run("   ")
        #expect(results == SearchResults())
    }

    @Test("The registry finds the modules that can be searched, in the order they registered")
    func registry() throws {
        let registry = try ModuleRegistry(handlers: [
            Searcher(module: .calendar), Plain(module: .photos), Searcher(module: .reader),
        ])
        #expect(registry.searchers.map(\.module) == [.calendar, .reader])
    }

    @Test("The same item ID in two modules is two results")
    func identity() {
        let id = UUID().uuidString
        #expect(SearchHit(module: .reader, itemID: id, title: "Lease").id != SearchHit(module: .calendar, itemID: id, title: "Lease").id)
    }
}

@Suite("Search text")
struct SearchTextTests {
    @Test("A query splits on any whitespace")
    func terms() {
        #expect(SearchText.terms(in: "  tram\tBelém\nnoon ") == ["tram", "Belém", "noon"])
        #expect(SearchText.terms(in: " \n ").isEmpty)
    }

    @Test("Finding ignores case and accents")
    func find() {
        #expect(SearchText.find("BELEM", in: "The tram to Belém") != nil)
        #expect(SearchText.find("belém", in: "The tram to BELEM") != nil)
        #expect(SearchText.find("porto", in: "The tram to Belém") == nil)
    }

    @Test("Every appearance of every word is found, for highlighting")
    func matches() {
        let text = "Café at the café, then Porto"
        let found = SearchText.matches(of: ["cafe", "porto"], in: text).map { String(text[$0]) }
        #expect(found.sorted() == ["Café", "Porto", "café"])
        #expect(SearchText.matches(of: ["lisbon"], in: text).isEmpty)
    }

    @Test("A long text is cut around the match, with marks where it was cut, on one line")
    func excerpt() throws {
        let text = String(repeating: "Before the hills\n", count: 20) + "needle" + String(repeating: " after the river", count: 20)
        let excerpt = SearchText.excerpt(of: text, around: try #require(SearchText.find("needle", in: text)))
        #expect(excerpt.hasPrefix("…"))
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.contains("needle"))
        #expect(!excerpt.contains("\n"))
        #expect(excerpt.count < 140)
    }

    @Test("A short text comes back whole, with no marks")
    func shortExcerpt() throws {
        let text = "Bring chalk and rope."
        #expect(SearchText.excerpt(of: text, around: try #require(SearchText.find("chalk", in: text))) == text)
    }
}

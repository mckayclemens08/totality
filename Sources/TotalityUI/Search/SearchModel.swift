import Foundation
import Observation
import TotalityCore

/// What the search screen shows. It lives and dies with the screen, and nothing here is written
/// anywhere, so a search leaves no trace once the screen closes.
@MainActor
@Observable
public final class SearchModel {
    public enum Phase: Sendable, Equatable {
        case waiting, searching, finished
    }

    public var query = "" {
        didSet {
            if query != oldValue { start() }
        }
    }
    public private(set) var phase = Phase.waiting
    /// Stay on screen during the next search, so results don't blink away between keystrokes.
    public private(set) var results = SearchResults()

    private let search: UniversalSearch
    private let pause: Duration
    @ObservationIgnored private var running: Task<Void, Never>?

    public init(search: UniversalSearch, pause: Duration = .milliseconds(200)) {
        self.search = search
        self.pause = pause
    }

    public var terms: [String] { SearchText.terms(in: query) }

    private func start() {
        running?.cancel()
        running = nil
        guard !terms.isEmpty else {
            results = SearchResults()
            phase = .waiting
            return
        }
        phase = .searching
        let query = query
        running = Task { [search, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            let found = await search.run(query)
            guard !Task.isCancelled else { return }
            results = found
            phase = .finished
        }
    }
}

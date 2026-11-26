import Foundation
import TotalityCore

/// The Clock's entry in the registry (issue 204, section 5). It meets other modules only here: search, its
/// cities as places for Weather, and alarms other modules ask for.
public struct ClockModule: ContentHandler {
    public let module = ModuleID.clock
    public let kinds: Set<ContentKind> = [.clockItems]
    private let book: ClockBook?
    private let maker: @Sendable (AlarmDraft) async throws -> AlarmMade

    /// `makeAlarm` sets an alarm through the Clock's screens' model, so they show it at once.
    public init(book: ClockBook?, makeAlarm: @escaping @Sendable (AlarmDraft) async throws -> AlarmMade) {
        self.book = book
        maker = makeAlarm
    }
}

extension ClockModule: ModuleSearcher {
    /// Finds a city or an alarm by name, on the device. Nothing searched for is kept or sent.
    public func search(_ query: String) async throws -> [SearchHit] {
        let terms = SearchText.terms(in: query)
        guard let book, !terms.isEmpty else { return [] }
        let items = try await book.loadItems() ?? ClockItems()
        let device = try await book.loadDevice() ?? ClockDevice()
        try Task.checkCancellation()
        return ClockSearch.hits(terms: terms, items: items, device: device)
    }
}

extension ClockModule: PlacesProvider {
    public func places() async -> [NamedPlace] {
        guard let book, let items = try? await book.loadItems() else { return [] }
        return items.shownCities.map {
            NamedPlace(id: $0.id.uuidString, name: $0.name, timeZoneID: $0.timeZoneID, module: .clock)
        }
    }
}

extension ClockModule: AlarmMaker {
    public func makeAlarm(_ draft: AlarmDraft) async throws -> AlarmMade {
        try await maker(draft)
    }
}

/// The Clock's search, apart so it can be tested without a store.
enum ClockSearch {
    static func hits(terms: [String], items: ClockItems, device: ClockDevice) -> [SearchHit] {
        func matches(_ text: String) -> Bool {
            terms.allSatisfy { SearchText.find($0, in: text) != nil }
        }
        let cities = items.shownCities.filter { matches($0.name) || matches($0.timeZoneID) }.map {
            SearchHit(module: .clock, itemID: "city:\($0.id.uuidString)", title: $0.name, detail: "World clock")
        }
        let alarms = device.alarms.filter { !$0.label.isEmpty && matches($0.label) }.map { alarm in
            SearchHit(module: .clock, itemID: "alarm:\(alarm.id.uuidString)", title: alarm.label, detail: String(format: "Alarm · %d:%02d", alarm.hour, alarm.minute))
        }
        return cities + alarms
    }
}

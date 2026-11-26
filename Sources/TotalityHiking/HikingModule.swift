import Foundation
import TotalityCore

/// Hiking's entry in the registry (issue 240, section 5). It meets other modules only here and through the
/// `PostDraft` it hands the app to share a hike. Search reads only what's sealed on this iPhone, and nothing
/// searched for is sent.
public struct HikingModule: ContentHandler, ModuleSearcher {
    public let module = ModuleID.hiking
    public let kinds: Set<ContentKind> = [.hike]
    private let log: HikeLog?
    private let units: @Sendable () -> HikeUnits

    public init(log: HikeLog?, units: @escaping @Sendable () -> HikeUnits = { HikeUnits(locale: .autoupdatingCurrent) }) {
        self.log = log
        self.units = units
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let terms = SearchText.terms(in: query)
        guard let log, !terms.isEmpty else { return [] }
        let units = units()
        var hits: [SearchHit] = []
        for hike in await log.hikes() where terms.allSatisfy({ SearchText.find($0, in: hike.title) != nil }) {
            let day = hike.startedAt.formatted(date: .abbreviated, time: .omitted)
            hits.append(SearchHit(module: .hiking, itemID: hike.id.uuidString, title: hike.title, detail: "\(units.distance(hike.metres)) · \(day)"))
        }
        try Task.checkCancellation()
        for trail in await log.savedTrails() where terms.allSatisfy({ SearchText.find($0, in: trail.name) != nil }) {
            hits.append(SearchHit(module: .hiking, itemID: trail.id, title: trail.name, detail: "Saved trail · \(units.distance(trail.metres))"))
        }
        return hits
    }
}

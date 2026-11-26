import Foundation
import Testing
import TotalityCore
@testable import TotalityHiking

/// Hiking's case of the two-user test (definition of done). Hikes have no server row in v1, so the case is
/// on the device: another account on the same iPhone, with its own key, reads none of the first one's
/// hikes, saved trails or nearby list, and can't pass its own off as theirs.
@Suite struct HikingTwoUserTests {
    @Test func anotherAccountOnTheSamePhoneSeesNothing() async throws {
        let store = MemoryBlobStore()
        let a = HikeLog(store: store, rootKey: try ContentRootKey.generate())
        let hike = Hike(title: "Timpanogos", startedAt: Date(), endedAt: Date(), seconds: 3600, segments: [walk(points: 10)])
        try await a.save(hike)
        try await a.save(Trail(id: "relation/1", name: "Timpooneke", lines: [walk(points: 4)], savedAt: Date()))
        try await a.keep(NearbyTrails(around: GeoPoint(latitude: 40.24, longitude: -111.64), fetchedAt: Date(), trails: []))

        let b = HikeLog(store: store, rootKey: try ContentRootKey.generate())
        #expect(await b.hikes().isEmpty)
        #expect(await b.savedTrails().isEmpty)
        #expect(await b.nearby() == nil)
    }

    @Test func aBlobSealedForOneHikeWontOpenAsAnother() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let log = HikeLog(store: store, rootKey: key)
        let first = Hike(title: "First", startedAt: Date(), endedAt: Date(), seconds: 1, segments: [walk(points: 3)])
        try await log.save(first)
        let name = try #require(store.all.keys.first)
        let other = UUID().uuidString.lowercased() + HikeLog.hikeSuffix
        try store.write(try #require(store.all[name]), as: other)
        // Copied under another hike's name, it opens as nothing: each hike's key and ID are bound together.
        #expect(await log.hikes() == [first])
    }
}

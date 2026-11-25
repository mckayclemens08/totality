import Foundation
import Testing
import TotalityCore
@testable import TotalityWeather

/// Weather's case of the two-user test (definition of done): user B can't read or replace user A's places
/// record. The server side of the same case is in backend-tests/two-user.test.js.
@Suite struct WeatherTwoUserTests {
    @Test func anotherPersonCantReadOrReplaceThePlaces() async throws {
        let keyA = try ContentRootKey.generate(), keyB = try ContentRootKey.generate()
        let a = WeatherPlaceBook(store: MemoryBlobStore(), rootKey: keyA), b = WeatherPlaceBook(store: MemoryBlobStore(), rootKey: keyB)
        var places = WeatherPlaces()
        places.add(provo, at: friday)
        try await a.add(places)
        let id = try #require(try await a.sealedObjectIDs().first)
        let sealed = try #require(try await a.sealedObject(id))

        // B's device is handed A's record, as a server could: it never opens it.
        await #expect(throws: (any Error).self) { try await b.store(sealed, ifLocalHash: nil) }
        #expect(await b.load().places.isEmpty)

        // B's own record, sent to A's device under A's ID, is refused too, and A's places stay.
        var theirs = WeatherPlaces()
        theirs.add(lisbon, at: friday)
        try await b.add(theirs)
        let theirID = try #require(try await b.sealedObjectIDs().first)
        let forged = try #require(try await b.sealedObject(theirID))
        let swapped = SealedObject(id: id, kind: .weatherPlaces, meta: forged.meta, body: nil)
        await #expect(throws: (any Error).self) { try await a.store(swapped, ifLocalHash: sealed.hash) }
        #expect(await a.load().places == [provo])
        #expect(id != theirID, "two people's records never meet")
    }

    @Test func anotherAccountOnTheSamePhoneSeesNoForecasts() async throws {
        let store = MemoryBlobStore()
        let a = ForecastCache(store: store, rootKey: try ContentRootKey.generate())
        try await a.write(CachedForecast(name: "Provo", forecast: sampleForecast()), for: ForecastCache.here)
        let b = ForecastCache(store: store, rootKey: try ContentRootKey.generate())
        #expect(await b.read(ForecastCache.here) == nil)
    }
}

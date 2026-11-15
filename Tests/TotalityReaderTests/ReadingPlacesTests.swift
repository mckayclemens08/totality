import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

@Suite struct ReadingPlacesTests {
    let book = UUID()
    let essay = UUID()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Two devices' places merge to the newest one for each item")
    func newestWins() {
        var phone = ReadingPlaces()
        phone.set(ReadingPlace(spot: .book(chapter: "OEBPS/ch02.xhtml", progress: 0.4), at: start.addingTimeInterval(60)), for: book)
        phone.set(ReadingPlace(spot: .pdf(page: 3), at: start), for: essay)
        var mac = ReadingPlaces()
        mac.set(ReadingPlace(spot: .book(chapter: "OEBPS/ch01.xhtml", progress: 0.9), at: start), for: book)
        mac.set(ReadingPlace(spot: .pdf(page: 7), at: start.addingTimeInterval(30)), for: essay)

        let merged = ReadingPlaces.merged(phone, mac)
        #expect(merged == ReadingPlaces.merged(mac, phone))
        #expect(merged.places[book]?.spot == .book(chapter: "OEBPS/ch02.xhtml", progress: 0.4))
        #expect(merged.places[essay]?.spot == .pdf(page: 7))
    }

    @Test("An older place never replaces a newer one")
    func olderIgnored() {
        var places = ReadingPlaces()
        places.set(ReadingPlace(spot: .pdf(page: 9), at: start.addingTimeInterval(10)), for: essay)
        places.set(ReadingPlace(spot: .pdf(page: 2), at: start), for: essay)
        #expect(places.places[essay]?.spot == .pdf(page: 9))
    }

    @Test("A deleted item's place is pruned and an older copy can't bring it back")
    func pruned() {
        var phone = ReadingPlaces()
        phone.set(ReadingPlace(spot: .doc(scroll: 0.5, cursor: 120), at: start), for: essay)
        phone.set(ReadingPlace(spot: .pdf(page: 1), at: start), for: book)
        let mac = phone
        phone.prune(keeping: [book], at: start.addingTimeInterval(5))
        #expect(phone.places[essay] == nil)
        let merged = ReadingPlaces.merged(phone, mac)
        #expect(merged.places[essay] == nil)
        #expect(merged.places[book] != nil)
        // Opening it again later counts, because that's newer.
        var again = merged
        again.set(ReadingPlace(spot: .doc(scroll: 0, cursor: 0), at: start.addingTimeInterval(9)), for: essay)
        #expect(ReadingPlaces.merged(again, mac).places[essay] != nil)
    }

    @Test("With Read along on, the file opens at Listen's place when Listen is further along")
    func listenAhead() {
        var places = ReadingPlaces()
        places.set(ReadingPlace(spot: .book(chapter: "OEBPS/ch01.xhtml", progress: 0.2), listen: 400, at: start), for: book)
        #expect(places.opening(book, listenOffset: 2_000, readAlong: true, readingOffset: 900) == .listen(2_000))
        #expect(places.opening(book, listenOffset: 2_000, readAlong: false, readingOffset: 900) == .spot(.book(chapter: "OEBPS/ch01.xhtml", progress: 0.2)))
        #expect(places.opening(book, listenOffset: 500, readAlong: true, readingOffset: 900) == .spot(.book(chapter: "OEBPS/ch01.xhtml", progress: 0.2)))
        #expect(places.opening(essay, listenOffset: nil, readAlong: true, readingOffset: nil) == nil)
    }

    @Test("The record survives a round trip, and an older record without removals still opens")
    func coding() throws {
        var places = ReadingPlaces()
        places.set(ReadingPlace(spot: .doc(scroll: 0.75, cursor: 42), listen: 10, at: start), for: essay)
        let data = try JSONEncoder().encode(places)
        #expect(try JSONDecoder().decode(ReadingPlaces.self, from: data) == places)
        #expect(try JSONDecoder().decode(ReadingPlaces.self, from: Data("{}".utf8)) == ReadingPlaces())
    }
}

/// A clock a test can move on.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

@Suite struct ReadingPlaceBookTests {
    let item = UUID()

    @Test("A new place is kept here at once, but reaches the synced record only after the hold or on going to the background")
    func held() async throws {
        let store = MemoryBlobStore()
        let clock = TestClock()
        let book = ReadingPlaceBook(store: store, rootKey: try ContentRootKey.generate(), now: { clock.now })
        try await book.remember(.pdf(page: 4), listen: 900, for: item)
        #expect(await book.place(of: item)?.spot == .pdf(page: 4))
        #expect(try await book.sealedObjectIDs().isEmpty)

        clock.advance(60)
        try await book.remember(.pdf(page: 5), listen: 1_100, for: item)
        #expect(try await book.sealedObjectIDs().isEmpty)

        clock.advance(ReadingPlaceBook.hold)
        try await book.remember(.pdf(page: 6), listen: 1_300, for: item)
        let ids = try await book.sealedObjectIDs()
        #expect(ids.count == 1)
        let object = try #require(try await book.verifiedObject(ids[0]))
        #expect(object.kind == .readerPlaces)
        #expect(object.body == nil)
        // What the server holds names no item and no page.
        #expect(object.meta.range(of: Data(item.uuidString.utf8)) == nil)
        #expect(object.meta.range(of: Data(item.uuidString.lowercased().utf8)) == nil)

        clock.advance(1)
        try await book.remember(.pdf(page: 7), listen: nil, for: item)
        try await book.publish()
        #expect(await book.place(of: item)?.spot == .pdf(page: 7))
    }

    @Test("Another device's record merges in, and a conflict keeps the newest place for each item")
    func syncs() async throws {
        let key = try ContentRootKey.generate()
        let clock = TestClock()
        let other = UUID()
        let phone = ReadingPlaceBook(store: MemoryBlobStore(), rootKey: key, now: { clock.now })
        let mac = ReadingPlaceBook(store: MemoryBlobStore(), rootKey: key, now: { clock.now })
        try await phone.remember(.book(chapter: "OEBPS/ch01.xhtml", progress: 0.3), listen: nil, for: item)
        try await phone.publish()
        clock.advance(10)
        try await mac.remember(.book(chapter: "OEBPS/ch02.xhtml", progress: 0.1), listen: nil, for: item)
        try await mac.remember(.pdf(page: 2), listen: nil, for: other)
        try await mac.publish()

        let id = try #require(try await phone.sealedObjectIDs().first)
        #expect(try await mac.sealedObjectIDs() == [id])
        let local = try #require(try await phone.sealedObject(id))
        let remote = try #require(try await mac.sealedObject(id))
        #expect(try await phone.resolveConflict(local: local, remote: remote) == .keepRemote)
        try await phone.store(remote, ifLocalHash: local.hash)
        #expect(await phone.place(of: item)?.spot == .book(chapter: "OEBPS/ch02.xhtml", progress: 0.1))
        #expect(await phone.place(of: other)?.spot == .pdf(page: 2))
    }

    @Test("A deleted item's place is dropped and goes from the synced record too")
    func forgets() async throws {
        let clock = TestClock()
        let book = ReadingPlaceBook(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate(), now: { clock.now })
        try await book.remember(.doc(scroll: 0.4, cursor: 80), listen: nil, for: item)
        try await book.publish()
        clock.advance(5)
        try await book.forget([item])
        #expect(await book.place(of: item) == nil)
        try await book.publish()
        #expect(await book.place(of: item) == nil)
    }
}

@Suite struct ReadingPlaceTwoUserTests {
    @Test("User 2 can't read user 1's places, and sync won't take user 1's record into user 2's")
    func staysPrivate() async throws {
        let item = UUID()
        let user1 = ReadingPlaceBook(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        try await user1.remember(.pdf(page: 12), listen: nil, for: item)
        try await user1.publish()
        let id = try #require(try await user1.sealedObjectIDs().first)
        let object = try #require(try await user1.sealedObject(id))

        let user2 = ReadingPlaceBook(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        // Their records never share an ID, so they never meet on the server.
        try await user2.remember(.pdf(page: 1), listen: nil, for: item)
        try await user2.publish()
        #expect(try await user2.sealedObjectIDs() != [id])
        await #expect(throws: (any Error).self) { try await user2.store(object, ifLocalHash: nil) }
        #expect(await user2.place(of: item)?.spot == .pdf(page: 1))
    }
}

@Suite struct ReadingPlaceMessageTests {
    @Test("The doc page's place message is taken only when it's well formed")
    func parse() {
        #expect(WritingMessage.parse(["type": "place", "cursor": 120, "scroll": 0.5]) == .place(cursor: 120, scroll: 0.5))
        #expect(WritingMessage.parse(["type": "place", "cursor": -1, "scroll": 0.5]) == nil)
        #expect(WritingMessage.parse(["type": "place", "cursor": 3, "scroll": 2]) == nil)
        #expect(WritingMessage.parse(["type": "place", "cursor": 3]) == nil)
    }
}

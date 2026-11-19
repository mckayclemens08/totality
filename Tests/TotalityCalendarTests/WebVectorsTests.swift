import Foundation
import Testing
import TotalityCore
@testable import TotalityCalendar

/// docs/calendar-vectors.json is made by the real CalendarVault, and the website's tests open it, so what
/// the iPhone seals is provably what the browser reads. See WebVectorsTests in the Reader's tests.
@Suite struct CalendarWebVectorsTests {
    struct Entry: Codable { let id, meta, title: String; let start, end: Double; let allDay: Bool; let repeats: String? }
    struct Vectors: Codable { let note: String; let rootKey: String; let entries: [Entry] }

    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/calendar-vectors.json")
    let key = try! ContentRootKey(bytes: Data((0..<32).map { UInt8(100 + $0) }))

    @Test func committedVectorsOpenInTheVault() async throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.path))
        let vault = CalendarVault(store: MemoryBlobs(), rootKey: key)
        for entry in vectors.entries {
            let id = try #require(UUID(uuidString: entry.id))
            try await vault.store(SealedObject(id: id, kind: .event, meta: Data(base64Encoded: entry.meta)!, body: nil), ifLocalHash: nil)
            let event = try await vault.event(id)
            #expect(event.title == entry.title)
            #expect(event.start.timeIntervalSinceReferenceDate == entry.start)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOTALITY_MAKE_VECTORS"] != nil))
    func makeVectors() async throws {
        let vault = CalendarVault(store: MemoryBlobs(), rootKey: key)
        let denver = "America/Denver"
        let monday = Date(timeIntervalSinceReferenceDate: 785_000_000) // a fixed moment, in November 2025
        let events = [
            CalendarEvent(title: "PHIL 4410", location: "Room 210", start: monday, end: monday.addingTimeInterval(3_000), timeZoneID: denver,
                          repeatRule: RepeatRule(frequency: .weekly, until: CalendarDay(year: 2026, month: 3, day: 1))),
            CalendarEvent(title: "Office hours <b>x</b>", notes: "Bring outline", start: monday.addingTimeInterval(86_400 * 2), end: monday.addingTimeInterval(86_400 * 2 + 3_600), timeZoneID: denver),
            CalendarEvent(title: "Conference", start: Date(timeIntervalSinceReferenceDate: 785_030_400), end: Date(timeIntervalSinceReferenceDate: 785_116_800),
                          isAllDay: true, timeZoneID: CalendarEvent.allDayZone),
        ]
        var entries: [Entry] = []
        for event in events {
            try await vault.save(event)
            let object = try #require(try await vault.sealedObject(event.id))
            entries.append(Entry(id: event.id.uuidString.lowercased(), meta: object.meta.base64EncodedString(), title: event.title,
                                 start: event.start.timeIntervalSinceReferenceDate, end: event.end.timeIntervalSinceReferenceDate,
                                 allDay: event.isAllDay, repeats: event.repeatRule?.frequency.rawValue))
        }
        let out = Vectors(note: "Made by CalendarWebVectorsTests.makeVectors from the real CalendarVault. Test key only.",
                          rootKey: (0..<32).map { String(format: "%02x", 100 + $0) }.joined(), entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(out).write(to: Self.path)
    }
}

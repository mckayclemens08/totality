import Foundation
import TotalityCore
@testable import TotalityTasks

final class MemoryBlobs: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    var everything: Data { lock.withLock { blobs.values.reduce(Data(), +) } }
    func corrupt(_ name: String) { lock.withLock { blobs[name]?[30] ^= 0xFF } }
}

/// A Gregorian calendar in one zone, with weeks starting on Sunday, as in the US.
func calendar(_ zone: String, locale: String = "en_US") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.locale = Locale(identifier: locale)
    calendar.firstWeekday = 1
    return calendar
}

let denver = calendar("America/Denver")

/// A moment on a zone's clock.
func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 0, in calendar: Calendar = denver) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Sunday 15 November 2026, 10am in Denver: the day the spec was agreed.
let agreed = moment(2026, 11, 15)

func day(_ year: Int, _ month: Int, _ day: Int) -> TaskDay { TaskDay(year: year, month: month, day: day) }

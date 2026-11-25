import Foundation
import TotalityCore

/// Which sound an alarm or timer rings with.
public enum ClockSound: Codable, Hashable, Sendable {
    /// iOS's own alarm sound.
    case standard
    /// One of the tones Totality makes on the device, so there's nobody's music to license.
    case tone(ClockTone)
    /// A sound the person added, by its ID in `ClockDevice.sounds`.
    case own(UUID)
}

/// The tones that come with Totality. Each is drawn from sine waves on the device the first time it's
/// needed, so they are royalty free by construction.
public enum ClockTone: String, Codable, CaseIterable, Hashable, Sendable {
    case chime, pulse, rise

    public var name: String {
        switch self {
        case .chime: "Chime"
        case .pulse: "Pulse"
        case .rise: "Rise"
        }
    }
}

/// A sound the person added. The file sits in the app's Library/Sounds folder unencrypted, because iOS
/// plays it from there; only its name is kept in the sealed record.
public struct OwnSound: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The file's name in Library/Sounds.
    public var fileName: String

    public init(id: UUID = UUID(), name: String, fileName: String) {
        self.id = id
        self.name = name
        self.fileName = fileName
    }
}

/// One alarm. Weekdays use `Calendar`'s numbers: 1 is Sunday, 7 is Saturday.
public struct ClockAlarm: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var hour: Int
    public var minute: Int
    /// iOS shows this on the Lock Screen when the alarm rings.
    public var label: String
    /// Empty means it rings once, at the next `hour:minute`, or at `date` when that's set.
    public var weekdays: Set<Int>
    /// A one-time alarm on a set day, like one made from a Calendar event.
    public var date: Date?
    public var snoozes: Bool
    public var isOn: Bool
    public var sound: ClockSound
    /// What it was made from, like the Calendar event it wakes you for.
    public var source: TaskSource?

    public init(
        id: UUID = UUID(), hour: Int, minute: Int, label: String = "", weekdays: Set<Int> = [], date: Date? = nil,
        snoozes: Bool = true, isOn: Bool = true, sound: ClockSound = .standard, source: TaskSource? = nil
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.label = label
        self.weekdays = weekdays
        self.date = date
        self.snoozes = snoozes
        self.isOn = isOn
        self.sound = sound
        self.source = source
    }

    public var repeats: Bool { !weekdays.isEmpty }
}

/// Bedtime and wake-up: a wake alarm on chosen days, and a reminder a little before bed.
public struct SleepSchedule: Codable, Hashable, Sendable {
    public var bedHour: Int
    public var bedMinute: Int
    public var wakeHour: Int
    public var wakeMinute: Int
    public var weekdays: Set<Int>
    /// How long before bedtime the reminder comes. Zero means at bedtime.
    public var remindMinutes: Int
    public var isOn: Bool
    public var sound: ClockSound

    public init(
        bedHour: Int = 22, bedMinute: Int = 30, wakeHour: Int = 6, wakeMinute: Int = 30,
        weekdays: Set<Int> = [2, 3, 4, 5, 6], remindMinutes: Int = 15, isOn: Bool = false, sound: ClockSound = .standard
    ) {
        self.bedHour = bedHour
        self.bedMinute = bedMinute
        self.wakeHour = wakeHour
        self.wakeMinute = wakeMinute
        self.weekdays = weekdays
        self.remindMinutes = remindMinutes
        self.isOn = isOn
        self.sound = sound
    }

    /// The wake-up as an alarm, under one fixed ID so it's replaced, never doubled.
    public var wakeAlarm: ClockAlarm {
        ClockAlarm(
            id: Self.wakeID, hour: wakeHour, minute: wakeMinute, label: "Wake up", weekdays: weekdays,
            snoozes: true, isOn: isOn, sound: sound
        )
    }

    /// How long in bed, in minutes.
    public var sleepMinutes: Int {
        let bed = bedHour * 60 + bedMinute
        let wake = wakeHour * 60 + wakeMinute
        return (wake - bed + 24 * 60) % (24 * 60)
    }

    public static let wakeID = UUID(uuidString: "C10C0000-0000-4000-8000-00000000BED0")!
}

/// A timer that's running or paused. It's a start time and a length, so it keeps counting with the app
/// closed.
public struct RunningTimer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var seconds: Int
    /// When the current run started. Nil while paused.
    public var startedAt: Date?
    /// Time counted before `startedAt`.
    public var banked: TimeInterval
    public var sound: ClockSound

    public init(id: UUID = UUID(), label: String, seconds: Int, startedAt: Date?, banked: TimeInterval = 0, sound: ClockSound = .standard) {
        self.id = id
        self.label = label
        self.seconds = seconds
        self.startedAt = startedAt
        self.banked = banked
        self.sound = sound
    }

    public var isPaused: Bool { startedAt == nil }

    public func elapsed(at now: Date) -> TimeInterval {
        min(TimeInterval(seconds), banked + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0))
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, TimeInterval(seconds) - elapsed(at: now))
    }

    public func progress(at now: Date) -> Double {
        seconds > 0 ? elapsed(at: now) / TimeInterval(seconds) : 1
    }

    /// When it rings, while it's running.
    public var endsAt: Date? {
        startedAt.map { $0.addingTimeInterval(TimeInterval(seconds) - banked) }
    }

    public func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }

    public mutating func pause(at now: Date) {
        guard startedAt != nil else { return }
        banked = elapsed(at: now)
        startedAt = nil
    }

    public mutating func resume(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }
}

/// What the Clock keeps on this device only, sealed and never synced: alarms, bedtime, running timers and
/// added sounds (issue 204, question 2: an alarm rings on the device that set it).
public struct ClockDevice: Codable, Equatable, Sendable {
    public var alarms: [ClockAlarm]
    public var sleep: SleepSchedule
    public var timers: [RunningTimer]
    public var sounds: [OwnSound]
    public var updatedAt: Date

    public init(alarms: [ClockAlarm] = [], sleep: SleepSchedule = SleepSchedule(), timers: [RunningTimer] = [], sounds: [OwnSound] = [], updatedAt: Date = .distantPast) {
        self.alarms = alarms
        self.sleep = sleep
        self.timers = timers
        self.sounds = sounds
        self.updatedAt = updatedAt
    }
}

/// It never syncs, but a key move can leave two copies on the device. The later one is kept whole.
extension ClockDevice: MergedRecord {
    public static func merged(_ one: ClockDevice, _ other: ClockDevice) -> ClockDevice {
        LaterWins.pick(one, other, updated: \.updatedAt)
    }
}

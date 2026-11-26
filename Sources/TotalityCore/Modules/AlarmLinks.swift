import Foundation

/// An alarm another module asks the Clock to set, like "wake me for this flight" from the Calendar or a
/// task's time from Tasks (issue 204). Nothing is set until the person presses Set in the sheet.
public struct AlarmDraft: Identifiable, Hashable, Sendable {
    public let id = UUID()
    /// The alarm's label. iOS shows it on the Lock Screen when the alarm rings.
    public var label: String
    /// When it rings, once.
    public var fireDate: Date
    /// What it came from, so the alarm can open it again. Kept inside the Clock's seal.
    public var source: TaskSource?

    public init(label: String, fireDate: Date, source: TaskSource? = nil) {
        self.label = label
        self.fireDate = fireDate
        self.source = source
    }
}

/// What the module that asked shows once the alarm is set.
public struct AlarmMade: Sendable, Hashable {
    public let id: UUID
    public let label: String
    public let fireDate: Date
    /// False when it rings as a notification, which the silent switch and Focus can mute (iOS 17 to 25).
    public let isRealAlarm: Bool

    public init(id: UUID, label: String, fireDate: Date, isRealAlarm: Bool) {
        self.id = id
        self.label = label
        self.fireDate = fireDate
        self.isRealAlarm = isRealAlarm
    }

    public var line: String {
        let time = fireDate.formatted(date: .abbreviated, time: .shortened)
        return isRealAlarm ? "Alarm set for \(time)" : "Notification set for \(time). The silent switch mutes it."
    }
}

/// The module that sets alarms for other modules. Others reach it only through `ModuleRegistry.alarmMaker`.
public protocol AlarmMaker: ContentHandler {
    /// Sets a one-time alarm on this device and says how it will ring.
    func makeAlarm(_ draft: AlarmDraft) async throws -> AlarmMade
}

extension ModuleRegistry {
    /// The module that sets alarms, if one is installed.
    public var alarmMaker: (any AlarmMaker)? {
        handlers.compactMap { $0 as? any AlarmMaker }.first
    }
}

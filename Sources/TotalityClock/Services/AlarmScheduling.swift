import Foundation

/// Whether Totality may ring alarms on this device.
public enum AlarmAccess: Sendable, Equatable {
    case notAsked, allowed, denied
}

/// How the Clock's alarms and timers ring on this device.
///
/// On iOS 26 and later that's AlarmKit: a real alarm that sounds through the silent switch and Focus and
/// fills the Lock Screen. On iOS 17 to 25 there's no AlarmKit, so they come as local notifications, which
/// the silent switch mutes, play at most 30 seconds, and Focus can hold back. The screens say which one
/// this device has, and never call a notification an alarm.
public protocol AlarmScheduling: Sendable {
    /// True for AlarmKit, false for notifications.
    var ringsAsAlarm: Bool { get }
    func access() async -> AlarmAccess
    func requestAccess() async -> AlarmAccess
    /// Sets the alarm, replacing any earlier copy of it. `sound` is a file in Library/Sounds, or nil for iOS's own.
    func schedule(_ alarm: ClockAlarm, sound: String?) async throws
    func cancelAlarm(_ id: UUID) async
    /// Starts or resumes a timer, replacing any earlier copy.
    func start(_ timer: RunningTimer, sound: String?, at now: Date) async throws
    func pause(_ timer: RunningTimer) async
    func cancelTimer(_ id: UUID) async
    /// The bedtime reminder, always a notification: it's a nudge, not an alarm. Nil clears it.
    func bedtimeReminder(_ sleep: SleepSchedule?) async
}

public enum AlarmSchedulingError: Error, Equatable {
    /// Alarm access is off in Settings.
    case notAllowed
    /// iOS's cap on what one app may set was reached.
    case full
    case failed
}

/// The scheduler this device should use: AlarmKit when iOS has it, notifications otherwise.
public enum SystemAlarms {
    public static func make() -> any AlarmScheduling {
        #if canImport(AlarmKit) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *), !ProcessInfo.processInfo.isiOSAppOnMac { return AlarmKitAlarms() }
        #endif
        return NotificationAlarms()
    }

    /// "iOS 25", for the line that says why alarms come as notifications.
    public static var systemName: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion)"
    }
}

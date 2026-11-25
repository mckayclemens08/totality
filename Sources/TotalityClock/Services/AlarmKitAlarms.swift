#if canImport(AlarmKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import AlarmKit
import Foundation
import SwiftUI
import TotalityUI

/// Nothing extra rides along with an alarm: its label is in the presentation, and everything else stays
/// in the Clock's sealed record.
struct ClockAlarmMetadata: AlarmMetadata {}

/// Real alarms and timers through AlarmKit, iOS 26 and later (issue 204, section 2). They ring like the
/// built-in Clock's: through the silent switch and Focus, on the Lock Screen and in the Dynamic Island,
/// with Stop and, when snooze is on, Snooze for 9 minutes. The schedule is held by iOS on the device and
/// never reaches Totality's server; iOS shows the label on the Lock Screen when it rings.
///
/// Timers' Lock Screen countdown is drawn by a Live Activity, which needs a widget extension this build
/// doesn't have yet. Until it does, a timer still rings through AlarmKit when it ends.
@available(iOS 26, *)
public struct AlarmKitAlarms: AlarmScheduling {
    /// Snooze is 9 minutes, fixed, like Tasks' fixed snooze (question 3).
    static let snooze: TimeInterval = 9 * 60

    private let notifications = NotificationAlarms()

    public init() {}

    public var ringsAsAlarm: Bool { true }

    public func access() async -> AlarmAccess {
        Self.access(AlarmManager.shared.authorizationState)
    }

    public func requestAccess() async -> AlarmAccess {
        guard let state = try? await AlarmManager.shared.requestAuthorization() else { return .denied }
        // Bedtime's reminder is a notification, so ask for those too, once.
        if Self.access(state) == .allowed, await notifications.access() == .notAsked { _ = await notifications.requestAccess() }
        return Self.access(state)
    }

    private static func access(_ state: AlarmManager.AuthorizationState) -> AlarmAccess {
        switch state {
        case .notDetermined: .notAsked
        case .denied: .denied
        case .authorized: .allowed
        @unknown default: .denied
        }
    }

    public func schedule(_ alarm: ClockAlarm, sound: String?) async throws {
        await cancelAlarm(alarm.id)
        guard alarm.isOn else { return }
        guard await ready() else { throw AlarmSchedulingError.notAllowed }
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        let snooze = AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: alarm.label.isEmpty ? "Alarm" : alarm.label),
            stopButton: stop,
            secondaryButton: alarm.snoozes ? snooze : nil,
            secondaryButtonBehavior: alarm.snoozes ? .countdown : nil
        )
        let attributes = AlarmAttributes<ClockAlarmMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: Theme.current.accent.color)
        let schedule: Alarm.Schedule
        if let date = alarm.date {
            schedule = .fixed(date)
        } else {
            let time = Alarm.Schedule.Relative.Time(hour: alarm.hour, minute: alarm.minute)
            let days = alarm.weekdays.sorted().compactMap(Self.weekday)
            schedule = .relative(.init(time: time, repeats: days.isEmpty ? .never : .weekly(days)))
        }
        let configuration = AlarmManager.AlarmConfiguration<ClockAlarmMetadata>(
            countdownDuration: alarm.snoozes ? Alarm.CountdownDuration(preAlert: nil, postAlert: Self.snooze) : nil,
            schedule: schedule, attributes: attributes, sound: Self.sound(sound)
        )
        try await place(alarm.id, configuration)
    }

    public func cancelAlarm(_ id: UUID) async {
        try? AlarmManager.shared.cancel(id: id)
    }

    public func start(_ timer: RunningTimer, sound: String?, at now: Date) async throws {
        let left = timer.remaining(at: now)
        // A paused AlarmKit timer resumes where it was; anything else is set afresh for what's left.
        if AlarmManager.shared.alarms.contains(where: { $0.id == timer.id && $0.state == .paused }) {
            do { try AlarmManager.shared.resume(id: timer.id); return } catch {}
        }
        await cancelTimer(timer.id)
        guard left > 0 else { return }
        guard await ready() else { throw AlarmSchedulingError.notAllowed }
        let title = LocalizedStringResource(stringLiteral: timer.label.isEmpty ? "Timer" : timer.label)
        let presentation = AlarmPresentation(
            alert: AlarmPresentation.Alert(title: title, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")),
            countdown: AlarmPresentation.Countdown(title: title, pauseButton: AlarmButton(text: "Pause", textColor: .white, systemImageName: "pause.fill")),
            paused: AlarmPresentation.Paused(title: title, resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.fill"))
        )
        let attributes = AlarmAttributes<ClockAlarmMetadata>(presentation: presentation, tintColor: Theme.current.accent.color)
        try await place(timer.id, .timer(duration: left, attributes: attributes, sound: Self.sound(sound)))
    }

    public func pause(_ timer: RunningTimer) async {
        try? AlarmManager.shared.pause(id: timer.id)
    }

    public func cancelTimer(_ id: UUID) async {
        try? AlarmManager.shared.cancel(id: id)
    }

    public func bedtimeReminder(_ sleep: SleepSchedule?) async {
        await notifications.bedtimeReminder(sleep)
    }

    // MARK: Parts

    /// Asks once, the first time an alarm is set (section 7: "Totality asks once").
    private func ready() async -> Bool {
        switch await access() {
        case .allowed: true
        case .notAsked: await requestAccess() == .allowed
        case .denied: false
        }
    }

    private func place(_ id: UUID, _ configuration: AlarmManager.AlarmConfiguration<ClockAlarmMetadata>) async throws {
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw AlarmSchedulingError.full
        } catch {
            throw AlarmSchedulingError.failed
        }
    }

    private static func sound(_ file: String?) -> AlertConfiguration.AlertSound {
        file.map { .named($0) } ?? .default
    }

    /// `Calendar`'s weekday numbers, 1 for Sunday, as AlarmKit's.
    static func weekday(_ number: Int) -> Locale.Weekday? {
        switch number {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: nil
        }
    }
}
#endif

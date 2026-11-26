import Foundation
import Testing
import UserNotifications
@testable import TotalityCore

struct CalendarAlertCoreTests {
    @Test func offsetsAreNamedTheWayThePersonSaysThem() {
        #expect(AlertOffset.name(0) == "At the start")
        #expect(AlertOffset.name(0, allDay: true) == "On the day")
        #expect(AlertOffset.name(1) == "1 minute before")
        #expect(AlertOffset.name(30) == "30 minutes before")
        #expect(AlertOffset.name(60) == "1 hour before")
        #expect(AlertOffset.name(75) == "1 hour 15 minutes before")
        #expect(AlertOffset.name(1_440) == "1 day before")
        #expect(AlertOffset.name(2_880, allDay: true) == "2 days before")
        #expect(AlertOffset.name(10_080) == "1 week before")
    }

    @Test func customAmountsAreChecked() {
        #expect(AlertOffset.custom(3, .days) == 4_320)
        #expect(AlertOffset.custom(0, .hours) == nil)
        #expect(AlertOffset.custom(5, .weeks) == nil)
        #expect(AlertOffset.custom(4, .weeks) == 40_320)
    }

    @Test func listsKeepEarliestFirstWithNoRepeatsAndAtMostFive() {
        var list: [Int] = []
        for minutes in [10, 1_440, 10, 30, 5, 60, 0] { list = AlertOffset.adding(minutes, to: list) }
        #expect(list == [1_440, 60, 30, 10, 5])
        #expect(AlertOffset.clock(9 * 60) == "9:00 AM")
        #expect(AlertOffset.clock(0) == "12:00 AM")
        #expect(AlertOffset.clock(13 * 60 + 5) == "1:05 PM")
    }

    @Test("The owner's defaults: 15 minutes for timed events, on the day for all-day, rung at 9 AM")
    func startingDefaults() {
        let settings = CalendarAlertDefaults()
        #expect(settings.defaults(allDay: false) == [15])
        #expect(settings.defaults(allDay: true) == [0])
        #expect(settings.allDayMinute == 540)
    }

    @Test("Choices saved before Calendar defaults existed still load, and keep what they had")
    func olderChoicesStillLoad() throws {
        var old = NotificationPreferences()
        old.quietHoursOn = true
        old.quietStart = 23 * 60
        old.modulesOff = [.mail]
        let encoded = try JSONEncoder().encode(old)
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["calendarAlerts"] = nil
        let loaded = try JSONDecoder().decode(NotificationPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.quietHoursOn && loaded.quietStart == 23 * 60 && loaded.modulesOff == [.mail])
        #expect(loaded.calendarAlerts == CalendarAlertDefaults())
    }

    @Test func calendarDefaultsAreSavedWithTheOtherChoices() throws {
        var prefs = NotificationPreferences()
        prefs.calendarAlerts.timed = [30, 5]
        prefs.calendarAlerts.allDayMinute = 8 * 60
        let back = try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back == prefs)
    }

    @Test func snoozeAndOpenAreLockScreenButtons() {
        #expect(NotificationAction.snoozeTen.title == "Snooze 10 min")
        #expect(NotificationAction(identifier: NotificationAction.open.identifier) == .open)
        #expect(!NotificationAction.snoozeTen.needsUnlock && !NotificationAction.open.needsUnlock)
        #expect(PlannedAlert.categories.contains([.snoozeTen, .open]))
        #expect(PlannedAlert.category(for: [.snoozeTen, .open]) == "totality.snoozeTen+open")
    }

    @Test("Snooze rings the same alert again in ten minutes, under an ID of its own")
    func snoozeMakesTheSameAlertAgain() throws {
        let content = UNMutableNotificationContent()
        content.title = "Dentist"
        content.body = "Dec 3 at 2:00 PM"
        content.categoryIdentifier = "totality.snoozeTen+open"
        content.userInfo = NotificationTarget(module: .calendar, kind: "event", item: "abc-1").userInfo
        let request = UNNotificationRequest(identifier: "calendar.abc.1.30", content: content, trigger: nil)
        let again = NotificationHub.snoozed(request, minutes: AlertOffset.snoozeMinutes)
        #expect(again.identifier != request.identifier)
        #expect(!again.identifier.hasPrefix("calendar."))
        #expect(again.content.title == "Dentist" && again.content.body == "Dec 3 at 2:00 PM")
        #expect(again.content.categoryIdentifier == "totality.snoozeTen+open")
        #expect(NotificationTarget(userInfo: again.content.userInfo)?.item == "abc-1")
        let trigger = try #require(again.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 600 && !trigger.repeats)
    }

    @MainActor @Test func eventAlertsHaveTheirOwnSwitch() {
        var prefs = NotificationPreferences()
        let kind = NotificationHub.reminderKinds[1]
        #expect(kind.module == .calendar && kind.name == "Event alerts")
        #expect(prefs.isOn(kind))
        prefs.set(kind, on: false)
        #expect(!prefs.isOn(kind))
    }
}

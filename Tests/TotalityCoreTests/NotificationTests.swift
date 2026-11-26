import Foundation
import Testing
@testable import TotalityCore

private let like = NotificationKind(module: .social, key: "like", name: "Likes", detail: "")
private let noisy = NotificationKind(module: .social, key: "friendsPost", name: "Friends posts", detail: "", startsOn: false)

private func note(_ id: String, kind: NotificationKind = like, isPrivate: Bool = false, closeFriend: Bool = false) -> AppNotification {
    AppNotification(
        id: id, kind: kind, title: "@jonah_r liked your post", body: "First frost", isPrivate: isPrivate, thread: "p1",
        target: NotificationTarget(module: .social, kind: "post", item: "p1"), fromCloseFriend: closeFriend, date: Date()
    )
}

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: hour, minute: minute))!
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

struct NotificationPreferencesTests {
    @Test func kindsStartWhereTheySayAndFlip() {
        var prefs = NotificationPreferences()
        #expect(prefs.isOn(like) && !prefs.isOn(noisy))
        prefs.set(like, on: false)
        prefs.set(noisy, on: true)
        #expect(!prefs.isOn(like) && prefs.isOn(noisy))
        prefs.set(.social, on: false)
        #expect(!prefs.isOn(noisy))
    }

    @Test func quietHoursRunPastMidnight() {
        var prefs = NotificationPreferences()
        prefs.quietHoursOn = true
        #expect(prefs.isQuiet(at: at(23), in: utc) && prefs.isQuiet(at: at(6, 59), in: utc))
        #expect(!prefs.isQuiet(at: at(7), in: utc) && !prefs.isQuiet(at: at(12), in: utc))
        prefs.quietStart = 13 * 60
        prefs.quietEnd = 14 * 60
        #expect(prefs.isQuiet(at: at(13, 30), in: utc) && !prefs.isQuiet(at: at(23), in: utc))
    }

    @Test func planAppliesQuietGroupingAndPreviews() throws {
        var prefs = NotificationPreferences()
        prefs.quietHoursOn = true
        prefs.showsPrivateText = false
        let quiet = try #require(PlannedAlert.plan(note("a", isPrivate: true), preferences: prefs, now: at(23), calendar: utc))
        #expect(quiet.isQuiet && quiet.body.isEmpty && quiet.thread == "social")
        #expect(quiet.userInfo["totality.item"] == "p1" && quiet.category == "totality.open")
        prefs.closeFriendsBreakThrough = true
        prefs.grouping = .thread
        let loud = try #require(PlannedAlert.plan(note("b", closeFriend: true), preferences: prefs, now: at(23), calendar: utc))
        #expect(!loud.isQuiet && loud.body == "First frost" && loud.thread == "social.p1")
        prefs.set(like, on: false)
        #expect(PlannedAlert.plan(note("c"), preferences: prefs, now: at(12), calendar: utc) == nil)
    }

    @Test func targetsAndActionsRoundTrip() {
        let target = NotificationTarget(module: .messages, kind: "chat", item: "!room:usetotality.com")
        #expect(NotificationTarget(userInfo: target.userInfo) == target)
        for action in NotificationAction.allCases { #expect(NotificationAction(identifier: action.identifier) == action) }
        #expect(PlannedAlert.category(for: [.reply, .markRead]) == "totality.reply+markRead")
    }
}

@MainActor
private final class FakePoster: AlertPoster {
    var posted: [PlannedAlert] = []
    var badge = -1
    func post(_ alert: PlannedAlert) async { posted.append(alert) }
    func setBadge(_ count: Int) async { badge = count }
}

@MainActor
private final class FakeSource: NotificationSource {
    let module = ModuleID.social
    let kinds = [like, noisy]
    var next: [AppNotification] = []
    var opened: NotificationTarget?
    var performed: [(NotificationAction, String?)] = []
    func newNotifications() async -> [AppNotification] { defer { next = [] }; return next }
    func badgeCount() -> Int { 3 }
    func prepareToOpen(_ target: NotificationTarget) { opened = target }
    func perform(_ action: NotificationAction, on target: NotificationTarget, text: String?) async { performed.append((action, text)) }
}

@MainActor
struct NotificationHubTests {
    private func hub() -> (NotificationHub, FakePoster, FakeSource) {
        let defaults = UserDefaults(suiteName: "hub." + UUID().uuidString)!
        let poster = FakePoster()
        let hub = NotificationHub(store: NotificationSettingsStore(defaults: defaults), seen: SeenAlerts(defaults: defaults), poster: poster)
        let source = FakeSource()
        hub.register(source)
        return (hub, poster, source)
    }

    @Test func postsOnceAndCountsBadges() async {
        let (hub, poster, source) = hub()
        source.next = [note("x"), note("y")]
        #expect(await hub.collect() == 2)
        source.next = [note("x")]
        #expect(await hub.collect() == 0)
        #expect(poster.posted.map(\.identifier) == ["totality.x", "totality.y"] && poster.badge == 3)
        hub.preferences.setBadges(.social, on: false)
        await hub.updateBadge()
        #expect(poster.badge == 0)
    }

    @Test func inFrontMarksSeenWithoutPosting() async {
        let (hub, poster, source) = hub()
        hub.isInFront = { true }
        source.next = [note("z")]
        #expect(await hub.collect() == 0)
        hub.isInFront = { false }
        source.next = [note("z")]
        #expect(await hub.collect() == 0 && poster.posted.isEmpty)
    }

    @Test func tapsOpenAndButtonsAct() async {
        let (hub, _, source) = hub()
        let target = NotificationTarget(module: .social, kind: "profile", item: "sam")
        await hub.respond(to: target, action: nil, text: nil)
        #expect(source.opened == target && hub.requestedModule == .social)
        await hub.respond(to: target, action: .approve, text: nil)
        #expect(source.performed.map(\.0) == [.approve])
        hub.requestedModule = nil
        await hub.respond(to: NotificationTarget(module: .mail, kind: "conversation", item: "1"), action: nil, text: nil)
        #expect(hub.requestedModule == .mail)
    }

    @Test func kindsIncludeReminders() {
        let (hub, _, _) = hub()
        #expect(hub.kinds.map(\.id) == ["social.like", "social.friendsPost", "tasks.reminder", "calendar.reminder"])
    }
}

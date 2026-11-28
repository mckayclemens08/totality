import Foundation
import Observation
import UserNotifications

/// Where alerts are posted. iOS in the app, a list in tests.
@MainActor
public protocol AlertPoster: AnyObject {
    func post(_ alert: PlannedAlert) async
    func setBadge(_ count: Int) async
}

/// The one notifications system (issue 232). Each module's adapter plugs in as a `NotificationSource`.
/// When a silent push or a refresh wakes the app, the hub asks every source what's new, applies the
/// Notifications page's choices, and posts the alerts itself. The words are written here, on the phone:
/// the push that woke it said nothing at all.
///
/// It is also the one delegate iOS tells about taps and lock-screen buttons. Anything that isn't its own
/// (Tasks' reminders, which came first) goes on to `fallback` unchanged.
@MainActor
@Observable
public final class NotificationHub: NSObject {
    public static let shared = NotificationHub()

    /// Alerts for kinds no source registers, because their module schedules them itself on the device:
    /// Tasks' and Calendar's reminders. They still get a switch.
    public static let reminderKinds = [
        NotificationKind(module: .tasks, key: "reminder", name: "Reminders", detail: "Done or snooze from the lock screen"),
        NotificationKind(module: .calendar, key: "reminder", name: "Event alerts", detail: "Before each event, as you set it"),
    ]

    public private(set) var sources: [ModuleID: any NotificationSource] = [:]
    /// The Notifications page's choices, read from and saved to this device.
    public var preferences: NotificationPreferences {
        didSet { if preferences != oldValue { store.current = preferences } }
    }
    /// A module an alert's tap asked for, waiting for the app to bring it up.
    public var requestedModule: ModuleID?
    /// Whether Totality is on screen. Then the modules are already showing what's new, so nothing is posted.
    @ObservationIgnored public var isInFront: @MainActor () -> Bool = { false }
    @ObservationIgnored public nonisolated(unsafe) var fallback: (any UNUserNotificationCenterDelegate)?

    @ObservationIgnored private let store: NotificationSettingsStore
    @ObservationIgnored private let seen: SeenAlerts
    @ObservationIgnored private var poster: (any AlertPoster)?
    @ObservationIgnored private var collecting: Task<Int, Never>?
    @ObservationIgnored private var pendingTargets: [ModuleID: NotificationTarget] = [:]
    @ObservationIgnored private var pendingActions: [(NotificationTarget, NotificationAction, String?)] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private let clock: @Sendable () -> Date

    public init(
        store: NotificationSettingsStore = .shared, seen: SeenAlerts = SeenAlerts(), poster: (any AlertPoster)? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.seen = seen
        self.poster = poster
        self.clock = clock
        preferences = store.current
        super.init()
    }

    /// Every kind with a switch, in the order the page lists modules.
    public var kinds: [NotificationKind] {
        let order: [ModuleID] = [.social, .messages, .mail, .tasks, .calendar]
        let all = sources.values.flatMap(\.kinds) + Self.reminderKinds
        return all.sorted { (order.firstIndex(of: $0.module) ?? 99, $0.module.rawValue) < (order.firstIndex(of: $1.module) ?? 99, $1.module.rawValue) }
    }

    /// A module joins, replacing any adapter it had before (a new account, say).
    public func register(_ source: any NotificationSource) {
        sources[source.module] = source
        if let target = pendingTargets.removeValue(forKey: source.module) {
            source.prepareToOpen(target)
        }
        let queued = pendingActions.filter { $0.0.module == source.module }
        if !queued.isEmpty {
            pendingActions.removeAll { $0.0.module == source.module }
            Task { @MainActor in
                for (target, action, text) in queued {
                    await source.perform(action, on: target, text: text)
                }
                await updateBadge()
            }
        }
    }

    public func unregister(_ module: ModuleID) {
        sources[module] = nil
    }

    /// Whether this kind may ring, for modules that schedule their own reminders.
    public func allows(_ kind: NotificationKind) -> Bool { preferences.isOn(kind) }

    /// Asks every source what's new and posts it. Asking while a round is running waits for that one.
    /// Returns how many alerts were posted.
    @discardableResult
    public func collect() async -> Int {
        if let collecting { return await collecting.value }
        let task = Task { @MainActor in await self.round() }
        collecting = task
        let posted = await task.value
        collecting = nil
        return posted
    }

    private func round() async -> Int {
        let poster = poster ?? SystemAlertPoster.shared
        var posted = 0
        for source in sources.values.sorted(by: { $0.module.rawValue < $1.module.rawValue }) {
            let notes = await source.newNotifications()
            // Fetched even in front, so what's seen there isn't alerted later.
            guard !isInFront() else {
                seen.add(notes.map(\.id))
                continue
            }
            for note in notes.sorted(by: { $0.date < $1.date }) where !seen.contains(note.id) {
                seen.add([note.id])
                guard let alert = PlannedAlert.plan(note, preferences: preferences, now: clock()) else { continue }
                await poster.post(alert)
                posted += 1
            }
        }
        await updateBadge(poster)
        return posted
    }

    /// The icon's badge: what each module with badges on says is waiting.
    public func updateBadge(_ poster: (any AlertPoster)? = nil) async {
        let count = sources.values.filter { preferences.badges($0.module) }.reduce(0) { $0 + max(0, $1.badgeCount()) }
        await (poster ?? self.poster ?? SystemAlertPoster.shared).setBadge(count)
    }

    /// A tap or a button on one of the hub's alerts.
    public func respond(to target: NotificationTarget, action: NotificationAction?, text: String?) async {
        guard let source = sources[target.module] else {
            // Content hasn't opened yet: remember the target so the module opens straight to it once registered.
            if let action {
                pendingActions.append((target, action, text))
            } else {
                pendingTargets[target.module] = target
                requestedModule = target.module
            }
            return
        }
        if let action {
            await source.perform(action, on: target, text: text)
            await updateBadge()
        } else {
            pendingTargets[target.module] = nil
            source.prepareToOpen(target)
            requestedModule = target.module
        }
    }

    // MARK: iOS

    /// Call once at launch, after anything else that sets notification categories, so a tap that opened
    /// the app is handled.
    public func start() {
        let center = UNUserNotificationCenter.current()
        if fallback == nil, let current = center.delegate, !(current is NotificationHub) { fallback = current }
        center.delegate = self
        guard !started else { return }
        started = true
        Task {
            let existing = await center.notificationCategories()
            let ours = Set(PlannedAlert.categories.map(Self.category))
            let kept = existing.filter { !$0.identifier.hasPrefix("totality.") }
            center.setNotificationCategories(kept.union(ours))
        }
    }

    /// Asks iOS for permission the first time. It does nothing once the person has answered.
    public func askPermission() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    nonisolated static func category(_ actions: [NotificationAction]) -> UNNotificationCategory {
        let buttons: [UNNotificationAction] = actions.map { action in
            var options: UNNotificationActionOptions = action.needsUnlock ? [.authenticationRequired] : []
            if action == .open { options.insert(.foreground) }
            if action == .reply {
                return UNTextInputNotificationAction(
                    identifier: action.identifier, title: action.title, options: options,
                    textInputButtonTitle: "Send", textInputPlaceholder: "Message"
                )
            }
            return UNNotificationAction(identifier: action.identifier, title: action.title, options: options)
        }
        return UNNotificationCategory(identifier: PlannedAlert.category(for: actions), actions: buttons, intentIdentifiers: [], options: [])
    }
}

private final class NotificationCenterBox: @unchecked Sendable {
    let center: UNUserNotificationCenter
    let request: UNNotificationRequest
    init(_ center: UNUserNotificationCenter, _ request: UNNotificationRequest) {
        self.center = center
        self.request = request
    }
}

extension NotificationHub: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        // Tasks' reminders, the only others, show the same way.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let content = response.notification.request.content
        guard content.categoryIdentifier.hasPrefix("totality."), let target = NotificationTarget(userInfo: content.userInfo) else {
            let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
            if let fallback, fallback.responds(to: selector) {
                fallback.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            } else {
                completionHandler()
            }
            return
        }
        let identifier = response.notification.request.identifier
        var action = NotificationAction(identifier: response.actionIdentifier)
        if action == .snoozeTen {
            // Done right here: the words are already in the alert, so it works with Calendar still sealed.
            let box = NotificationCenterBox(center, response.notification.request)
            Task { @MainActor in
                let again = Self.snoozed(box.request, minutes: AlertOffset.snoozeMinutes)
                try? await box.center.add(again)
                box.center.removeDeliveredNotifications(withIdentifiers: [identifier])
                completionHandler()
            }
            return
        }
        // The Open button is a tap that was asked for by name.
        if action == .open { action = nil }
        let resolvedAction = action
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            await self.respond(to: target, action: resolvedAction, text: text)
            // A button finished the job, so the alert leaves the lock screen.
            if resolvedAction != nil {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            }
            completionHandler()
        }
    }
}

extension NotificationHub {
    /// The same alert again after `minutes`. Its identifier is its own, so a Calendar refresh that replaces
    /// the planned alerts can't remove it.
    nonisolated static func snoozed(_ request: UNNotificationRequest, minutes: Int) -> UNNotificationRequest {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        return UNNotificationRequest(
            identifier: "totality.snooze." + UUID().uuidString.lowercased(), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(max(1, minutes)) * 60, repeats: false)
        )
    }

    /// Hands an alert that isn't the hub's to the delegate that was there before, through the call iOS
    /// itself would have made.
    nonisolated func forward(_ center: UNUserNotificationCenter, _ response: UNNotificationResponse) {
        fallback?.userNotificationCenter?(center, didReceive: response, withCompletionHandler: {})
    }
}

/// Posts to iOS.
@MainActor
final class SystemAlertPoster: AlertPoster {
    static let shared = SystemAlertPoster()

    func post(_ alert: PlannedAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.threadIdentifier = alert.thread
        content.categoryIdentifier = alert.category
        content.userInfo = alert.userInfo
        if alert.isQuiet {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// The alerts already posted, so the same event never rings twice. IDs only, the newest few hundred.
public final class SeenAlerts: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let most: Int
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "notifications.seen", most: Int = 500) {
        self.defaults = defaults
        self.key = key
        self.most = most
    }

    public func contains(_ id: String) -> Bool {
        lock.withLock { (defaults.stringArray(forKey: key) ?? []).contains(id) }
    }

    public func add(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            var all = defaults.stringArray(forKey: key) ?? []
            for id in ids where !all.contains(id) { all.append(id) }
            defaults.set(Array(all.suffix(most)), forKey: key)
        }
    }
}

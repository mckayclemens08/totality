import CoreLocation
import Foundation
import TotalityCore
import UserNotifications

/// Tasks' reminders on this iPhone: local notifications and Core Location region monitoring. There's no
/// push, so everything is set on the device and rings with no signal. Where the person is never leaves
/// the iPhone: iOS watches the regions, and Totality only hears "entered" or "left".
public final class SystemTaskReminders: NSObject, TaskReminderScheduling, @unchecked Sendable {
    public static let shared = SystemTaskReminders()

    /// iOS's cap on pending notifications for the whole app.
    static let systemLimit = 64

    private let manager: CLLocationManager
    private let lock = NSLock()
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    /// The words each watched place rings with. iOS may wake the app for a region with Tasks still sealed,
    /// so these are kept on the device, like a pending notification is, and never synced.
    private let placesFile: URL?

    override private init() {
        manager = CLLocationManager()
        placesFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TaskPlaceReminders.json")
        super.init()
        manager.delegate = self
    }

    /// Call once at launch, so a notification action or a region event that wakes the app is handled.
    public func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let complete = UNNotificationAction(identifier: ReminderAction.completeID, title: "Complete", options: [])
        let snoozes = ReminderAction.Snooze.allCases.map { UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: []) }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ReminderAction.category, actions: [complete] + snoozes, intentIdentifiers: [], options: []),
        ])
    }

    // MARK: - TaskReminderScheduling

    public func replace(with notifications: [PlannedTaskNotification], places: [PlannedPlace]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(TaskReminderPlanner.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        // Calendar's reminders share iOS's 64; Tasks takes what they leave. None at all while the
        // Notifications page has Tasks' reminders switched off (issue 232).
        let allowed = await MainActor.run { NotificationHub.shared.allows(NotificationHub.reminderKinds[0]) }
        let room = allowed ? max(0, Self.systemLimit - (pending.count - ours.count)) : 0
        for planned in notifications.prefix(room) {
            try? await center.add(Self.request(id: planned.id, taskID: planned.taskID, title: planned.title, body: planned.body, at: planned.fireDate))
        }
        // A finished or edited task's notification shouldn't stay on the lock screen.
        let live = Set(notifications.map(\.taskID))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter {
            guard let id = TaskReminderPlanner.taskID(in: $0) else { return false }
            return !live.contains(id) && !places.contains { $0.taskID == id } && $0.hasPrefix(TaskReminderPlanner.prefix)
        })
        watch(places)
    }

    public func access() async -> ReminderAccess {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let notifications: ReminderAccess.Notifications = switch settings.authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .denied
        default: .allowed
        }
        return ReminderAccess(notifications: notifications, location: locationAccess)
    }

    public func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    public func requestAlwaysLocation() async {
        #if os(iOS)
        if manager.authorizationStatus == .authorizedWhenInUse {
            // iOS shows the step up to Always once at most, and may say nothing back, so don't wait.
            manager.requestAlwaysAuthorization()
            return
        }
        #endif
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { authorizationWaiters.append(continuation) }
            manager.requestAlwaysAuthorization()
        }
    }

    private var locationAccess: ReminderAccess.Location {
        switch manager.authorizationStatus {
        case .notDetermined: .notAsked
        case .authorizedAlways: .always
        #if os(iOS)
        case .authorizedWhenInUse: .whileUsing
        #endif
        default: .denied
        }
    }

    // MARK: - Places

    private func watch(_ places: [PlannedPlace]) {
        let wanted = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for region in manager.monitoredRegions where region.identifier.hasPrefix(TaskReminderPlanner.prefix) {
            if let place = wanted[region.identifier], let circle = region as? CLCircularRegion, Self.matches(circle, place.place) { continue }
            manager.stopMonitoring(for: region)
        }
        saveWords(places)
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let watched = Set(manager.monitoredRegions.map(\.identifier))
        for place in places where !watched.contains(place.id) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: place.place.latitude, longitude: place.place.longitude),
                radius: min(place.place.radius, manager.maximumRegionMonitoringDistance), identifier: place.id
            )
            region.notifyOnEntry = place.place.onArrival
            region.notifyOnExit = !place.place.onArrival
            manager.startMonitoring(for: region)
        }
    }

    private static func matches(_ region: CLCircularRegion, _ place: ReminderPlace) -> Bool {
        abs(region.center.latitude - place.latitude) < 1e-6 && abs(region.center.longitude - place.longitude) < 1e-6
            && abs(region.radius - place.radius) < 1 && region.notifyOnEntry == place.onArrival
    }

    private struct Words: Codable {
        let taskID: UUID
        let title: String
        let body: String
    }

    private func saveWords(_ places: [PlannedPlace]) {
        guard let placesFile else { return }
        let words = Dictionary(places.map { ($0.id, Words(taskID: $0.taskID, title: $0.title, body: $0.body)) }, uniquingKeysWith: { a, _ in a })
        if words.isEmpty {
            try? FileManager.default.removeItem(at: placesFile)
            return
        }
        try? FileManager.default.createDirectory(at: placesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? JSONEncoder().encode(words).write(to: placesFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? JSONEncoder().encode(words).write(to: placesFile, options: .atomic)
        #endif
    }

    private func words(for identifier: String) -> Words? {
        guard let placesFile, let data = try? Data(contentsOf: placesFile) else { return nil }
        return (try? JSONDecoder().decode([String: Words].self, from: data))?[identifier]
    }

    private func ring(_ region: CLRegion) {
        guard region.identifier.hasPrefix(TaskReminderPlanner.prefix), let words = words(for: region.identifier) else { return }
        let request = Self.request(
            id: TaskReminderPlanner.notificationID(words.taskID, Date()), taskID: words.taskID,
            title: words.title, body: words.body, at: nil
        )
        Task { @MainActor in
            guard NotificationHub.shared.allows(NotificationHub.reminderKinds[0]) else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Notifications

    static func request(id: String, taskID: UUID, title: String, body: String, at date: Date?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = ReminderAction.category
        content.threadIdentifier = "tasks"
        content.userInfo = ["task": taskID.uuidString]
        let trigger = date.map {
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0), repeats: false
            )
        }
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    /// Takes every notification of one task off the iPhone, waiting and shown.
    private static func clear(_ taskID: UUID) async {
        let center = UNUserNotificationCenter.current()
        let prefix = TaskReminderPlanner.prefix + taskID.uuidString.lowercased() + "."
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let shown = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(prefix) }
        center.removeDeliveredNotifications(withIdentifiers: shown)
    }

    /// Called with each action as it happens, once Tasks is open. Until then actions wait in the queue.
    @MainActor public var onAction: (@Sendable @MainActor (ReminderAction) async -> Void)?
}

extension SystemTaskReminders: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content
        guard info.categoryIdentifier == ReminderAction.category,
              let raw = info.userInfo["task"] as? String, let taskID = UUID(uuidString: raw)
        else { return }
        let now = Date()
        let action: ReminderAction
        if response.actionIdentifier == ReminderAction.completeID {
            // Nagging stops the moment it's ticked off, before Tasks has even opened.
            await Self.clear(taskID)
            action = ReminderAction(taskID: taskID, kind: .complete, at: now)
        } else if let snooze = ReminderAction.Snooze(rawValue: response.actionIdentifier) {
            let until = snooze.until(from: now, in: .autoupdatingCurrent)
            await Self.clear(taskID)
            try? await center.add(Self.request(
                id: TaskReminderPlanner.notificationID(taskID, until), taskID: taskID, title: info.title, body: info.body, at: until
            ))
            action = ReminderAction(taskID: taskID, kind: .snooze(until: until), at: now)
        } else {
            return
        }
        ReminderActionQueue.shared.add(action)
        if let handle = await MainActor.run(body: { onAction }) { await handle(action) }
    }
}

extension SystemTaskReminders: CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let waiters = lock.withLock {
            defer { authorizationWaiters.removeAll() }
            return authorizationWaiters
        }
        waiters.forEach { $0.resume() }
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        ring(region)
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        ring(region)
    }
}

import Foundation

/// Tells the person about a new severe alert for one of their places. It's a notification made on the
/// iPhone itself when Weather refreshes, so no server learns where the person or their places are.
public protocol WeatherAlertNotifying: Sendable {
    /// Asks the system once, when the person turns alerts on. True if they may show.
    func requestPermission() async -> Bool
    func notify(title: String, body: String, id: String) async
}

/// Which alerts have been announced already, kept as short hashes so the list says nothing about any place.
public struct AnnouncedAlerts: Sendable {
    public static let defaultsKey = "weather.announcedAlerts"
    /// Only severe and extreme alerts ring; the rest show in the app.
    public static let threshold = WeatherAlert.Severity.severe

    /// The alerts to announce now: severe enough, not over, and not announced before.
    public static func toAnnounce(_ alerts: [(place: String, alert: WeatherAlert)], seen: Set<String>, at date: Date) -> [(place: String, alert: WeatherAlert)] {
        var picked = Set<String>()
        return alerts.filter { item in
            let mark = Self.mark(item.alert.id)
            guard item.alert.severity >= threshold, (item.alert.ends ?? .distantFuture) > date,
                  !seen.contains(mark), picked.insert(mark).inserted else { return false }
            return true
        }
    }

    /// A short hash of an alert's ID: the same alert always gives the same mark.
    public static func mark(_ id: String) -> String {
        // FNV-1a, 64 bits. Enough to tell alerts apart; it isn't a secret.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

#if canImport(UserNotifications)
import UserNotifications

public struct SystemWeatherAlertNotices: WeatherAlertNotifying {
    public init() {}

    public func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func notify(title: String, body: String, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "weather-alerts"
        let request = UNNotificationRequest(identifier: "weather-alert-\(AnnouncedAlerts.mark(id))", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif

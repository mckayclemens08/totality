#if os(iOS)
import SwiftUI
import TotalityCore
import TotalityMail
import UIKit
import UserNotifications

/// Instant Gmail sync on the app's side (issue 164). It registers this phone's Apple push token with
/// Totality's push service, keeps each Gmail watch going, and when an empty push says an inbox changed,
/// fetches from Gmail and posts the notification itself. The server never sees what it says.
@MainActor
final class PushSetup {
    static let shared = PushSetup()

    /// Fetches mail for a push and returns what to notify. Set once content opens.
    var onWake: (@MainActor () async -> [NewMailNote])?
    /// Keeps the Gmail watches going. Set once content opens.
    var keepWatching: (@MainActor () async -> Void)?

    /// The Pub/Sub topic this build's Gmail watches post to. Empty until the owner sets it up, and then
    /// instant sync stays off.
    static var topic: String? { Bundle.main.object(forInfoDictionaryKey: "TotalityGmailPushTopic") as? String }

    static func plan() -> GmailPushPlan? {
        guard let token = AccountSetup.searchToken else { return nil }
        return GmailPushPlan(topic: topic, push: PushClient(token: token))
    }

    /// Asks Apple for this phone's push token. iOS answers through the app delegate.
    func start() {
        guard Self.plan() != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func registered(_ device: Data) {
        guard let signIn = AccountSetup.searchToken else { return }
        let push = PushClient(token: signIn)
        Task { try? await push.register(device: device, sandbox: PushClient.isSandbox) }
    }

    /// The watches renew, and notifications are asked for the first time there's something to show.
    func renew() async {
        guard GmailPushSettings.shared.isOn, Self.plan() != nil else {
            await keepWatching?()
            return
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await keepWatching?()
    }

    /// One push. iOS gives about 30 seconds, so this fetches, notifies, and says whether anything came.
    func woke() async -> UIBackgroundFetchResult {
        guard GmailPushSettings.shared.isOn, let onWake else { return .noData }
        let notes = await onWake()
        await keepWatching?()
        // In front, Mail is already showing it.
        guard UIApplication.shared.applicationState != .active else { return notes.isEmpty ? .noData : .newData }
        for note in notes {
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            content.sound = .default
            content.threadIdentifier = "mail." + note.conversationID.uuidString
            let request = UNNotificationRequest(identifier: "mail." + note.id.uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
        return notes.isEmpty ? .noData : .newData
    }
}

/// The parts of instant sync iOS hands to an app delegate.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushSetup.shared.registered(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await PushSetup.shared.woke()
    }
}
#endif

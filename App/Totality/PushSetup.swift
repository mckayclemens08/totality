#if os(iOS)
import SwiftUI
import TotalityCore
import TotalityMail
import UIKit
import UserNotifications

/// Push on the app's side (issues 164 and 232). It registers this phone's Apple push token with Totality's
/// push service and as the Matrix homeserver's pusher, and keeps each Gmail watch going. When an empty push
/// wakes the phone, `NotificationHub` asks every module what's new and posts the alerts itself. The server
/// never sees what they say.
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

    /// This phone's Apple push token, once iOS has given it. The Matrix pusher is set from it.
    static var device: Data? {
        get { UserDefaults.standard.data(forKey: "push.device") }
        set { UserDefaults.standard.set(newValue, forKey: "push.device") }
    }

    /// Asks Apple for this phone's push token. iOS answers through the app delegate. Every signed-in phone
    /// registers, for Messages and Social as well as Gmail.
    func start() {
        guard AccountSetup.searchToken != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func registered(_ device: Data) {
        guard let signIn = AccountSetup.searchToken else { return }
        Self.device = device
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

    /// One push. iOS gives about 30 seconds, so every module fetches what's new and the hub posts it.
    /// Mail's part fetches from Gmail through `onWake`.
    func woke() async -> UIBackgroundFetchResult {
        let posted = await NotificationHub.shared.collect()
        if GmailPushSettings.shared.isOn { await keepWatching?() }
        return posted > 0 ? .newData : .noData
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

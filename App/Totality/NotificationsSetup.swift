#if os(iOS)
import Foundation
import TotalityCalendar
import TotalityCore
import TotalityMail
import TotalityMessages
import TotalitySocial
import UIKit

/// Plugs each module's notifications into `NotificationHub` (issue 232). It lives in the app, which may
/// import every module, so the modules never import each other.
@MainActor
enum NotificationsSetup {
    /// Once content opens: Messages and Mail join, the hub collects on the refresh beat, and iOS is asked
    /// for permission the first time.
    static func connect(messages: MessagesModel, mail: MailAccountModel) {
        let hub = NotificationHub.shared
        hub.isInFront = { UIApplication.shared.applicationState == .active }
        let messagesSource = MessagesNotifications(model: messages)
        messagesSource.primeCursorIfNeeded()
        hub.register(messagesSource)
        hub.register(MailNotifications(mail: mail))
        AppRefresh.shared.extras["notifications"] = { await NotificationHub.shared.collect() }
        Task { await hub.askPermission() }
    }

    /// Calendar joins so a tap on one of its alerts opens that event. Its alerts are planned on the phone
    /// by the Calendar itself, so it has nothing to fetch.
    static func connect(calendar: CalendarModel) {
        NotificationHub.shared.register(CalendarNotifications(model: calendar))
    }

    /// Social joins once its model is made. Its likes, comments and follows poke the other person's phones.
    static func connect(social: SocialModel) {
        NotificationHub.shared.register(SocialNotifications(model: social))
        social.onActivity = { names in
            guard let token = AccountSetup.searchToken else { return }
            Task { try? await PushClient(token: token).poke(names) }
        }
    }

    /// Everything leaves with the account.
    static func disconnect() {
        let hub = NotificationHub.shared
        for module in Array(hub.sources.keys) { hub.unregister(module) }
        AppRefresh.shared.extras["notifications"] = nil
        Task { await hub.updateBadge() }
    }
}

/// Calendar's part: taps. Alerts are set by `SystemReminders` and Snooze is done by the hub.
@MainActor
final class CalendarNotifications: NotificationSource {
    let module = ModuleID.calendar
    let kinds: [NotificationKind] = []
    private let model: CalendarModel

    init(model: CalendarModel) {
        self.model = model
    }

    func newNotifications() async -> [AppNotification] { [] }

    func prepareToOpen(_ target: NotificationTarget) {
        if target.kind == "event" { model.requestAlertTarget(target.item) }
    }
}

/// Mail's part. Gmail wakes the phone (non-negotiable 8); the notes are written here from mail the phone
/// fetched itself, as before. Mark read works from the lock screen.
@MainActor
final class MailNotifications: NotificationSource {
    static let newMail = NotificationKind(module: .mail, key: "newMail", name: "New mail", detail: "Instant for Gmail, sooner or later for the rest")

    let module = ModuleID.mail
    let kinds = [newMail]
    private let mail: MailAccountModel

    init(mail: MailAccountModel) {
        self.mail = mail
    }

    func newNotifications() async -> [AppNotification] {
        // In front, Mail is already showing it, and the minute-by-minute refresh fetches anyway.
        guard GmailPushSettings.shared.isOn, UIApplication.shared.applicationState != .active,
              let onWake = PushSetup.shared.onWake else { return [] }
        return await onWake().map { note in
            AppNotification(
                id: "mail." + note.id.uuidString.lowercased(), kind: Self.newMail, title: note.title, subtitle: note.subtitle,
                body: note.body, isPrivate: true, thread: note.account.uuidString.lowercased(),
                target: NotificationTarget(module: .mail, kind: "conversation", item: note.conversationID.uuidString),
                actions: [.markRead], date: Date()
            )
        }
    }

    func badgeCount() -> Int {
        MailBadge.shared.count(in: mail.current.mailbox)
    }

    func prepareToOpen(_ target: NotificationTarget) {
        guard let id = UUID(uuidString: target.item) else { return }
        mail.current.requestedConversation = id
    }

    func perform(_ action: NotificationAction, on target: NotificationTarget, text: String?) async {
        guard action == .markRead, let id = UUID(uuidString: target.item) else { return }
        if mail.current.phase != .ready { await mail.current.refresh() }
        guard let conversation = mail.current.mailbox.conversations(in: .inbox).first(where: { $0.id == id }) else { return }
        await mail.current.markRead(conversation)
    }
}
#endif

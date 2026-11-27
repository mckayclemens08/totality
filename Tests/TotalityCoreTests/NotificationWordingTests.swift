import Foundation
import Testing
@testable import TotalityCore

/// Every alert says what it is (owner, 2026-11-26: a Gmail alert showed only "Fossil" and a subject).
struct NotificationWordingTests {
    private func planned(_ module: ModuleID, subtitle: String? = nil, thread: String = "t1") throws -> PlannedAlert {
        let kind = NotificationKind(module: module, key: "k", name: "K", detail: "")
        let note = AppNotification(
            id: module.rawValue, kind: kind, title: "Fossil", subtitle: subtitle, body: "Tick Tock: Don't miss these prices",
            thread: thread, target: NotificationTarget(module: module, kind: "item", item: "1"), date: Date()
        )
        return try #require(PlannedAlert.plan(note, preferences: NotificationPreferences(), now: Date()))
    }

    @Test func eachModuleSaysWhatItIs() throws {
        #expect(try planned(.messages).subtitle == "Message")
        #expect(try planned(.social).subtitle == "Social")
        #expect(try planned(.calendar).subtitle == "Calendar")
        #expect(try planned(.mail).subtitle == "New email")
        #expect(ModuleID.allCases.allSatisfy { !NotificationWording.subtitle(for: $0).isEmpty })
    }

    @Test func mailSaysEmailAndGroupsByAccount() throws {
        let alert = try planned(.mail, subtitle: "New email \u{00B7} Gmail", thread: "account-1")
        #expect(alert.title == "Fossil" && alert.subtitle == "New email \u{00B7} Gmail")
        #expect(alert.thread == "mail.account-1", "Each mail account groups on its own, even when grouping by app")
        #expect(try planned(.social).thread == "social")
    }
}

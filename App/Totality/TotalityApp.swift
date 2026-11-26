import SwiftUI
import TotalityCore
import TotalityPhotos
import TotalityTasks
import TotalityUI

@main
struct TotalityApp: App {
    #if os(iOS)
    // Instant Gmail sync's push token and wake-ups come through here.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif

    init() {
        // iOS needs this before launch finishes. A run with no library open does nothing.
        SyncSchedule.register()
        // Before launch finishes too, so Complete or Snooze on a notification, or a place reminder, that
        // wakes the app is handled.
        SystemTaskReminders.shared.start()
        #if os(iOS)
        // After Tasks, so its reminder buttons keep working: the hub takes over as iOS's notification
        // delegate and hands Tasks' own alerts back to it (issue 232).
        NotificationHub.shared.start()
        #endif
    }

    var body: some Scene {
        // One window on Mac: a second would hold its own copy of a note and could overwrite the first.
        #if os(macOS)
        Window("Totality", id: "main") {
            RootView()
                .followsTheme()
        }
        .defaultSize(width: 430, height: 800)
        #else
        WindowGroup {
            RootView()
                .followsTheme()
        }
        .backgroundTask(.appRefresh(AppRefresh.backgroundIdentifier)) {
            await AppRefresh.shared.runInBackground()
        }
        #endif
    }
}

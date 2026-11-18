import SwiftUI
import TotalityCore
import TotalityPhotos
import TotalityTasks
import TotalityUI

@main
struct TotalityApp: App {
    init() {
        // iOS needs this before launch finishes. A run with no library open does nothing.
        SyncSchedule.register()
        // Before launch finishes too, so Complete or Snooze on a notification, or a place reminder, that
        // wakes the app is handled.
        SystemTaskReminders.shared.start()
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

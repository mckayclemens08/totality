import SwiftUI
import TotalityCore
import TotalityPhotos

@main
struct TotalityApp: App {
    init() {
        // iOS needs this before launch finishes. A run with no library open does nothing.
        SyncSchedule.register()
    }

    var body: some Scene {
        // One window on Mac: a second would hold its own copy of a note and could overwrite the first.
        #if os(macOS)
        Window("Totality", id: "main") {
            RootView()
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 430, height: 800)
        #else
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
        }
        .backgroundTask(.appRefresh(AppRefresh.backgroundIdentifier)) {
            await AppRefresh.shared.runInBackground()
        }
        #endif
    }
}

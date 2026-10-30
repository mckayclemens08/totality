import SwiftUI

@main
struct TotalityApp: App {
    var body: some Scene {
        // One window on Mac: a second would hold its own copy of a note and could overwrite the first.
        #if os(macOS)
        Window("Totality", id: "main") {
            RootView()
        }
        .defaultSize(width: 430, height: 800)
        #else
        WindowGroup {
            RootView()
        }
        #endif
    }
}

import SwiftUI
import TotalityReader

@main
struct TotalityApp: App {
    init() {
        if #available(iOS 18, macOS 15, *) {
            Task { await VoiceTrial.runIfAsked() }
        }
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
        #endif
    }
}

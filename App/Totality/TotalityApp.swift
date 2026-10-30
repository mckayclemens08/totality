import SwiftUI

@main
struct TotalityApp: App {
    private static let macWindowSize = CGSize(width: 430, height: 800)

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(Self.macWindowSize)
    }
}

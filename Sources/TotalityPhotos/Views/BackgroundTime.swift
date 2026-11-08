#if os(iOS)
import UIKit
#endif

/// Time iOS gives an upload to finish once Totality goes into the background. On the Mac there's
/// nothing to ask for. When iOS's time runs out, the upload stops where it is and carries on next time.
@MainActor
final class BackgroundTime {
    #if os(iOS)
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin() -> BackgroundTime {
        let time = BackgroundTime()
        time.id = UIApplication.shared.beginBackgroundTask(withName: "Uploading photos") { [weak time] in time?.end() }
        return time
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
    #else
    static func begin() -> BackgroundTime { BackgroundTime() }
    func end() {}
    #endif
}

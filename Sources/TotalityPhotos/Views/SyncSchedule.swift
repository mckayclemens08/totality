import Foundation
import Network
#if os(iOS)
import BackgroundTasks
#endif

/// Whether the device is on Wi-Fi or another network that isn't metered, which is when sync goes (P4),
/// and when an original that's only in iCloud may come down (P7).
enum NetworkCheck {
    static func isOnWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.first() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "app.totality.photos.network"))
        }
    }

    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func first() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }
}

/// iOS's background processing time for sync, which it tends to give at night while charging. It's up to
/// iOS when, and whether, it runs. Most syncing happens while Photos is open.
public enum SyncSchedule {
    public static let identifier = "app.totality.photos.sync"
    /// The open library's sync, set while there is one. A run iOS starts with nothing set does nothing.
    @MainActor public static var run: (@MainActor () async -> Void)?
    /// Stops that run, when iOS's time is up.
    @MainActor public static var stop: (@MainActor () -> Void)?

    /// Must be called before the app finishes launching.
    public static func register() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            let held = HeldTask(task)
            let work = Task { @MainActor in
                await run?()
                held.task.setTaskCompleted(success: true)
                ask()
            }
            task.expirationHandler = {
                work.cancel()
                Task { @MainActor in stop?() }
            }
        }
        #endif
    }

    #if os(iOS)
    /// iOS's task, which it lets be completed from any thread.
    private final class HeldTask: @unchecked Sendable {
        let task: BGProcessingTask
        init(_ task: BGProcessingTask) { self.task = task }
    }
    #endif

    /// Asks iOS for the next run, while charging and online.
    public static func ask() {
        #if os(iOS)
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}

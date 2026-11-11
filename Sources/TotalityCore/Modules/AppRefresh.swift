import Foundation
import os
#if os(iOS)
import BackgroundTasks
#endif

/// The one scheduler that keeps modules up to date before they're opened. Modules join through the
/// registry as `ModuleRefresher`s; the app calls `refresh()` at launch, on coming back, every `every`
/// while it's in front, and `runInBackground()` when iOS grants a background refresh.
///
/// iOS decides when a background refresh runs, usually a few times an hour at most, and only while the
/// content key can open, which is while the phone is unlocked. Mail arriving the moment it's sent with the
/// app closed needs push notifications, and those need a paid Apple Developer account, so they wait.
@MainActor
public final class AppRefresh {
    public static let shared = AppRefresh()
    /// What iOS knows the background refresh by. It's listed under BGTaskSchedulerPermittedIdentifiers.
    public static let backgroundIdentifier = "app.totality.client.refresh"
    /// How often modules fetch while Totality is in front.
    public static let every = Duration.seconds(60)
    /// The soonest iOS is asked to run the next background refresh.
    public static let soonest: TimeInterval = 15 * 60

    /// The modules to refresh. Nil until content opens, and again while the key moves.
    public var registry: ModuleRegistry?
    private var running: Task<Void, Never>?
    private static let log = Logger(subsystem: "app.totality.client", category: "refresh")

    public init() {}

    /// Every module fetches what's new, one after another. Asking while a refresh is under way waits for
    /// that one instead of starting another.
    public func refresh() async {
        if let running {
            await running.value
            return
        }
        let refreshers = registry?.refreshers ?? []
        let task = Task { @MainActor in
            for refresher in refreshers {
                guard !Task.isCancelled else { return }
                let start = ContinuousClock.now
                await refresher.refreshAhead()
                let took = (ContinuousClock.now - start).components
                let milliseconds = Int(took.seconds * 1000 + took.attoseconds / 1_000_000_000_000_000)
                let module = refresher.module.rawValue
                Self.log.notice("\(module, privacy: .public) took \(milliseconds, privacy: .public) ms")
            }
        }
        running = task
        await task.value
        running = nil
    }

    /// Asks iOS for the next background refresh. Asking again replaces the earlier request.
    public func scheduleBackground() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.soonest)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// One background refresh. The next is asked for first, so one iOS cuts short still leads to another.
    public func runInBackground() async {
        scheduleBackground()
        await refresh()
    }
}

import Foundation
import os

/// How long each step of opening Mail takes, written to the device's log so a slow step shows up in
/// Console under the "mail" category. Only the step's name and milliseconds are written: never an
/// address, a subject, a token, or how much mail there is.
struct MailClock {
    private static let log = Logger(subsystem: "app.totality.client", category: "mail")
    private let name: String
    private let start = ContinuousClock.now
    private var last = ContinuousClock.now

    init(_ name: String) {
        self.name = name
    }

    /// The step that just finished, and how long it took since the one before.
    mutating func mark(_ step: String) {
        let now = ContinuousClock.now
        let name = name, took = Self.milliseconds(now - last)
        Self.log.notice("\(name, privacy: .public): \(step, privacy: .public) took \(took, privacy: .public) ms")
        last = now
    }

    func done() {
        let name = name, took = Self.milliseconds(ContinuousClock.now - start)
        Self.log.notice("\(name, privacy: .public): done in \(took, privacy: .public) ms")
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// The answer, or nil when it doesn't come within `limit`. Work still going on is left to finish by
/// itself, and its answer is dropped.
func mailAnswer<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
    let once = MailOnce<T?>()
    return await withCheckedContinuation { continuation in
        once.wait(continuation)
        Task { once.resume(await work()) }
        Task {
            try? await Task.sleep(for: limit)
            once.resume(nil)
        }
    }
}

/// Resumes its continuation for whichever answer comes first.
private final class MailOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func wait(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: T) {
        let waiting = lock.withLock {
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(returning: value)
    }
}

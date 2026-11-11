import Foundation

/// A step that took longer than it's allowed.
public struct DeadlinePassed: Error, Equatable, Sendable {
    public init() {}
}

/// Gives a step a time limit, so nothing in Totality waits forever. When the time runs out the caller
/// gets `DeadlinePassed` straight away, even from a step that never checks for cancellation, and the
/// step is asked to stop and left to finish on its own.
public enum Deadline {
    public static func run<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = Once<T>()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            let worker = Task {
                do { once.finish(.success(try await work())) } catch { once.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.finish(.failure(DeadlinePassed())) { worker.cancel() }
            }
        }
    }

    /// Answers once, whichever comes first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var pending: Result<T, any Error>?
        private var done = false

        func set(_ continuation: CheckedContinuation<T, any Error>) {
            let early: Result<T, any Error>? = lock.withLock {
                if let pending { return pending }
                self.continuation = continuation
                return nil
            }
            if let early { continuation.resume(with: early) }
        }

        /// True for the first answer, which is the one passed on. Later ones are dropped.
        @discardableResult
        func finish(_ result: Result<T, any Error>) -> Bool {
            let (first, waiting): (Bool, CheckedContinuation<T, any Error>?) = lock.withLock {
                guard !done else { return (false, nil) }
                done = true
                guard let continuation else {
                    pending = result
                    return (true, nil)
                }
                self.continuation = nil
                return (true, continuation)
            }
            waiting?.resume(with: result)
            return first
        }
    }
}

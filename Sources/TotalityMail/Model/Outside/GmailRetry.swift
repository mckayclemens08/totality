import Foundation

/// How Gmail's passing troubles are waited out: "too fast" (429, or a 403 saying so), its own 5xx, and a
/// connection that timed out or dropped. Each wait doubles from `first`, with jitter so many requests
/// don't all come back at once, and is never shorter than Gmail's own Retry-After. Nothing is shown to
/// the person until the trouble has lasted past `patience`.
struct GmailRetry: Sendable {
    /// The first wait. Doubles each time after.
    var first: Duration
    /// No single wait is longer than this, unless Gmail's Retry-After asks for more.
    var longest: Duration = .seconds(30)
    /// More waiting than this in all, and the trouble is real, so it's said.
    var patience: Duration = .seconds(120)
    /// Tries in all, however short the waits were.
    var mostTries = 10
    /// The share of each doubled wait actually waited, from 0 to 1.
    var jitter: @Sendable () -> Double = { Double.random(in: 0.5...1) }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// The wait after `failures` failed tries (1 after the first), never less than Retry-After.
    func wait(after failures: Int, retryAfter: Duration?) -> Duration {
        let doubled = min(first * Double(1 << min(max(failures - 1, 0), 20)), longest)
        return max(doubled * min(max(jitter(), 0), 1), retryAfter ?? .zero)
    }

    /// Gmail's Retry-After, in seconds or as a date. Nil when it didn't say, or said nonsense.
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return .milliseconds(Int(min(seconds, 3_600) * 1000)) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: value) else { return nil }
        return .milliseconds(Int(min(max(date.timeIntervalSince(now), 0), 3_600) * 1000))
    }

    /// A dropped or slow connection that's worth trying again. Being offline isn't: that's said at once.
    static func passes(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .badServerResponse].contains(error.code)
    }
}

/// Keeps Gmail requests under its per-person quota: about 250 units a second, where fetching one message
/// costs 5. Every request is counted as 5, so 40 a second is 200 units, with room to spare.
actor GmailPace {
    static let perSecond = 40.0

    private let perSecond: Double
    private let burst: Double
    private var tokens: Double
    private var last = ContinuousClock.now

    init(perSecond: Double = GmailPace.perSecond) {
        self.perSecond = perSecond
        burst = perSecond
        tokens = perSecond
    }

    /// Waits until one more request fits under the quota. Its place is taken before waiting, so
    /// requests waiting together go in turn.
    func take() async throws {
        let now = ContinuousClock.now
        let elapsed = now - last
        last = now
        tokens = min(burst, tokens + (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * perSecond)
        tokens -= 1
        if tokens < 0 { try await Task.sleep(for: .milliseconds(Int(-tokens / perSecond * 1000))) }
    }
}

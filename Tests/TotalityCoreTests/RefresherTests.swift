import Foundation
import Testing
@testable import TotalityCore

/// Counts calls from the main actor.
@MainActor
private final class Counter {
    var count = 0
}

@Suite("Deadline")
struct DeadlineTests {
    @Test func answersWithTheWork() async throws {
        let value = try await Deadline.run(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func passesOnTheWorksError() async {
        struct Broke: Error {}
        await #expect(throws: Broke.self) {
            try await Deadline.run(.seconds(5)) { throw Broke() }
        }
    }

    /// A step that never answers and ignores cancellation still gives up on time.
    @Test func givesUpOnWorkThatNeverAnswers() async {
        let start = ContinuousClock.now
        await #expect(throws: DeadlinePassed.self) {
            try await Deadline.run(.milliseconds(100)) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}

@Suite("Refresher")
@MainActor
struct RefresherTests {
    @Test func runsEveryStepAndClearsTheLine() async {
        let refresher = Refresher()
        let counter = Counter()
        refresher.add("a") { counter.count += 1; return .done }
        refresher.add("b") { counter.count += 10; return .done }
        await refresher.refresh()
        #expect(counter.count == 11)
        #expect(refresher.problem == nil)
        #expect(!refresher.isRefreshing)
        #expect(refresher.lastFinished != nil)
    }

    @Test func aStepWithTheSameNameReplacesTheOldOne() async {
        let refresher = Refresher()
        let counter = Counter()
        refresher.add("a") { counter.count += 1; return .done }
        refresher.add("a") { counter.count += 5; return .done }
        await refresher.refresh()
        #expect(counter.count == 5)
        #expect(refresher.stepNames == ["a"])
    }

    @Test func offlineIsSaidPlainly() async {
        let refresher = Refresher()
        refresher.add("a") { .failed("Something else") }
        refresher.add("b") { .offline }
        await refresher.refresh(.pulled)
        #expect(refresher.problem == Refresher.offlineLine)
    }

    /// Automatic runs stay quiet about a problem until it happens twice in a row (owner, 2026-11-08).
    @Test func anAutomaticProblemShowsOnlyOnceItLasts() async {
        let refresher = Refresher()
        refresher.add("a") { .failed("Google Calendar couldn't be reached.") }
        await refresher.refresh()
        #expect(refresher.problem == nil)
        await refresher.refresh()
        #expect(refresher.problem == "Google Calendar couldn't be reached.")
        refresher.add("a") { .done }
        await refresher.refresh()
        #expect(refresher.problem == nil)
    }

    @Test func aPullSaysStraightAway() async {
        let refresher = Refresher()
        refresher.add("a") { .offline }
        await refresher.refresh(.pulled)
        #expect(refresher.problem == Refresher.offlineLine)
    }

    @Test func aBlipBetweenGoodRunsNeverShows() async {
        let refresher = Refresher()
        refresher.add("a") { .offline }
        await refresher.refresh()
        refresher.add("a") { .done }
        await refresher.refresh()
        refresher.add("a") { .offline }
        await refresher.refresh()
        #expect(refresher.problem == nil)
    }

    /// The person isn't looking, and a locked phone can't open its keys.
    @Test func backgroundRunsShowNothing() async {
        let refresher = Refresher()
        refresher.add("a") { .failed("Locked") }
        await refresher.refresh(.background)
        await refresher.refresh(.background)
        #expect(refresher.problem == nil)
        #expect(refresher.lastFinished != nil)
    }

    /// The spinner never hangs: a step that never answers ends the run at its limit.
    @Test func aStepThatNeverAnswersEndsTheRun() async {
        let refresher = Refresher(limit: .milliseconds(100))
        refresher.add("stuck") {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return .done
        }
        await refresher.refresh(.pulled)
        #expect(!refresher.isRefreshing)
        #expect(refresher.problem == Refresher.slowLine)
    }

    @Test func askingDuringARunWaitsForThatRun() async {
        let refresher = Refresher()
        let counter = Counter()
        refresher.add("slow") {
            try? await Task.sleep(for: .milliseconds(100))
            counter.count += 1
            return .done
        }
        async let first: Void = refresher.refresh()
        async let second: Void = refresher.refresh()
        _ = await (first, second)
        #expect(counter.count == 1)
        #expect(!refresher.isRefreshing)
    }

    @Test func nothingToDoIsNotARun() async {
        let refresher = Refresher()
        await refresher.refresh()
        #expect(refresher.lastFinished == nil)
    }
}

@Suite("Refresher pull-only steps")
@MainActor
struct RefresherPullOnlyTests {
    @Test func aPullOnlyStepWaitsForAPull() async {
        let refresher = Refresher()
        let counter = Counter()
        refresher.add("this device") { counter.count += 1; return .done }
        refresher.add("other devices", onlyWhenPulled: true) { counter.count += 10; return .done }
        await refresher.refresh()
        #expect(counter.count == 1)
        await refresher.refresh(.pulled)
        #expect(counter.count == 12)
    }
}

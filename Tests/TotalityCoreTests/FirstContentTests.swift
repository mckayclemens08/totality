import Testing
@testable import TotalityCore

@MainActor
@Suite struct FirstContentTests {
    @Test func waitsForEveryJob() async {
        var done: [String] = []
        await FirstContent.wait(for: [
            { try? await Task.sleep(for: .milliseconds(20)); done.append("a") },
            { done.append("b") },
        ], cap: .seconds(5))
        #expect(Set(done) == ["a", "b"])
    }

    @Test func aHangingJobIsCutOffAtTheCap() async {
        var quick = false
        let start = ContinuousClock.now
        await FirstContent.wait(for: [
            { try? await Task.sleep(for: .seconds(30)) },
            { quick = true },
        ], cap: .milliseconds(100))
        #expect(quick)
        #expect(ContinuousClock.now - start < .seconds(5), "Launch never waits past the cap")
    }

    @Test func noJobsReturnsAtOnce() async {
        await FirstContent.wait(for: [], cap: .seconds(5))
    }
}

import Foundation
import Testing
@testable import TotalityMessages

/// What a person reads when the Matrix SDK fails. Only the network is called the network.
struct MatrixFailureTests {
    @Test func networkFailuresStillSayOffline() {
        for message in [
            "error sending request for url (https://matrix.usetotality.com/_matrix/client/v3/rooms)",
            "Connection refused (os error 61)",
            "operation timed out",
            "dns error: failed to lookup address information",
            "The Internet connection appears to be offline.",
        ] {
            #expect(MatrixFailure.fromSDK(message) == .offline, "\(message)")
            #expect(MatrixFailure.fromSDK(message).error == .offline)
        }
    }

    @Test func anSDKFailureIsNotAConnectionProblem() {
        // What the SDK says when a room's power levels haven't synced yet: the Close friends bug.
        let error = MatrixFailure.fromSDK("the room is missing data needed for this operation (InsufficientData)").error
        guard case .failed(let text) = error else { Issue.record("expected a failure, got \(error)"); return }
        #expect(!text.lowercased().contains("connection"))
        #expect(!text.lowercased().contains("reach the server"))
        #expect(!text.lowercased().contains("offline"))
        #expect(text == "That didn't go through (the room is missing data needed for this operation (InsufficientData)).")
    }

    @Test func serverCodesAreQuoted() {
        #expect(MatrixFailure.server(code: "M_UNKNOWN").error == .failed("That didn't go through (M_UNKNOWN)."))
        #expect(MatrixFailure.server(code: "M_INVALID_PARAM").error == .failed("That didn't go through (M_INVALID_PARAM)."))
        #expect(MatrixFailure.server(code: "M_FORBIDDEN").error == .failed("The Matrix server refused that."))
        guard case .failed(let busy) = MatrixFailure.server(code: "M_LIMIT_EXCEEDED").error else { Issue.record("not a failure"); return }
        #expect(!busy.contains("connection"))
        // A code that isn't a code is never echoed.
        #expect(MatrixFailure.server(code: "@carterbnielson:usetotality.com hi").error == .failed("That didn't go through (unknown code)."))
    }

    @Test func theCodeNamesNobodyAndCarriesNoContent() {
        let message = """
        Failed to invite @carterbnielson:usetotality.com to !AbCdEf123:usetotality.com after event \
        $Yl0h9sQ2x8kVt3bQe7nR4pLmZ1cW6uJ5aDfGhJkLqWe: body "see you at 7, love" from carter@example.com \
        via https://matrix.usetotality.com/_matrix/client/v3/rooms token syt_Y2FydGVy_aBcDeFgHiJ_1a2B3c
        """
        let code = MatrixFailure.code(message)
        #expect(code.count <= MatrixFailure.codeLength)
        for secret in ["carterbnielson", "AbCdEf123", "Yl0h9sQ2x8", "see you", "love", "example.com", "https", "syt_", "aBcDeFgHiJ"] {
            #expect(!code.contains(secret), "\(secret) leaked into \(code)")
        }
        #expect(code.hasPrefix("Failed to invite"))
    }

    @Test func theCodeIsShortAndKeepsOrdinaryWords() {
        #expect(MatrixFailure.code("Room doesn't exist and couldn't be found.") == "Room doesn't exist and couldn't be found")
        #expect(MatrixFailure.code(String(repeating: "word ", count: 60)).count == MatrixFailure.codeLength)
        #expect(MatrixFailure.code("") == "unknown error")
        #expect(MatrixFailure.code("@someone:usetotality.com") == "unknown error")
    }

    @Test func waitingStopsOnceReady() async throws {
        var calls = 0
        let ready = try await MatrixWait.until(attempts: 10, every: .milliseconds(1)) {
            calls += 1
            return calls == 3
        }
        #expect(ready)
        #expect(calls == 3)
    }

    @Test func waitingGivesUpInTime() async throws {
        var calls = 0
        let ready = try await MatrixWait.until(attempts: 4, every: .milliseconds(1)) {
            calls += 1
            return false
        }
        #expect(!ready)
        #expect(calls == 4)
    }
}

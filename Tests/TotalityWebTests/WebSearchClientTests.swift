import Foundation
import Testing
@testable import TotalityWeb

@Suite struct WebSearchClientTests {
    @Test("A search goes in the body of a POST, so it's never part of an address")
    func theSearchIsNotInTheAddress() async throws {
        let (client, host) = FakeGateway.client { _ in (200, resultsJSON(["Tram"])) }
        _ = try await client.search("private words", category: .news, page: 2, safety: .strict)
        let sent = try #require(FakeGateway.requests(to: host).first)
        #expect(sent.method == "POST")
        #expect(sent.url.path() == "/web/search")
        #expect(sent.url.query() == nil)
        #expect(!sent.url.absoluteString.contains("private"))
        #expect(sent.body["query"] as? String == "private words")
        #expect(sent.body["category"] as? String == "news")
        #expect(sent.body["page"] as? Int == 2)
        #expect(sent.body["safety"] as? Int == 2)
    }

    @Test func theSignInGoesWithIt() async throws {
        let (client, host) = FakeGateway.client { _ in (200, resultsJSON([])) }
        _ = try await client.search("tram", category: .web, page: 1, safety: .moderate)
        #expect(FakeGateway.requests(to: host).first?.authorization == "Bearer good.token")
    }

    @Test func resultsComeBackAsSent() async throws {
        let (client, _) = FakeGateway.client { _ in (200, resultsJSON(["Tram"], partial: true)) }
        let answer = try await client.search("tram", category: .web, page: 1, safety: .moderate)
        #expect(answer.partial)
        #expect(answer.results.map(\.title) == ["Tram"])
        #expect(answer.results.first?.thumbnail == nil)
    }

    @Test("Each refusal says what it is", arguments: [
        (401, WebSearchError.signedOut), (429, .limitReached), (502, .unavailable), (404, .unavailable),
    ])
    func refusals(status: Int, error: WebSearchError) async {
        let (client, _) = FakeGateway.client { _ in (status, Data()) }
        await #expect(throws: error) {
            try await client.search("tram", category: .web, page: 1, safety: .moderate)
        }
    }

    @Test func noSignInMeansNothingIsSent() async {
        let (client, host) = FakeGateway.client(token: { throw CancellationError() }) { _ in (200, Data()) }
        await #expect(throws: WebSearchError.signedOut) {
            try await client.search("tram", category: .web, page: 1, safety: .moderate)
        }
        #expect(FakeGateway.requests(to: host).isEmpty)
    }

    @Test func aDamagedAnswerIsNotACrash() async {
        let (client, _) = FakeGateway.client { _ in (200, Data("nope".utf8)) }
        await #expect(throws: WebSearchError.unavailable) {
            try await client.search("tram", category: .web, page: 1, safety: .moderate)
        }
    }

    @Test("A thumbnail is asked for by POST, with its signature")
    func thumbnails() async throws {
        let (client, host) = FakeGateway.client { _ in (200, Data("png".utf8)) }
        let data = try await client.image(WebThumbnail(url: "https://img.example/a.jpg", signature: "abc"))
        #expect(data == Data("png".utf8))
        let sent = try #require(FakeGateway.requests(to: host).first)
        #expect(sent.url.path() == "/web/image")
        #expect(sent.url.query() == nil)
        #expect(sent.body["signature"] as? String == "abc")
    }
}

import Foundation
import Testing
@testable import TotalityWeb

@MainActor
@Suite struct WebModelTests {
    private func model(_ answer: @escaping @Sendable (FakeGateway.Sent) -> (Int, Data)) -> (WebModel, host: String) {
        let (client, host) = FakeGateway.client(answer: answer)
        return (WebModel(client: client), host)
    }

    private func finished(_ model: WebModel) async throws {
        try await until { model.current.search.phase != .searching }
    }

    @Test func aSearchShowsResults() async throws {
        let (model, _) = model { _ in (200, resultsJSON(["Tram"])) }
        model.submit("tram 28")
        #expect(model.current.showing == .results)
        try await finished(model)
        #expect(model.current.search.results.map(\.title) == ["Tram"])
        #expect(model.current.search.phase == .done)
    }

    @Test func anAddressOpensAPage() {
        let (model, host) = model { _ in (200, Data()) }
        model.submit("example.com")
        #expect(model.current.showing == .page)
        #expect(model.current.page?.url?.host() == "example.com")
        #expect(FakeGateway.requests(to: host).isEmpty)
    }

    @Test func safeSearchReachesTheServer() async throws {
        let (model, host) = model { _ in (200, resultsJSON([])) }
        model.safety = .strict
        model.submit("tram 28")
        try await finished(model)
        #expect(FakeGateway.requests(to: host).first?.body["safety"] as? Int == 2)
    }

    @Test("Choosing a category searches again and clears the old results")
    func categories() async throws {
        let (model, host) = model { sent in (200, resultsJSON([sent.body["category"] as? String ?? ""])) }
        model.submit("tram 28")
        try await finished(model)
        model.choose(.images)
        #expect(model.current.search.results.isEmpty)
        try await finished(model)
        #expect(model.current.search.results.map(\.title) == ["images"])
        model.choose(.images)
        #expect(FakeGateway.requests(to: host).count == 2)
    }

    @Test("A failed search says why", arguments: [
        (401, WebSearchError.signedOut), (429, .limitReached), (502, .unavailable),
    ])
    func failures(status: Int, error: WebSearchError) async throws {
        let (model, _) = model { _ in (status, Data()) }
        model.submit("tram 28")
        try await finished(model)
        #expect(model.current.search.phase == .failed(error))
    }

    @Test func withNoAccountSearchAsksForASignIn() async throws {
        let model = WebModel(client: nil)
        model.submit("tram 28")
        try await finished(model)
        #expect(model.current.search.phase == .failed(.signedOut))
    }

    @Test("A slow answer can't replace a newer search")
    func staleAnswers() async throws {
        let (model, _) = model { sent in
            if sent.body["query"] as? String == "old" { Thread.sleep(forTimeInterval: 0.2) }
            return (200, resultsJSON([sent.body["query"] as? String ?? ""]))
        }
        model.submit("old")
        model.submit("new")
        try await finished(model)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.current.search.results.map(\.title) == ["new"])
    }

    @Test("More results add to the list, without repeats")
    func loadMore() async throws {
        let (model, host) = model { sent in
            (200, resultsJSON(sent.body["page"] as? Int == 1 ? ["One", "Two"] : ["Two", "Three"]))
        }
        model.submit("tram 28")
        try await finished(model)
        model.loadMore()
        try await until { model.current.search.page == 2 }
        #expect(model.current.search.results.map(\.title) == ["One", "Two", "Three"])
        #expect(FakeGateway.requests(to: host).count == 2)
    }

    @Test("A failed next page keeps what's already on screen")
    func loadMoreFailure() async throws {
        let (model, _) = model { sent in
            sent.body["page"] as? Int == 1 ? (200, resultsJSON(["One"])) : (502, Data())
        }
        model.submit("tram 28")
        try await finished(model)
        model.loadMore()
        try await until { !model.current.search.isLoadingMore }
        #expect(model.current.search.phase == .done)
        #expect(model.current.search.results.count == 1)
    }

    @Test("Back leaves a page for the results it came from, then the start")
    func backSteps() async throws {
        let (model, _) = model { _ in (200, resultsJSON(["Tram"])) }
        model.submit("tram 28")
        try await finished(model)
        model.open(try #require(URL(string: "https://example.com/Tram")))
        #expect(model.current.showing == .page)
        #expect(model.canGoBack)
        model.goBack()
        #expect(model.current.showing == .results)
        #expect(model.canGoForward)
        model.goForward()
        #expect(model.current.showing == .page)
        model.goBack()
        model.goBack()
        #expect(model.current.showing == .start)
        #expect(!model.canGoBack)
    }

    @Test func theFallbackGoesToDuckDuckGoWithTheSameWords() async throws {
        let (model, _) = model { _ in (502, Data()) }
        model.submit("tram 28")
        try await finished(model)
        model.openOnPublicSearch()
        let url = try #require(model.current.page?.url)
        #expect(url.host() == "duckduckgo.com")
        #expect(url.query()?.contains("tram") == true)
    }
}

@MainActor
@Suite struct WebPageTests {
    @Test("A private page keeps nothing, and a normal one uses the account's store")
    func stores() {
        #expect(!WebPage.configuration(isPrivate: true, store: .default()).websiteDataStore.isPersistent)
        #expect(WebPage.configuration(isPrivate: false, store: .default()).websiteDataStore.isPersistent)
    }

    @Test("Pages can't open tabs by themselves, and fraud warnings stay on")
    func safeties() {
        let configuration = WebPage.configuration(isPrivate: false, store: .default())
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(configuration.preferences.isFraudulentWebsiteWarningEnabled)
        #expect(configuration.upgradeKnownHostsToHTTPS)
    }

    @Test("Pages get no scripts and no message route into the app")
    func noBridge() {
        let configuration = WebPage.configuration(isPrivate: false, store: .default())
        #expect(configuration.userContentController.userScripts.isEmpty)
    }

    @Test("A bad certificate can't be retried past")
    func certificates() {
        let failure = WebPageFailure.of(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))
        #expect(failure == .insecure)
        #expect(failure?.canRetry == false)
    }

    @Test("A stopped load isn't a failure")
    func cancelled() {
        #expect(WebPageFailure.of(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)) == nil)
    }

    @Test func offlineIsToldApart() {
        #expect(WebPageFailure.of(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) == .offline)
        #expect(WebPageFailure.of(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) == .other)
    }
}

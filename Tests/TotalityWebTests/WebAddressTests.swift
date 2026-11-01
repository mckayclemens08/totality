import Foundation
import Testing
@testable import TotalityWeb

@Suite struct WebAddressTests {
    private func address(_ text: String) -> String? {
        if case .address(let url) = WebAddress.parse(text) { url.absoluteString } else { nil }
    }

    private func isSearch(_ text: String) -> Bool {
        if case .search = WebAddress.parse(text) { true } else { false }
    }

    @Test("Web addresses open, with or without a scheme", arguments: [
        ("example.com", "https://example.com"),
        ("https://carris.pt/28", "https://carris.pt/28"),
        ("http://example.com", "http://example.com"),
        ("HTTPS://example.com", "HTTPS://example.com"),
        ("news.ycombinator.com/item?id=1", "https://news.ycombinator.com/item?id=1"),
        ("localhost:8080", "https://localhost:8080"),
        ("192.168.1.1", "https://192.168.1.1"),
        ("  example.com  ", "https://example.com"),
    ])
    func addresses(typed: String, opens: String) {
        #expect(address(typed) == opens)
    }

    @Test("Everything else is a search", arguments: [
        "tram 28 lisbon", "what is 3.5 + 2", "kant", "3.5", "v2.0", "a.b c", "hello.", ".com", "example..com",
    ])
    func searches(typed: String) {
        #expect(isSearch(typed))
    }

    @Test("The box can never run or open anything but a web page", arguments: [
        "javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "ftp://example.com", "tel:5551234",
        "totality://open", "about:blank",
    ])
    func onlyWebSchemes(typed: String) {
        #expect(address(typed) == nil)
        #expect(isSearch(typed))
    }

    @Test func nothingTypedIsNothing() {
        #expect(WebAddress.parse("   ") == nil)
    }

    @Test func thePublicSearchKeepsTheWordsTogether() throws {
        let url = try #require(WebAddress.publicSearch("tram & bus?"))
        #expect(url.host() == "duckduckgo.com")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.first?.value == "tram & bus?")
    }
}

import Foundation
import Testing
@testable import TotalityCore

@Suite struct ProfileLinksTests {
    @Test func addsHTTPSAndLowercasesTheHost() throws {
        #expect(try ProfileLinks.normalize("Example.com/Me") == "https://example.com/Me")
        #expect(try ProfileLinks.normalize("  https://WWW.Example.com  ") == "https://www.example.com")
        #expect(try ProfileLinks.normalize("https://example.com/") == "https://example.com")
        #expect(try ProfileLinks.normalize("//example.com/x") == "https://example.com/x")
        #expect(try ProfileLinks.normalize("example.com:8080/x") == "https://example.com:8080/x")
    }

    @Test(arguments: [
        "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,hi", "mailto:a@b.com", "tel:5551234",
        "http://example.com", "ftp://example.com", "file:///etc/passwd", "sms:555",
    ])
    func refusesOtherSchemes(_ typed: String) {
        #expect(throws: ProfileLinks.Problem.notHTTPS) { try ProfileLinks.normalize(typed) }
    }

    @Test(arguments: [
        "https://user:pass@example.com", "https://example.com@evil.com", "https://localhost", "https://192.168.1.1",
        "https://exa mple.com", "https://-bad.com", "not a link", "https://",
    ])
    func refusesMalformed(_ typed: String) {
        #expect(throws: ProfileLinks.Problem.self) { try ProfileLinks.normalize(typed) }
    }

    @Test func unsafeCharactersAreEncodedNotKept() throws {
        #expect(try ProfileLinks.normalize("https://example.com/<script>") == "https://example.com/%3Cscript%3E")
    }

    @Test func refusesLongAndEmpty() {
        #expect(throws: ProfileLinks.Problem.tooLong) { try ProfileLinks.normalize("https://example.com/" + String(repeating: "a", count: 200)) }
        #expect(throws: ProfileLinks.Problem.empty) { try ProfileLinks.normalize("   ") }
    }

    @Test func listsDropBlanksAndRepeatsAndStopAtFive() throws {
        #expect(try ProfileLinks.normalize(all: ["a.com", "", "https://A.com", "b.com"]) == ["https://a.com", "https://b.com"])
        let six = (1...6).map { "site\($0).com" }
        #expect(throws: ProfileLinks.Problem.tooMany) { try ProfileLinks.normalize(all: six) }
        #expect(try ProfileLinks.normalize(all: Array(six.prefix(5))).count == 5)
    }

    @Test func serverLinksAreCheckedAgainBeforeShowing() {
        let shown = ProfileLinks.safe(["https://ok.com/me", "javascript:alert(1)", "http://plain.com", "https://UPPER.com", "https://a.com@b.com"])
        #expect(shown.map(\.absoluteString) == ["https://ok.com/me"])
        #expect(ProfileLinks.safe(nil).isEmpty)
        #expect(ProfileLinks.safe((1...9).map { "https://s\($0).com" }).count == 5)
    }

    @Test func chipsShowTheSiteNotTheAddress() throws {
        #expect(ProfileLinks.domain(of: try #require(URL(string: "https://www.example.com/a/b?x=1"))) == "example.com")
        #expect(ProfileLinks.domain(of: try #require(URL(string: "https://blog.example.com"))) == "blog.example.com")
    }
}

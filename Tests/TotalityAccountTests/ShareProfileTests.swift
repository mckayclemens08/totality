import Foundation
import Testing
import TotalityCore
@testable import TotalityAccount

@Suite struct ProfileLinkTests {
    @Test func theWebLinkIsTheUsernameOnTheDomain() {
        #expect(ProfileLink.web(for: "McKay").absoluteString == "https://usetotality.com/@mckay")
    }

    @Test(arguments: [
        ("totality://profile/dana_w", "dana_w"),
        ("totality://profile/Dana_W", "dana_w"),
        ("https://usetotality.com/@mckay", "mckay"),
    ])
    func readsBothKindsOfLink(link: String, username: String) throws {
        #expect(ProfileLink.username(in: try #require(URL(string: link))) == username)
    }

    @Test(arguments: [
        "totality://profile/", "totality://profile/ab", "totality://profile/a/b", "totality://other/mckay",
        "totality://profile/..", "https://elsewhere.example/@mckay", "http://usetotality.com/@mckay",
        "https://usetotality.com/mckay", "https://usetotality.com/@mckay/more", "mailto:mckay@usetotality.com",
    ])
    func ignoresAnythingElse(link: String) throws {
        #expect(ProfileLink.username(in: try #require(URL(string: link))) == nil)
    }

    @Test func theCodeHoldsTheLink() throws {
        let image = try #require(ProfileQRCode.mask(for: ProfileLink.web(for: "mckay")))
        #expect(image.width > 20 && image.width == image.height)
    }
}

@MainActor
@Suite struct ShareProfileModelTests {
    @Test("Nothing is on the web until sharing, and stopping takes it down")
    func sharingIsAChoice() async {
        let service = FakeAccountService(username: "mckay")
        let model = AccountModel(service: service)
        await model.load()
        #expect(model.webPage == false)
        #expect(await service.pageChanges.isEmpty)
        #expect(await model.setWebPage(published: true))
        #expect(model.webPage == true)
        #expect(await model.setWebPage(published: false))
        #expect(model.webPage == false)
        #expect(await service.pageChanges == [true, false])
    }

    @Test("A change to the profile goes up only when the page is up")
    func editsRefreshAPublishedPage() async {
        let service = FakeAccountService(username: "mckay")
        let model = AccountModel(service: service)
        await model.load()
        _ = await model.saveProfile(displayName: "McKay Clemens", bio: "")
        #expect(await service.pageChanges.isEmpty)
        await model.setWebPage(published: true)
        _ = await model.saveProfile(displayName: "McKay C.", bio: "Building Totality in Utah.")
        #expect(await service.pageChanges == [true, true])
    }

    @Test("A page that can't go up says why and can be tried again")
    func failureIsRecoverable() async {
        let service = FakeAccountService(username: "mckay")
        let model = AccountModel(service: service)
        await model.load()
        await service.failPage(.offline)
        #expect(await model.setWebPage(published: true) == false)
        #expect(model.webPage == false)
        #expect(model.webPageProblem == AccountError.offline.message)
        await service.failPage(nil)
        #expect(await model.setWebPage(published: true))
        #expect(model.webPageProblem == nil)
    }

    @Test("Signing out forgets whether the page was up")
    func signOutForgets() async {
        let service = FakeAccountService(username: "mckay")
        let model = AccountModel(service: service)
        await model.load()
        await model.setWebPage(published: true)
        await model.signOut()
        #expect(model.webPage == nil)
    }

    @Test("Another person's profile opens by username, and a bad one finds nothing")
    func looksUpOthers() async throws {
        let service = FakeAccountService(username: "mckay")
        await service.addOther(Profile(username: "dana_w", displayName: "Dana Whitfield", bio: "Trail runner."))
        let model = AccountModel(service: service)
        await model.load()
        #expect(try await model.lookUp("Dana_W")?.displayName == "Dana Whitfield")
        #expect(try await model.lookUp("nobody_here") == nil)
        #expect(try await model.lookUp("../x") == nil)
    }
}

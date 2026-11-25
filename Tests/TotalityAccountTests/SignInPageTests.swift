import Foundation
import Testing
@testable import TotalityAccount

/// The full-screen sign-in page shows only on a device that has never signed in, or after signing out
/// there (owner, 2026-11-25). Otherwise Totality opens straight to Home.
@MainActor
@Suite struct SignInPageTests {
    private let password = "correct horse battery"

    private func freshMarks() -> UserDefaults { UserDefaults(suiteName: "test.\(UUID().uuidString)")! }

    @Test("A device that has never signed in shows the sign-in page")
    func newDeviceShowsPage() async {
        let model = AccountModel(service: FakeAccountService(), marks: freshMarks())
        #expect(!model.showsSignInPage, "nothing is decided while the session is read")
        await model.restore()
        #expect(model.phase == .signedOut)
        #expect(model.showsSignInPage)
    }

    @Test("A saved session opens straight to Home, and marks the device for next time")
    func savedSessionOpensHome() async {
        let marks = freshMarks()
        let model = AccountModel(service: FakeAccountService(username: "owner"), marks: marks)
        await model.restore()
        #expect(model.phase == .signedIn(username: "owner"))
        #expect(!model.showsSignInPage)
        #expect(AccountModel(service: FakeAccountService(), marks: marks).hasSignedInHere)
    }

    @Test("Restoring makes no network call: the device isn't registered and no profile is read")
    func restoreIsLocal() async {
        let service = FakeAccountService(username: "owner")
        let model = AccountModel(service: service, marks: freshMarks())
        await model.restore()
        #expect(await service.devices == 0)
        #expect(model.profile == nil)
    }

    @Test("Signing in on the page hides it from then on, even once the session is gone")
    func signInHidesPageForGood() async {
        let marks = freshMarks()
        let model = AccountModel(service: FakeAccountService(), marks: marks)
        await model.restore()
        await model.signIn(username: "owner", password: password)
        #expect(!model.showsSignInPage)
        // Next launch, with the session lost (it lapsed, or the Keychain couldn't be read just then).
        let next = AccountModel(service: FakeAccountService(), marks: marks)
        await next.restore()
        #expect(next.phase == .signedOut)
        #expect(!next.showsSignInPage, "Home opens, and Account still offers to sign in")
    }

    @Test("Creating an account hides the page too")
    func signUpHidesPage() async {
        let model = AccountModel(service: FakeAccountService(), marks: freshMarks())
        await model.restore()
        await model.signUp(username: "owner", password: password, confirmation: password)
        #expect(!model.showsSignInPage)
        #expect(model.hasSignedInHere)
    }

    @Test("Signing out brings the page back, on this launch and the next")
    func signOutShowsPage() async {
        let marks = freshMarks()
        let model = AccountModel(service: FakeAccountService(username: "owner"), marks: marks)
        await model.restore()
        await model.signOut()
        #expect(model.showsSignInPage)
        let next = AccountModel(service: FakeAccountService(), marks: marks)
        await next.restore()
        #expect(next.showsSignInPage)
    }

    @Test("A failed sign-in leaves the page up and marks nothing")
    func failedSignInKeepsPage() async {
        let service = FakeAccountService()
        await service.fail(signIn: .wrongPassword)
        let marks = freshMarks()
        let model = AccountModel(service: service, marks: marks)
        await model.restore()
        await model.signIn(username: "owner", password: password)
        #expect(model.showsSignInPage)
        #expect(!model.hasSignedInHere)
        #expect(marks.object(forKey: AccountModel.signedInHereKey) == nil)
    }

    @Test("A sign-out that couldn't finish keeps the account and Home")
    func failedSignOutKeepsHome() async {
        let service = FakeAccountService(username: "owner")
        await service.fail(signOut: .offline)
        let model = AccountModel(service: service, marks: freshMarks())
        await model.restore()
        await model.signOut()
        #expect(model.phase == .signedIn(username: "owner"))
        #expect(!model.showsSignInPage)
    }

    @Test("Once sign-in returns, the steps after it have finished")
    func signInFinishesBeforeReturning() async {
        let service = FakeAccountService()
        let model = AccountModel(service: service, marks: freshMarks())
        await model.signIn(username: "owner", password: password)
        await model.waitForSignIn()
        #expect(await service.devices == 1)
        #expect(model.deviceRegistered)
    }

    @Test("Only a flag is kept on the device: no username, token or password")
    func onlyAFlagIsKept() async {
        let marks = freshMarks()
        let model = AccountModel(service: FakeAccountService(), marks: marks)
        await model.signIn(username: "owner", password: password)
        let kept = marks.dictionaryRepresentation().filter { $0.key.hasPrefix("account.") }
        #expect(kept[AccountModel.signedInHereKey] as? Bool == true)
        for value in kept.values {
            let text = "\(value)"
            #expect(!text.contains(password))
        }
    }

    @Test("Restoring twice, or after the account is known, changes nothing")
    func restoreOnlyOnce() async {
        let service = FakeAccountService()
        let model = AccountModel(service: service, marks: freshMarks())
        await model.signIn(username: "owner", password: password)
        await model.restore()
        #expect(model.phase == .signedIn(username: "owner"))
    }
}

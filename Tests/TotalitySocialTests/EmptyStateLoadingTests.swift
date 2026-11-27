import Foundation
import Testing
import TotalityCore
@testable import TotalitySocial

/// "Nothing here" must only show once loading has finished and found nothing (owner, 2026-11-26).
@MainActor
@Suite struct EmptyStateLoadingTests {
    let world = FakeSocialWorld()
    let matrix = FakeServer()

    @Test func theEmptyTextIsNeverShownWhileLoading() {
        #expect(!SocialModel.showsEmpty(loaded: false, count: 0), "still loading, no posts yet")
        #expect(SocialModel.showsEmpty(loaded: true, count: 0), "finished and found nothing")
        #expect(!SocialModel.showsEmpty(loaded: true, count: 3))
        #expect(!SocialModel.showsEmpty(loaded: false, count: 3))
    }

    @Test func savedIsNotLoadedUntilItsFirstFetchEnds() async {
        let model = SocialModel(server: world.person("maya"), privateRooms: matrix.device(for: "maya"))
        #expect(!model.savedLoaded)
        await model.load()
        await model.loadSaved()
        #expect(model.savedLoaded && model.saved.isEmpty)
    }

    @Test func theFeedIsNotLoadingOnceLoadReturns() async {
        let model = SocialModel(server: world.person("maya"), privateRooms: matrix.device(for: "maya"))
        await model.load()
        #expect(!model.isLoading)
    }

    @Test("A profile's last page shows at once and is kept in memory only, never in the saved defaults")
    func profilePagesAreCachedInMemoryOnly() async throws {
        let defaults = try #require(UserDefaults(suiteName: "social.empty-state." + UUID().uuidString))
        let maya = SocialModel(server: world.person("maya"), privateRooms: matrix.device(for: "maya"), remembered: defaults)
        let jonah = SocialModel(server: world.person("jonah"), privateRooms: matrix.device(for: "jonah"))
        for (a, b) in [(jonah, "maya"), (maya, "jonah")] { await a.load(); _ = await a.setFollowing(true, b) }
        #expect(maya.cachedPosts(by: "maya") == nil)
        #expect(await maya.publish(.friends, title: "", body: "The spare key is under the fern."))
        #expect(await maya.publish(.everyone, title: "", body: "Frost on the boardwalk."))
        let page = try await maya.posts(by: "maya")
        #expect(page.count == 2)
        #expect(maya.cachedPosts(by: "MAYA")?.count == 2, "found whatever the capitals")
        let stored = defaults.dictionaryRepresentation().description
        #expect(!stored.contains("fern") && !stored.contains("boardwalk"), "no post text is written to disk")
    }
}

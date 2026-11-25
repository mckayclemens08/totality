import Foundation
import Testing
@testable import TotalitySocial

/// Social's media moved from Supabase Storage to Totality's own server (2026-11-25). Older posts keep
/// reading from the old bucket, and a removal that fails is never silently forgotten.
@MainActor
@Suite struct SocialMediaMoveTests {
    let world = FakeSocialWorld()

    @Test func newFilesGoToTotalitysServer() async throws {
        let maya = SocialModel(server: world.person("maya"))
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 400, height: 300))
        #expect(await maya.publish(.everyone, title: "", body: "Bridge at noon", attachments: [photo]))
        let post = try #require(world.posts.values.first?.post)
        #expect(!post.media.isEmpty && post.media.allSatisfy { $0.store == .totality })
        #expect(world.oldFiles.isEmpty)
    }

    @Test func postsFromBeforeTheMoveStillReadFromTheOldBucket() async throws {
        let json = #"{"kind":"photo","path":"\#(UUID().uuidString.lowercased())/\#(UUID().uuidString.lowercased())","size":3}"#
        let old = try JSONDecoder().decode(PostMedia.self, from: Data(json.utf8))
        #expect(old.store == nil, "media written before the move carry no store")
        world.oldFiles[old.path] = Data([1, 2, 3])
        let maya = SocialModel(server: world.person("maya"))
        #expect(try await maya.mediaData(old) == Data([1, 2, 3]))
    }

    @Test func theStoreIsWrittenAndAnOldEntryStaysWithoutOne() throws {
        let path = UUID().uuidString.lowercased() + "/" + UUID().uuidString.lowercased()
        let new = String(decoding: try JSONEncoder().encode(PostMedia(kind: .photo, path: path, size: 1)), as: UTF8.self)
        #expect(new.contains(#""store":"totality""#))
        let old = String(decoding: try JSONEncoder().encode(PostMedia(kind: .photo, path: path, size: 1, store: nil)), as: UTF8.self)
        #expect(!old.contains("store"))
    }

    @Test func oldFilesAreRemovedFromTheOldBucket() async throws {
        let path = world.id("maya").uuidString.lowercased() + "/" + UUID().uuidString.lowercased()
        world.oldFiles[path] = Data([1])
        let maya = SocialModel(server: world.person("maya"))
        await maya.load()
        await maya.removeMedia([PostMedia(kind: .photo, path: path, size: 1, store: nil)])
        #expect(world.oldFiles.isEmpty)
    }

    @Test func aRemovalThatFailsIsTriedAgainOnTheNextLoad() async throws {
        let defaults = try #require(UserDefaults(suiteName: "social.test." + UUID().uuidString))
        let maya = SocialModel(server: world.person("maya"), remembered: defaults)
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 400, height: 300))
        #expect(await maya.publish(.everyone, title: "", body: "", attachments: [photo]))
        let post = try #require(maya.following.first)
        world.removalsFail = true
        await maya.delete(post)
        #expect(world.posts.isEmpty)
        #expect(world.files.count == 1, "the server couldn't be reached")
        #expect(maya.leftoverMedia().map(\.path) == post.media.map(\.path), "remembered, not dropped")

        await maya.load()
        #expect(world.files.count == 1 && maya.leftoverMedia().count == 1, "still failing, still remembered")
        world.removalsFail = false
        await maya.load()
        #expect(world.files.isEmpty && maya.leftoverMedia().isEmpty)
    }

    @Test func aSealedFilesKeyIsNeverRememberedForRetrying() async throws {
        let defaults = try #require(UserDefaults(suiteName: "social.test." + UUID().uuidString))
        let maya = SocialModel(server: world.person("maya"), remembered: defaults)
        await maya.load()
        world.removalsFail = true
        let path = world.id("maya").uuidString.lowercased() + "/" + UUID().uuidString.lowercased()
        let (_, key) = try MediaSeal.seal(Data([9]))
        await maya.removeMedia([PostMedia(kind: .audio, path: path, size: 29, key: key)])
        #expect(maya.leftoverMedia().count == 1 && maya.leftoverMedia().allSatisfy { $0.key == nil })
        let stored = try #require(defaults.data(forKey: "social.leftoverMedia.maya"))
        #expect(!String(decoding: stored, as: UTF8.self).contains(key))
    }
}

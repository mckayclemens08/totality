import CoreGraphics
import Foundation
import ImageIO
import Testing
import TotalityCore
import UniformTypeIdentifiers
@testable import TotalitySocial

/// A JPEG of `width`×`height`, with a GPS tag that posting must leave off.
func sampleJPEG(width: Int = 3000, height: Int = 2000) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.6, green: 0.7, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 40.76, kCGImagePropertyGPSLatitudeRef: "N"]
    CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return out as Data
}

let folder = "0b6c2f7e-35d4-4d5c-9a51-6f3a1a0c9e21"
func path() -> String { folder + "/" + UUID().uuidString.lowercased() }

@Suite struct PostMediaTests {
    @Test func photosAreShrunkAndLoseWhereTheyWereTaken() throws {
        let photo = try Attachment.photo(sampleJPEG())
        #expect(photo.kind == .photo && photo.contentType == "image/jpeg")
        #expect(max(photo.width ?? 0, photo.height ?? 0) == MediaLimits.photoSide)
        #expect(photo.data.count <= MediaLimits.photoBytes)
        let source = try #require(CGImageSourceCreateWithData(photo.data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
        #expect(throws: SocialError.self) { try Attachment.photo(Data("not a photo".utf8)) }
    }

    @Test func sealingOpensOnlyWithItsOwnKey() throws {
        let clip = Data("a voice clip".utf8)
        let (sealed, key) = try MediaSeal.seal(clip)
        #expect(sealed != clip && sealed.count == clip.count + MediaLimits.sealOverhead)
        #expect(try MediaSeal.open(sealed, key: key) == clip)
        let (_, other) = try MediaSeal.seal(clip)
        #expect(other != key, "every file gets a fresh key")
        #expect(throws: SocialError.self) { try MediaSeal.open(sealed, key: other) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        #expect(throws: SocialError.self) { try MediaSeal.open(tampered, key: key) }
        #expect(throws: SocialError.self) { try MediaSeal.open(sealed, key: "short") }
    }

    @Test func limitsMatchTheServer() throws {
        let photo = PostMedia(kind: .photo, path: path(), size: 300_000, width: 1600, height: 1200)
        let audio = PostMedia(kind: .audio, path: path(), size: 900_000, duration: 95)
        #expect(MediaLimits.problem(Array(repeating: photo, count: 4), encrypted: false) == nil)
        #expect(MediaLimits.problem(Array(repeating: photo, count: 5), encrypted: false) != nil)
        #expect(MediaLimits.problem([audio], encrypted: false) == nil)
        #expect(MediaLimits.problem([audio, photo], encrypted: false) != nil)
        #expect(MediaLimits.problem([audio, audio], encrypted: false) != nil)
        var long = audio
        long.duration = 300
        #expect(MediaLimits.problem([long], encrypted: false) != nil)
        #expect(MediaLimits.problem([PostMedia(kind: .photo, path: "../etc/passwd", size: 1)], encrypted: false) != nil)
        #expect(MediaLimits.problem([PostMedia(kind: .photo, path: path(), size: MediaLimits.fileBytes * 2)], encrypted: false) != nil)
        // Sealed exactly when the post is encrypted.
        #expect(MediaLimits.problem([photo], encrypted: true) != nil)
        var sealed = photo
        sealed.key = try MediaSeal.seal(Data()).key
        #expect(MediaLimits.problem([sealed], encrypted: true) == nil)
        #expect(MediaLimits.problem([sealed], encrypted: false) != nil)
        #expect(PostLimits.problem(title: "", body: "", hasMedia: true) == nil)
        #expect(PostLimits.problem(title: "", body: "") == "Write something first.")
    }

    @Test func theServerIsNeverToldAKey() throws {
        var item = PostMedia(kind: .audio, path: path(), size: 10, duration: 4)
        item.key = try MediaSeal.seal(Data()).key
        let json = String(decoding: try JSONEncoder().encode(item.forServer), as: UTF8.self)
        #expect(!json.contains("key"))
        #expect(json.contains("\"duration\":4"))
    }

    @Test func roomPostsCarryKeysInsideTheEncryption() throws {
        var item = PostMedia(kind: .photo, path: path(), size: 1234, width: 1600, height: 900)
        item.key = try MediaSeal.seal(Data()).key
        let message = RoomMessage.post(id: UUID(), title: nil, body: "", tags: [], date: Date(timeIntervalSince1970: 1_795_000_000), media: [item])
        #expect(RoomMessage(message.encoded) == message)
        // A room post whose file isn't sealed, or that breaks the limits, is ignored.
        let plain = RoomMessage.post(id: UUID(), title: nil, body: "hi", tags: [], date: Date(), media: [item.forServer])
        #expect(RoomMessage(plain.encoded) == nil)
        let tooMany = RoomMessage.post(id: UUID(), title: nil, body: "hi", tags: [], date: Date(), media: Array(repeating: item, count: 5))
        #expect(RoomMessage(tooMany.encoded) == nil)
        // Text-only posts are unchanged on the wire.
        #expect(!RoomMessage.post(id: UUID(), title: nil, body: "hi", tags: [], date: Date()).encoded.contains("media"))
    }

    @Test func publicRowsReadMediaButNeverKeys() throws {
        let p = path()
        let json = """
        [{"id":"\(UUID().uuidString)","handle":"maya","display_name":null,"title":null,"body":"","tags":[],
          "created_at":"2026-11-21T10:00:00.000Z","edited_at":null,"likes":3,"comments":0,"liked":false,"reason":"","saved":false,
          "media":[{"kind":"photo","path":"\(p)","size":2000,"width":1600,"height":1200}]},
         {"id":"\(UUID().uuidString)","handle":"maya","display_name":null,"title":"Old","body":"x","tags":[],
          "created_at":"2026-11-21T10:00:00.000Z","edited_at":null,"likes":3,"comments":0,"liked":false,"reason":"","saved":false}]
        """
        let rows = try JSONDecoder().decode([RestSocialServer.PostRow].self, from: Data(json.utf8))
        #expect(rows[0].post.photos.map(\.path) == [p])
        #expect(rows[0].post.headline == "Photo")
        #expect(rows[1].post.media.isEmpty)
    }

    @Test func theFolderComesFromTheSignIn() {
        let payload = Data(#"{"sub":"0B6C2F7E-35D4-4D5C-9A51-6F3A1A0C9E21","role":"authenticated"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        #expect(RestSocialServer.account(fromToken: "e30.\(payload).sig") == folder)
        #expect(RestSocialServer.account(fromToken: "nonsense") == nil)
    }

    @Test func clipTimes() {
        #expect(ClipTime.text(0) == "0:00")
        #expect(ClipTime.text(98.7) == "1:38")
        #expect(ClipTime.text(120) == "2:00")
    }
}

@MainActor
@Suite struct SocialMediaModelTests {
    let world = FakeSocialWorld()
    let matrix = FakeServer()

    @Test func publicPhotosAreStoredReadable() async throws {
        let maya = SocialModel(server: world.person("maya"))
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 800, height: 600))
        #expect(await maya.publish(.everyone, title: "", body: "Trailhead at dawn", attachments: [photo, photo]))
        let post = try #require(world.posts.values.first?.post)
        #expect(post.photos.count == 2 && post.media.allSatisfy { !$0.isSealed })
        #expect(world.files[post.photos[0].path] == photo.data, "a public photo is stored as it is, for For You")
        #expect(try await maya.mediaData(post.photos[0]) == photo.data)
    }

    @Test func friendsAudioIsSealedAndItsKeyStaysInTheRoom() async throws {
        let maya = SocialModel(server: world.person("maya"), privateRooms: matrix.device(for: "maya"))
        await maya.load()
        let clip = Attachment(kind: .audio, data: Data(repeating: 7, count: 5000), duration: 12)
        #expect(await maya.publish(.friends, title: "Voice note", body: "", attachments: [clip]))
        #expect(world.posts.isEmpty)
        let stored = try #require(world.files.values.first)
        #expect(stored != clip.data && stored.count == clip.data.count + MediaLimits.sealOverhead)
        let post = try #require(maya.following.first)
        let audio = try #require(post.audio)
        #expect(audio.isSealed && audio.duration == 12)
        #expect(try await maya.mediaData(audio) == clip.data)
    }

    @Test func aFailedPostLeavesNoFilesBehind() async throws {
        // No Messages on this device, so a Friends post can't go; nothing it uploaded may stay.
        let maya = SocialModel(server: world.person("maya"))
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 400, height: 300))
        #expect(await maya.publish(.friends, title: "", body: "", attachments: [photo]) == false)
        #expect(world.files.isEmpty)
        #expect(maya.notice != nil)
    }

    @Test func deletingAPostRemovesItsFiles() async throws {
        let maya = SocialModel(server: world.person("maya"))
        await maya.load()
        let photo = try Attachment.photo(sampleJPEG(width: 400, height: 300))
        #expect(await maya.publish(.everyone, title: "", body: "", attachments: [photo]))
        let post = try #require(maya.following.first)
        await maya.delete(post)
        #expect(world.files.isEmpty && world.posts.isEmpty)
    }
}

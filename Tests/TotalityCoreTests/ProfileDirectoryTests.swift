import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TotalityCore

// Other people's photos come from a public bucket anyone can write their own folder of, so each test
// here is a file someone could put there.

private func picture(width: Int, height: Int, as type: UTType, gps: Bool = false) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [:]
    if gps {
        properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 40.2338, kCGImagePropertyGPSLongitude: 111.6585]
    }
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
}

private func size(of data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

@Test func aRealJPEGIsRebuiltAsASmallSquare() throws {
    let rebuilt = try #require(SafeAvatar.prepare(picture(width: 1200, height: 800, as: .jpeg)))
    #expect(SafeAvatar.kind(of: rebuilt) == .jpeg)
    let (width, height) = try #require(size(of: rebuilt))
    #expect(width == SafeAvatar.side && height == SafeAvatar.side)
}

@Test func aPNGIsRebuiltAsAJPEG() throws {
    let rebuilt = try #require(SafeAvatar.prepare(picture(width: 300, height: 300, as: .png)))
    #expect(SafeAvatar.kind(of: rebuilt) == .jpeg)
}

@Test func whereAPhotoWasTakenDoesntSurvive() throws {
    let original = picture(width: 600, height: 600, as: .jpeg, gps: true)
    let before = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(original as CFData, nil)!, 0, nil) as? [CFString: Any]
    #expect(before?[kCGImagePropertyGPSDictionary] != nil)
    let rebuilt = try #require(SafeAvatar.prepare(original))
    let after = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(rebuilt as CFData, nil)!, 0, nil) as? [CFString: Any]
    #expect(after?[kCGImagePropertyGPSDictionary] == nil)
}

@Test func aFakePhotoThatIsntAJPEGShowsInitials() {
    // Named .jpg and uploaded as image/jpeg, which is all the bucket checks.
    let page = Data("<html><script>alert(1)</script></html>".utf8)
    #expect(SafeAvatar.prepare(page) == nil)
    #expect(SafeAvatar.prepare(picture(width: 64, height: 64, as: .gif)) == nil)
    #expect(SafeAvatar.prepare(Data()) == nil)
}

@Test func aJPEGStartThatIsntAPictureIsRefused() {
    var broken = Data([0xFF, 0xD8, 0xFF, 0xE0])
    broken.append(Data(repeating: 0x41, count: 2000))
    #expect(SafeAvatar.prepare(broken) == nil)
}

@Test func aHugeCanvasIsRefusedBeforeDecoding() {
    #expect(SafeAvatar.prepare(picture(width: SafeAvatar.maximumEdge + 1, height: 8, as: .png)) == nil)
    #expect(SafeAvatar.prepare(picture(width: 8, height: SafeAvatar.maximumEdge + 1, as: .png)) == nil)
}

@Test func aVeryWidePictureStillComesOutSquare() throws {
    let rebuilt = try #require(SafeAvatar.prepare(picture(width: 4000, height: 20, as: .png)))
    let (width, height) = try #require(size(of: rebuilt))
    #expect(width == height)
}

@Test func anOversizedFileIsDroppedUnread() {
    var big = picture(width: 64, height: 64, as: .jpeg)
    big.append(Data(count: SafeAvatar.maximumBytes))
    #expect(SafeAvatar.prepare(big) == nil)
}

@Test func initialsComeFromUpToTwoWords() {
    #expect(PublicProfile.initials(of: "Ana Ruiz") == "AR")
    #expect(PublicProfile.initials(of: "mckay_clemens") == "MC")
    #expect(PublicProfile.initials(of: "ana") == "A")
    #expect(PublicProfile.initials(of: "Mary Jo Lake") == "MJ")
    #expect(PublicProfile.initials(of: "  ") == "?")
}

@Test func aProfileGoesByItsNameOrItsHandle() {
    #expect(PublicProfile(username: "ana_ruiz", displayName: "Ana Ruiz", bio: nil, photo: nil).name == "Ana Ruiz")
    #expect(PublicProfile(username: "ana_ruiz", displayName: nil, bio: nil, photo: nil).name == "ana_ruiz")
    #expect(PublicProfile(username: "ana_ruiz", displayName: "  ", bio: nil, photo: nil).name == "ana_ruiz")
}

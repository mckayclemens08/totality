import Foundation
import Testing
import TotalityCore
@testable import TotalityPhotos

/// docs/photos-vectors.json is made by the real PhotoSealer, and the website's tests open it.
@Suite struct PhotosWebVectorsTests {
    struct Entry: Codable { let id, owner, details, thumbBlob, thumb, thumbPlain, originalBlob, original, originalPlain: String }
    struct Vectors: Codable { let note: String; let rootKey: String; let entries: [Entry] }

    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/photos-vectors.json")
    let key = try! ContentRootKey(bytes: Data((0..<32).map { UInt8(100 + $0) }))

    @Test func committedVectorsOpen() throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.path))
        let sealer = PhotoSealer(rootKey: key)
        for entry in vectors.entries {
            let id = try #require(UUID(uuidString: entry.id))
            #expect(try sealer.open(Data(base64Encoded: entry.thumb)!, .thumbnail, of: id) == Data(base64Encoded: entry.thumbPlain)!)
            #expect(try sealer.open(Data(base64Encoded: entry.original)!, .original, of: id) == Data(base64Encoded: entry.originalPlain)!)
            #expect(try sealer.open(Data(base64Encoded: entry.details)!, .details, of: id).count > 10)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOTALITY_MAKE_VECTORS"] != nil))
    func makeVectors() throws {
        let sealer = PhotoSealer(rootKey: key)
        let owner = "11111111-2222-4333-8444-555555555555"
        var entries: [Entry] = []
        for (i, type) in ["public.jpeg", "public.heic"].enumerated() {
            let id = UUID(), thumbBlob = UUID(), originalBlob = UUID()
            let taken = Date(timeIntervalSince1970: 1_763_000_000 + Double(i) * 86_400)
            var details = PhotoDetails(id: id, owner: owner, original: originalBlob, thumbnail: thumbBlob, added: taken, taken: taken,
                                       width: 4032, height: 3024, type: type, byteCount: 12)
            details.caption = i == 0 ? "Trail crew <b>x</b>" : nil
            details.isFavourite = i == 0
            let thumb = Data((0..<40).map { UInt8(truncatingIfNeeded: $0 &* 7) }), original = Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 3) })
            entries.append(Entry(
                id: id.uuidString.lowercased(), owner: owner, details: try sealer.sealDetails(details).base64EncodedString(),
                thumbBlob: thumbBlob.uuidString.lowercased(), thumb: try sealer.seal(thumb, .thumbnail, of: id).base64EncodedString(), thumbPlain: thumb.base64EncodedString(),
                originalBlob: originalBlob.uuidString.lowercased(), original: try sealer.seal(original, .original, of: id).base64EncodedString(), originalPlain: original.base64EncodedString()))
        }
        let out = Vectors(note: "Made by PhotosWebVectorsTests.makeVectors from the real PhotoSealer. Test key only.",
                          rootKey: (0..<32).map { String(format: "%02x", 100 + $0) }.joined(), entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(out).write(to: Self.path)
    }
}

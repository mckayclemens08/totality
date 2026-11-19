import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

/// docs/reader-web-vectors.json is made by the website (web/site/test/make-reader-vectors.mjs): docs created
/// and saved the way the website does it. Each must open in the real ReaderVault with the details and words it
/// says, with the row hash, body hash and blob name the iPhone would work out, so the browser's writes are
/// exactly the iPhone's.
@Suite struct ReaderWebEditVectorsTests {
    struct Item: Decodable {
        let id, meta, body, hash, bodyHash, blob, owner: String
        let title, text, mime: String
        let byteCount: Int
        let wordTarget: Int?
        let editorOpens: Bool
    }
    struct Vectors: Decodable { let items: [Item] }

    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/reader-web-vectors.json")
    let key = try! ContentRootKey(bytes: Data((0..<32).map { UInt8(100 + $0) }))

    @Test func websiteNotesOpenInTheVault() async throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.path))
        #expect(vectors.items.count >= 3)
        for v in vectors.items {
            let vault = ReaderVault(store: MemoryBlobStore(), rootKey: key)
            let id = try #require(UUID(uuidString: v.id))
            let object = SealedObject(id: id, kind: .note, meta: try #require(Data(base64Encoded: v.meta)), body: try #require(Data(base64Encoded: v.body)))
            #expect(object.hash == v.hash, "row hash is SealedObject.hash")
            #expect(object.bodyHash == v.bodyHash)
            #expect(SealedBlobKey.blob(owner: v.owner, item: id, bodyHash: v.bodyHash).uuidString.lowercased() == v.blob)
            try await vault.store(object, ifLocalHash: nil)
            let item = try await vault.item(id)
            #expect(item.title == v.title)
            #expect(item.kind == .note)
            #expect(item.mime == v.mime)
            #expect(item.byteCount == v.byteCount)
            #expect(item.wordTarget == v.wordTarget)
            #expect(String(decoding: try await vault.body(of: id), as: UTF8.self) == v.text)
            // The writing editor opens it as it is, with no conversion and no kept original.
            if v.editorOpens {
                let (opened, text) = try await vault.markdown(of: id)
                #expect(text == v.text)
                #expect(opened.keptOriginalID == nil)
                #expect(opened.updatedAt == item.updatedAt)
            }
        }
    }
}

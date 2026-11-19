import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

/// docs/reader-vectors.json is made by the real vault, and web/site/test/reader.test.mjs opens it with the
/// website's code, so what the iPhone seals is provably what the browser reads. If the format changes,
/// the committed vector stops opening here and has to be made again, which tells the website too.
@Suite struct WebVectorsTests {
    struct Entry: Codable { let id, meta, body: String; let title, text: String; let kind, mime: String }
    struct Vectors: Codable { let note: String; let rootKey: String; let entries: [Entry] }

    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/reader-vectors.json")
    let key = try! ContentRootKey(bytes: Data((0..<32).map { UInt8(100 + $0) }))

    @Test func committedVectorsOpenInTheVault() async throws {
        let data = try Data(contentsOf: Self.path)
        let vectors = try JSONDecoder().decode(Vectors.self, from: data)
        let vault = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        for entry in vectors.entries {
            let id = try #require(UUID(uuidString: entry.id))
            let object = SealedObject(id: id, kind: .note, meta: Data(base64Encoded: entry.meta)!, body: Data(base64Encoded: entry.body)!)
            try await vault.store(object, ifLocalHash: nil)
            #expect(try await vault.item(id).title == entry.title)
            #expect(String(decoding: try await vault.body(of: id), as: UTF8.self) == entry.text)
        }
    }

    /// Run by hand to make the vectors again: TOTALITY_MAKE_VECTORS=1 swift test --filter makeVectors
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOTALITY_MAKE_VECTORS"] != nil))
    func makeVectors() async throws {
        let vault = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        var entries: [Entry] = []
        let texts = [
            ("Seminar paper draft", "# Seminar paper draft\n\nThe state is the *actuality* of the ethical Idea.\n\n- first point\n- second point\n\nSee **Hegel**, § 257. Ünïcode ✓ <b>not html</b>"),
            ("Plain note", "Just words, no markup.\nTwo lines."),
        ]
        for (title, text) in texts {
            let created = try await vault.createNote(title: title)
            _ = try await vault.saveNote(created.id, title: title, body: text)
            let object = try #require(try await vault.sealedObject(created.id))
            entries.append(Entry(
                id: created.id.uuidString.lowercased(), meta: object.meta.base64EncodedString(),
                body: object.body!.base64EncodedString(), title: title, text: text, kind: "note", mime: MarkdownText.mime
            ))
        }
        let out = Vectors(note: "Made by WebVectorsTests.makeVectors from the real ReaderVault. Test key only.", rootKey: (0..<32).map { String(format: "%02x", 100 + $0) }.joined(), entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(out).write(to: Self.path)
    }
}

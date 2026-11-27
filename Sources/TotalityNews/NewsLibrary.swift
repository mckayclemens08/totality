import Foundation
import TotalityCore

struct NewsRecord: Codable, Sendable {
    var sources = NewsSource.defaults
    var saved: [NewsArticle] = []
    var latest: [NewsArticle] = []
}

public actor NewsLibrary {
    private static let id = UUID(uuidString: "5AC06741-B38B-4670-A59B-ACCD67AB39CC")!
    private static let suffix = ".news"
    public static let sealedPurposes: [String: KeyPurpose] = [suffix: .news]
    private var name: String { Self.id.uuidString.lowercased() + Self.suffix }
    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var closed = false

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    func read() throws -> NewsRecord {
        guard !closed else { throw CancellationError() }
        guard let sealed = try store.read(name) else { return NewsRecord() }
        let key = rootKey.objectKey(for: Self.id, purpose: .news)
        let data = try ContentCipher.open(sealed, key: key, objectID: Self.id)
        return try JSONDecoder().decode(NewsRecord.self, from: data)
    }

    func update(_ update: @Sendable (inout NewsRecord) -> Void) throws -> NewsRecord {
        var record = try read()
        update(&record)
        let key = rootKey.objectKey(for: Self.id, purpose: .news)
        let sealed = try ContentCipher.seal(JSONEncoder().encode(record), key: key, objectID: Self.id)
        try store.write(sealed, as: name)
        return record
    }

    func close() { closed = true }
}

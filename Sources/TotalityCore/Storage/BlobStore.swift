import Foundation

public enum BlobStoreError: Error, Equatable {
    case invalidName(String)
}

/// Where sealed bytes live. Callers hand it ciphertext only. Supabase Storage will sit behind this
/// same protocol.
public protocol BlobStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ data: Data, as name: String) throws
    func delete(_ name: String) throws
    func names() throws -> [String]
    /// Whether a blob is there, without reading it.
    func exists(_ name: String) throws -> Bool
}

extension BlobStore {
    public func exists(_ name: String) throws -> Bool { try read(name) != nil }
}

/// Blobs as files in one directory. Names are checked so none can leave it.
public struct FileBlobStore: BlobStore {
    private let directory: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    private func url(_ name: String) throws -> URL {
        let allowed = name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "." || $0 == "-"
        }
        guard !name.isEmpty, allowed, !name.hasPrefix(".") else { throw BlobStoreError.invalidName(name) }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Where a file lives, for one too big to read whole. The name is checked like any other.
    public func location(of name: String) throws -> URL {
        try url(name)
    }

    public func read(_ name: String) throws -> Data? {
        let file = try url(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    public func write(_ data: Data, as name: String) throws {
        try data.write(to: url(name), options: .atomic)
    }

    public func exists(_ name: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try url(name).path)
    }

    public func delete(_ name: String) throws {
        let file = try url(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// Dot-files are the system's, like Finder's `.DS_Store`. They can't be blob names, so they're left out.
    public func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
    }
}

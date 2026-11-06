import Foundation
import TotalityCore
@testable import TotalityReader

/// Keeps blobs in memory so a test can read exactly what would reach a disk or a server.
final class MemoryBlobStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
}

func newVault(store: any BlobStore = MemoryBlobStore()) throws -> ReaderVault {
    ReaderVault(store: store, rootKey: try ContentRootKey.generate())
}

@MainActor
final class FakeSpeechEngine: SpeechEngine {
    var onFinish: (() -> Void)?
    var onWord: ((Int) -> Void)?
    var onStatus: ((String?) -> Void)?
    private(set) var spoken: [String] = []
    private(set) var speeds: [Double] = []
    private(set) var prepared: [String?] = []
    private(set) var pauses = 0
    private(set) var resumes = 0
    private(set) var warmUps: [Bool] = []

    func speak(_ text: String, speed: Double) {
        spoken.append(text)
        speeds.append(speed)
    }
    func prepare(_ text: String?) { prepared.append(text) }
    func warmUp(speakingSoon: Bool) { warmUps.append(speakingSoon) }
    func pause() { pauses += 1 }
    func resume() { resumes += 1 }
    func stop() {}
}

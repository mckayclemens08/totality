import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

/// docs/tasks-vectors.json is made by the real TaskVault, and the website's tests open it.
@Suite struct TasksWebVectorsTests {
    struct Entry: Codable { let id, meta, title: String; let kind: String }
    struct Vectors: Codable { let note: String; let rootKey: String; let entries: [Entry] }

    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/tasks-vectors.json")
    let key = try! ContentRootKey(bytes: Data((0..<32).map { UInt8(100 + $0) }))

    @Test func committedVectorsOpenInTheVault() async throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.path))
        let vault = TaskVault(store: MemoryBlobs(), rootKey: key)
        for entry in vectors.entries {
            let id = try #require(UUID(uuidString: entry.id))
            let kind: ContentKind = entry.kind == "task" ? .task : .taskList
            try await vault.store(SealedObject(id: id, kind: kind, meta: Data(base64Encoded: entry.meta)!, body: nil), ifLocalHash: nil)
            if kind == .task { #expect(try await vault.task(id).title == entry.title) } else { #expect(try await vault.list(id).name == entry.title) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOTALITY_MAKE_VECTORS"] != nil))
    func makeVectors() async throws {
        let vault = TaskVault(store: MemoryBlobs(), rootKey: key)
        let made = Date(timeIntervalSinceReferenceDate: 785_000_000)
        let school = TaskList(name: "School", kind: .area, createdAt: made)
        try await vault.save(school)
        var today = TaskItem(title: "Finish Hegel paper, section 2", notes: "Rework the move from **family** to civil society.", place: .anytime,
                             when: TaskDay(year: 2026, month: 11, day: 18), time: TaskTime(hour: 14), checklist: [
                                .init(title: "Reread §§ 182–188", isDone: true), .init(title: "Outline the system of needs")],
                             tags: ["school/thesis"], priority: .high, listID: school.id, createdAt: made)
        today.repeatRule = nil
        let someday = TaskItem(title: "Learn <i>Greek</i>", place: .someday, createdAt: made)
        let done = TaskItem(title: "Call Dad", place: .anytime, createdAt: made, completedAt: made.addingTimeInterval(60))
        var entries: [Entry] = []
        for task in [today, someday, done] {
            try await vault.save(task)
            let object = try #require(try await vault.sealedObject(task.id))
            entries.append(Entry(id: task.id.uuidString.lowercased(), meta: object.meta.base64EncodedString(), title: task.title, kind: "task"))
        }
        let listObject = try #require(try await vault.sealedObject(school.id))
        entries.append(Entry(id: school.id.uuidString.lowercased(), meta: listObject.meta.base64EncodedString(), title: school.name, kind: "task_list"))
        let out = Vectors(note: "Made by TasksWebVectorsTests.makeVectors from the real TaskVault. Test key only.",
                          rootKey: (0..<32).map { String(format: "%02x", 100 + $0) }.joined(), entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(out).write(to: Self.path)
    }
}

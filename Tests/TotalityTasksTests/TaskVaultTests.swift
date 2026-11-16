import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

@Suite struct TaskVaultTests {
    private func sample() -> TaskItem {
        var task = TaskItem(title: "Email Dr. Lee about thesis chapter 2", notes: "Mention the **corpus** results.",
                            place: .anytime, when: day(2026, 11, 16), deadline: day(2026, 11, 20), tags: ["school"], createdAt: agreed)
        task.checklist = [.init(title: "Attach the draft")]
        return task
    }

    @Test("A task opens again exactly as saved, and nothing of it is readable in storage")
    func sealed() async throws {
        let blobs = MemoryBlobs()
        let vault = TaskVault(store: blobs, rootKey: try .generate())
        let task = sample()
        try await vault.save(task)
        #expect(try await vault.task(task.id) == task)
        let stored = blobs.everything
        for words in ["Dr. Lee", "corpus", "school", "Attach the draft", "2026"] {
            #expect(stored.range(of: Data(words.utf8)) == nil, "\(words) is readable")
        }
        // The blob's name says only its random ID and kind.
        #expect(try blobs.names() == [task.id.uuidString.lowercased() + ".task"])
    }

    @Test("Two-user: user 2's device can't open, accept or merge user 1's sealed task")
    func twoUsers() async throws {
        let one = TaskVault(store: MemoryBlobs(), rootKey: try .generate())
        let twoBlobs = MemoryBlobs()
        let two = TaskVault(store: twoBlobs, rootKey: try .generate())
        let task = sample()
        try await one.save(task)
        let sealed = try #require(try await one.sealedObject(task.id))
        await #expect(throws: CryptoError.self) { try await two.store(sealed, ifLocalHash: nil) }
        #expect(try twoBlobs.names().isEmpty)
        let mine = TaskItem(id: task.id, title: "Something of my own", createdAt: agreed)
        try await two.save(mine)
        let local = try #require(try await two.sealedObject(task.id))
        await #expect(throws: CryptoError.self) { try await two.resolveConflict(local: local, remote: sealed) }
        #expect(try await two.task(task.id).title == "Something of my own")
    }

    @Test("A server can't pass a task off as a list, or a list as a task")
    func kindsStayApart() async throws {
        let key = try ContentRootKey.generate()
        let vault = TaskVault(store: MemoryBlobs(), rootKey: key)
        let other = TaskVault(store: MemoryBlobs(), rootKey: key)
        let task = sample()
        try await vault.save(task)
        let sealed = try #require(try await vault.sealedObject(task.id))
        let relabelled = SealedObject(id: sealed.id, kind: .taskList, meta: sealed.meta, body: nil)
        await #expect(throws: CryptoError.self) { try await other.store(relabelled, ifLocalHash: nil) }
        let elsewhere = SealedObject(id: sealed.id, kind: .event, meta: sealed.meta, body: nil)
        await #expect(throws: CryptoError.self) { try await other.store(elsewhere, ifLocalHash: nil) }
        try await other.store(sealed, ifLocalHash: nil)
        #expect(try await other.task(task.id) == task)

        let list = TaskList(name: "Thesis", kind: .project, createdAt: agreed)
        try await vault.save(list)
        let listObject = try #require(try await vault.sealedObject(list.id))
        #expect(listObject.kind == .taskList)
        #expect(try await vault.list(list.id) == list)
        let asTask = SealedObject(id: list.id, kind: .task, meta: listObject.meta, body: nil)
        await #expect(throws: CryptoError.self) { try await other.store(asTask, ifLocalHash: nil) }
    }

    @Test("A conflict merges part by part: the merged task is kept here and sent on the next sync")
    func conflict() async throws {
        let key = try ContentRootKey.generate()
        let phone = TaskVault(store: MemoryBlobs(), rootKey: key)
        let mac = TaskVault(store: MemoryBlobs(), rootKey: key)
        let task = sample()
        var titled = task
        titled.title = "Email Dr. Lee about chapter 2 and the corpus"
        titled.noteChanges(from: task, at: agreed.addingTimeInterval(60))
        var done = task
        done.completedAt = agreed.addingTimeInterval(120)
        done.noteChanges(from: task, at: agreed.addingTimeInterval(120))
        try await phone.save(titled)
        try await mac.save(done)
        let local = try #require(try await phone.sealedObject(task.id))
        let remote = try #require(try await mac.sealedObject(task.id))
        #expect(try await phone.resolveConflict(local: local, remote: remote) == .keepLocal)
        let merged = try await phone.task(task.id)
        #expect(merged.title == titled.title)
        #expect(merged.isCompleted)
        // The other side, which already has everything after merging, takes the merged one.
        let mergedObject = try #require(try await phone.sealedObject(task.id))
        #expect(try await mac.resolveConflict(local: remote, remote: mergedObject) == .keepRemote)
    }

    @Test("Saving over a version a sync replaced merges instead of undoing the sync")
    func saveOverStale() async throws {
        let vault = TaskVault(store: MemoryBlobs(), rootKey: try .generate())
        let task = sample()
        try await vault.save(task)
        var synced = task
        synced.priority = .high
        synced.noteChanges(from: task, at: agreed.addingTimeInterval(30))
        try await vault.save(synced)
        var screen = task
        screen.notes = "Mention the corpus and the survey."
        screen.noteChanges(from: task, at: agreed.addingTimeInterval(60))
        let saved = try await vault.save(screen, over: task)
        #expect(saved.priority == .high)
        #expect(saved.notes == "Mention the corpus and the survey.")
    }

    @Test("A delete leaves a record, so sync removes it from the server and never brings it back by mistake")
    func deletion() async throws {
        let vault = TaskVault(store: MemoryBlobs(), rootKey: try .generate())
        let task = sample()
        try await vault.save(task)
        try await vault.delete(task.id)
        #expect(try await vault.sealedObjectIDs().isEmpty)
        #expect(try await vault.deletedObjectIDs() == [task.id])
        let listing = try await vault.everything()
        #expect(listing.tasks.isEmpty)
    }

    @Test("A damaged task is counted, not hidden, and the rest still open")
    func damaged() async throws {
        let blobs = MemoryBlobs()
        let vault = TaskVault(store: blobs, rootKey: try .generate())
        let first = sample()
        let second = TaskItem(title: "Book MUN hotel", createdAt: agreed)
        try await vault.save(first)
        try await vault.save(second)
        blobs.corrupt(first.id.uuidString.lowercased() + ".task")
        let listing = try await vault.everything()
        #expect(listing.tasks.map(\.title) == ["Book MUN hotel"])
        #expect(listing.unreadable == 1)
        await #expect(throws: CryptoError.self) { try await vault.verifiedObject(first.id) }
    }

    @Test("A closed vault refuses changes, so nothing lands under the old key while it moves")
    func closed() async throws {
        let vault = TaskVault(store: MemoryBlobs(), rootKey: try .generate())
        await vault.close()
        await #expect(throws: TaskVaultError.closed) { try await vault.save(sample()) }
    }

    @Test("A key move can find every blob Tasks keeps")
    func purposes() {
        #expect(TaskVault.sealedPurposes[".task"] == .task)
        #expect(TaskVault.sealedPurposes[".tasklist"] == .taskList)
        #expect(TaskVault.sealedPurposes[".task.trash"] == .task)
        #expect(TaskVault.sealedPurposes[".tasklist.trash"] == .taskList)
    }
}

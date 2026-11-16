import Foundation
import Testing
@testable import TotalityTasks

@Suite struct TaskMergeTests {
    private let base = TaskItem(title: "Draft thesis chapter 2", place: .anytime, createdAt: agreed)

    private func edited(_ task: TaskItem, at offset: TimeInterval, _ change: (inout TaskItem) -> Void) -> TaskItem {
        var new = task
        change(&new)
        new.noteChanges(from: task, at: agreed.addingTimeInterval(offset))
        return new
    }

    @Test("Each part takes the newer edit, so changes made on two devices both survive")
    func perField() {
        let phone = edited(base, at: 60) { $0.title = "Draft thesis chapter 2: phonotactics" }
        let mac = edited(base, at: 120) { $0.completedAt = agreed.addingTimeInterval(120) }
        for merged in [phone.merged(with: mac), mac.merged(with: phone)] {
            #expect(merged.title == "Draft thesis chapter 2: phonotactics")
            #expect(merged.isCompleted)
        }
    }

    @Test("When both change the same part, the later one wins, whichever side merges")
    func newerWins() {
        let phone = edited(base, at: 60) { $0.notes = "Start from the vowel inventory." }
        let mac = edited(base, at: 90) { $0.notes = "Start from the consonant clusters." }
        #expect(phone.merged(with: mac).notes == "Start from the consonant clusters.")
        #expect(mac.merged(with: phone).notes == "Start from the consonant clusters.")
    }

    @Test("A tie on the clock settles the same way on both devices, and done wins a tie on completion")
    func ties() {
        let one = edited(base, at: 60) { $0.title = "Thesis: chapter 2" }
        let two = edited(base, at: 60) { $0.title = "Thesis, chapter 2" }
        #expect(one.merged(with: two).title == two.merged(with: one).title)
        let done = edited(base, at: 30) { $0.completedAt = agreed.addingTimeInterval(30) }
        var other = edited(base, at: 30) { $0.priority = .high }
        other.edits["completion"] = agreed.addingTimeInterval(30)
        #expect(done.merged(with: other).isCompleted)
        #expect(other.merged(with: done).isCompleted)
    }

    @Test("Restoring from the Logbook after completing wins, because it's newer")
    func restoreWins() {
        let done = edited(base, at: 30) { $0.completedAt = agreed.addingTimeInterval(30) }
        let restored = edited(done, at: 90) { $0.completedAt = nil }
        let titled = edited(done, at: 60) { $0.title = "Chapter 2, second pass" }
        let merged = restored.merged(with: titled)
        #expect(!merged.isCompleted)
        #expect(merged.title == "Chapter 2, second pass")
    }

    @Test("Parts a newer version knows about are kept by an older one")
    func unknownParts() {
        var newer = base
        newer.edits["repeat"] = agreed.addingTimeInterval(500)
        #expect(base.merged(with: newer).edits["repeat"] == agreed.addingTimeInterval(500))
    }

    @Test("An editor that fell behind sends only what it changed, so a sync meanwhile isn't undone")
    func applying() {
        let synced = edited(base, at: 60) { $0.deadline = day(2026, 11, 20) }
        var draft = base
        draft.notes = "Ask Dr. Lee about the corpus."
        let result = synced.applying(draft, since: base, at: agreed.addingTimeInterval(90))
        #expect(result.deadline == day(2026, 11, 20))
        #expect(result.notes == "Ask Dr. Lee about the corpus.")
        #expect(result.edits["notes"] == agreed.addingTimeInterval(90))
        #expect(result.edits["deadline"] == agreed.addingTimeInterval(60))
    }

    @Test("A task saved by an older version, with parts missing, still opens")
    func olderRecord() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","title":"Book MUN hotel","createdAt":800000000}"#
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.title == "Book MUN hotel")
        #expect(task.place == .inbox)
        #expect(task.checklist.isEmpty)
        #expect(task.updatedAt == task.createdAt)
    }
}

import TotalityCore

/// How a module appears on the home screen.
public struct ModuleEntry: Identifiable, Sendable, Equatable {
    public let id: ModuleID
    public let name: String
    public let systemImage: String
    /// One line on what it's for, shown when adding it back to Home.
    public let summary: String
    /// What of the person's stays put when it's removed, like "Your photos".
    public let keeps: String

    public init(id: ModuleID, name: String, systemImage: String, summary: String = "", keeps: String = "What's in it") {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.summary = summary
        self.keeps = keeps
    }

    // SF Symbols stand in until the owner decides SF Symbols vs Lucide (proposal §11-E). The order
    // is a placeholder too.
    public static let all: [ModuleEntry] = [
        .init(id: .messages, name: "Messages", systemImage: "bubble.left",
              summary: "End-to-end encrypted chats and groups.", keeps: "Your chats"),
        .init(id: .reader, name: "Reader", systemImage: "book",
              summary: "Your files, notes and docs, with Listen.", keeps: "Your files and notes"),
        .init(id: .calendar, name: "Calendar", systemImage: "calendar",
              summary: "Events and reminders.", keeps: "Your events"),
        .init(id: .tasks, name: "Tasks", systemImage: "checklist",
              summary: "To-dos, lists and deadlines.", keeps: "Your tasks"),
        .init(id: .ai, name: "Ask Totality", systemImage: "sparkles",
              summary: "Runs on this iPhone and sees only what you allow.", keeps: "Your grants and activity"),
        .init(id: .player, name: "Music", systemImage: "music.note",
              summary: "Your music and podcasts.", keeps: "Your music"),
        .init(id: .mail, name: "Mail", systemImage: "envelope",
              summary: "Your Totality address and any others you add.", keeps: "Your mail"),
        .init(id: .photos, name: "Photos", systemImage: "photo.on.rectangle",
              summary: "Photos and videos, sealed before they upload.", keeps: "Your photos"),
        .init(id: .money, name: "Money", systemImage: "dollarsign.circle",
              summary: "Your accounts and spending, read-only.", keeps: "Your accounts"),
        .init(id: .calls, name: "Calls", systemImage: "phone",
              summary: "Voice and video calls.", keeps: "Your call history"),
        .init(id: .social, name: "Social", systemImage: "person.2",
              summary: "Posts from people you follow.", keeps: "Your posts"),
        .init(id: .web, name: "Web", systemImage: "globe",
              summary: "Private web search and bookmarks.", keeps: "Your bookmarks"),
        .init(id: .weather, name: "Weather", systemImage: "cloud.sun",
              summary: "The forecast where you are and in places you save.", keeps: "Your places"),
        .init(id: .clock, name: "Clock", systemImage: "alarm",
              summary: "World clock, alarms, timers and a stopwatch.", keeps: "Your cities, presets and alarms"),
        .init(id: .contacts, name: "Contacts", systemImage: "person.crop.circle",
              summary: "Your own address book, end-to-end encrypted.", keeps: "Your contacts"),
        .init(id: .hiking, name: "Hiking", systemImage: "figure.hiking",
              summary: "Trails nearby, and hikes recorded on this iPhone.", keeps: "Your hikes"),
    ]
}

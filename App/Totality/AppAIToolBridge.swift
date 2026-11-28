import Foundation
import TotalityAI
import TotalityCalendar
import TotalityContacts
import TotalityCore
import TotalityHiking
import TotalityMail
import TotalityMessages
import TotalityMusic
import TotalityReader
import TotalityTasks
import TotalityWeather

/// App-level bridge handed to `TotalityAI` so modules remain strictly isolated from each other.
/// Only invoked for modules whose grant has `read == true` or for proposals explicitly approved by the user.
@MainActor
final class AppAIToolBridge: AISourceBridge {
    private let calendar: CalendarModel
    private let mail: MailAccountModel
    private let tasks: TasksModel
    private let reader: ReaderModel
    private let weather: WeatherModel
    private let messages: MessagesModel
    private let contacts: ContactsModel
    private let hiking: HikingModel
    private let music: MusicModel

    init(
        calendar: CalendarModel,
        mail: MailAccountModel,
        tasks: TasksModel,
        reader: ReaderModel,
        weather: WeatherModel,
        messages: MessagesModel,
        contacts: ContactsModel,
        hiking: HikingModel,
        music: MusicModel
    ) {
        self.calendar = calendar
        self.mail = mail
        self.tasks = tasks
        self.reader = reader
        self.weather = weather
        self.messages = messages
        self.contacts = contacts
        self.hiking = hiking
        self.music = music
    }

    func fetchItems(for module: ModuleID, limit: Int) async throws -> [AIContextItem] {
        switch module {
        case .calendar:
            let now = Date()
            return calendar.events
                .filter { $0.end >= now.addingTimeInterval(-86_400) }
                .sorted { $0.start < $1.start }
                .prefix(limit)
                .map { event in
                    let when = event.start.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)
                    return AIContextItem(
                        id: event.id.uuidString,
                        module: .calendar,
                        title: event.title,
                        detail: event.location.isEmpty ? when : "\(when) · \(event.location)",
                        body: event.notes,
                        date: event.start
                    )
                }
        case .mail:
            return mail.current.conversations.prefix(limit).map { conv in
                let latest = conv.latest
                let fromName = latest.from.name.isEmpty ? latest.from.address : latest.from.name
                let plainText: String
                switch latest.body {
                case .plain(let text), .html(_, let text): plainText = text
                case .unreadable: plainText = ""
                }
                let snippet = String(plainText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
                return AIContextItem(
                    id: conv.id.uuidString,
                    module: .mail,
                    title: conv.subject,
                    detail: fromName,
                    body: snippet,
                    date: latest.date,
                    metadata: ["sender": fromName, "email": latest.from.address]
                )
            }
        case .tasks:
            return tasks.tasks.filter { $0.completedAt == nil }.prefix(limit).map { task in
                let whenText = task.deadline.map { "\($0.month)/\($0.day)" }
                    ?? task.when.map { "\($0.month)/\($0.day)" }
                    ?? "Open"
                return AIContextItem(
                    id: task.id.uuidString,
                    module: .tasks,
                    title: task.title,
                    detail: whenText,
                    body: task.notes,
                    date: nil
                )
            }
        case .reader:
            return reader.items.prefix(limit).map { item in
                AIContextItem(
                    id: item.id.uuidString,
                    module: .reader,
                    title: item.displayTitle,
                    detail: item.typeName,
                    body: "",
                    date: item.updatedAt
                )
            }
        case .weather:
            return weather.shown.prefix(limit).map { shown in
                let forecast = weather.forecast(for: shown)
                let detail = forecast.map { "Now \(Int($0.now.temperature.rounded()))°C" } ?? "Saved place"
                return AIContextItem(
                    id: shown.key,
                    module: .weather,
                    title: shown.name,
                    detail: detail,
                    body: "",
                    date: forecast?.fetchedAt
                )
            }
        case .messages:
            return messages.chats.prefix(limit).map { chat in
                AIContextItem(
                    id: chat.id,
                    module: .messages,
                    title: chat.title,
                    detail: chat.lastMessage ?? "Encrypted chat",
                    body: chat.lastMessage ?? "",
                    date: chat.lastActivity
                )
            }
        case .contacts:
            return contacts.cards.prefix(limit).map { card in
                let name = [card.givenName, card.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let title = name.isEmpty ? card.company : name
                let primary = card.emails.first?.value ?? card.phones.first?.value ?? ""
                return AIContextItem(
                    id: card.id.uuidString,
                    module: .contacts,
                    title: title.isEmpty ? "Contact" : title,
                    detail: primary,
                    body: card.notes,
                    date: nil
                )
            }
        case .hiking:
            return hiking.hikes.prefix(limit).map { hike in
                let day = hike.startedAt.formatted(date: .abbreviated, time: .omitted)
                return AIContextItem(
                    id: hike.id.uuidString,
                    module: .hiking,
                    title: hike.title,
                    detail: day,
                    body: "",
                    date: hike.startedAt
                )
            }
        case .player:
            return music.catalog.tracks.prefix(limit).map { track in
                AIContextItem(
                    id: track.id.uuidString,
                    module: .player,
                    title: track.title,
                    detail: "\(track.subtitle) · \(track.source.displayName)",
                    body: "\(track.formatLabel) · \(track.source.privacyBadge)",
                    date: track.addedAt
                )
            }
        default:
            return []
        }
    }

    func execute(_ action: AIProposedAction, editedBody: String?) async throws -> String {
        let body = (editedBody ?? action.body).trimmingCharacters(in: .whitespacesAndNewlines)
        switch action.kind {
        case .replyEmail:
            let recipient = (action.metadata["to"] ?? action.recipientOrTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recipient.isEmpty else { throw AISourceBridgeError.failed("No recipient email address on that draft.") }
            let subject = action.metadata["subject"] ?? action.subtitle ?? "Reply"
            let draft = MailDraft(to: [MailAddress(address: recipient)], subject: subject, body: body)
            _ = try await mail.current.send(draft)
            return "Approved · sent"
        case .createTask:
            let created = await tasks.add(body, in: .inbox)
            guard !created.isEmpty else { throw AISourceBridgeError.failed("Tasks couldn't add that right now.") }
            return "Approved · added"
        case .createCalendarEvent:
            let start = action.metadata["when"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                ?? Date().addingTimeInterval(3600)
            var draft = EventDraft(start: start, end: start.addingTimeInterval(3600))
            draft.title = body
            guard await calendar.create(draft) else {
                throw AISourceBridgeError.failed("Calendar couldn't add that event right now.")
            }
            return "Approved · scheduled"
        case .saveReaderNote:
            guard let item = await reader.newNote(),
                  await reader.saveNote(item.id, title: action.metadata["title"] ?? "Note", body: body) else {
                throw AISourceBridgeError.failed("Reader couldn't save that note right now.")
            }
            return "Approved · saved"
        }
    }
}

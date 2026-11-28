import Foundation
import TotalityCore

public struct AIEngineReply: Sendable, Equatable {
    public let answer: String
    public let readSummary: [AIToolUsage]
    public let proposal: AIProposedAction?
    public let missingPermission: ModuleID?

    public init(
        answer: String,
        readSummary: [AIToolUsage] = [],
        proposal: AIProposedAction? = nil,
        missingPermission: ModuleID? = nil
    ) {
        self.answer = answer
        self.readSummary = readSummary
        self.proposal = proposal
        self.missingPermission = missingPermission
    }
}

public protocol AIInferenceEngine: Sendable {
    func answer(
        question: String,
        about: AIContextItem?,
        grantedRead: Set<ModuleID>,
        grantedPropose: Set<ModuleID>,
        context: [ModuleID: [AIContextItem]],
        now: Date
    ) async throws -> AIEngineReply
}

/// Manages local quantized GGUF open model weights stored privately in the app container.
/// Works without Apple Intelligence and never sends user prompts or data off-device.
public struct LocalOpenModelStore: Sendable {
    public typealias ModelDownloader = @Sendable (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> Void

    public static let defaultModelName = "Qwen 2.5 1.5B · 4-bit"
    public static let defaultSizeLabel = "~1.0 GB"
    public static let defaultFilename = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
    public static let defaultDownloadURL = URL(
        string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
    )!
    public static let expectedByteCount: Int64 = 1_117_320_736

    private let directory: URL?
    private let downloadURL: URL
    private let minimumValidBytes: Int64
    private let downloader: ModelDownloader?

    public init(
        directory: URL? = nil,
        downloadURL: URL = LocalOpenModelStore.defaultDownloadURL,
        minimumValidBytes: Int64 = 1_000_000,
        downloader: ModelDownloader? = nil
    ) {
        self.directory = directory
        self.downloadURL = downloadURL
        self.minimumValidBytes = minimumValidBytes
        self.downloader = downloader
    }

    public static func live(directory: URL) -> LocalOpenModelStore {
        LocalOpenModelStore(directory: directory, minimumValidBytes: 100_000_000) { source, destination, onProgress in
            try await GGUFDownloadTransfer.download(
                from: source,
                to: destination,
                fallbackTotalBytes: expectedByteCount,
                onProgress: onProgress
            )
        }
    }

    public var modelFileURL: URL? {
        directory?.appendingPathComponent(Self.defaultFilename)
    }

    /// Non-nil only when a real downloaded GGUF file is present on disk (nil for in-memory test stores).
    public var readyModelURL: URL? {
        guard let url = modelFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size >= minimumValidBytes else {
            return nil
        }
        return url
    }

    public func status() -> LocalModelStatus {
        guard let directory else {
            return .ready(modelName: Self.defaultModelName, sizeLabel: Self.defaultSizeLabel)
        }
        let marker = directory.appendingPathComponent(Self.defaultFilename)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: marker.path),
           let size = attrs[.size] as? Int64,
           size >= minimumValidBytes {
            return .ready(modelName: Self.defaultModelName, sizeLabel: Self.defaultSizeLabel)
        }
        return .notDownloaded(modelName: Self.defaultModelName, sizeLabel: Self.defaultSizeLabel)
    }

    /// Downloads the GGUF model to local private storage or prepares a local marker in test mode.
    public func prepareLocalEngine(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> LocalModelStatus {
        guard let directory, let destination = modelFileURL else {
            return .ready(modelName: Self.defaultModelName, sizeLabel: Self.defaultSizeLabel)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if status().isReady {
            onProgress(1)
            return status()
        }
        if let downloader {
            try await downloader(downloadURL, destination, onProgress)
        } else {
            // Test/offline fallback when no downloader closure was injected.
            let info = ["model": Self.defaultModelName, "quantization": "Q4_K_M", "localOnly": "true"]
            let data = try JSONEncoder().encode(info)
            try data.write(to: directory.appendingPathComponent("model-config.json"), options: .atomic)
            try Data("gguf-stub".utf8).write(to: destination, options: .atomic)
            onProgress(1)
            return .ready(modelName: Self.defaultModelName, sizeLabel: Self.defaultSizeLabel)
        }
        guard status().isReady else {
            throw NSError(domain: "TotalityAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Downloaded model file was incomplete."])
        }
        return status()
    }

    public func removeDownloadedModel() throws -> LocalModelStatus {
        if let url = modelFileURL, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if let directory {
            let part = directory.appendingPathComponent(Self.defaultFilename + ".part")
            if FileManager.default.fileExists(atPath: part.path) {
                try? FileManager.default.removeItem(at: part)
            }
        }
        return status()
    }
}

private final class GGUFDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let fallbackTotalBytes: Int64
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var lastReported = -1.0

    private init(destination: URL, fallbackTotalBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.fallbackTotalBytes = fallbackTotalBytes
        self.onProgress = onProgress
    }

    static func download(
        from source: URL,
        to destination: URL,
        fallbackTotalBytes: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let transfer = GGUFDownloadTransfer(destination: destination, fallbackTotalBytes: fallbackTotalBytes, onProgress: onProgress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
        transfer.session = session
        let task = session.downloadTask(with: source)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                transfer.continuation = cont
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackTotalBytes
        guard expected > 0 else { return }
        let ratio = min(0.99, max(0, Double(totalBytesWritten) / Double(expected)))
        if ratio - lastReported >= 0.01 {
            lastReported = ratio
            onProgress(ratio)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "TotalityAI", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Model server returned HTTP \(http.statusCode)."
                ])
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            onProgress(1)
            continuation?.resume()
            continuation = nil
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}

/// Completely on-device inference engine over decrypted context granted by the user.
/// Runs `llama.cpp` when local GGUF weights are present on device, and falls back to clean
/// on-device structured synthesis before the model download finishes.
public struct LocalOpenModelEngine: AIInferenceEngine {
    private let modelStore: LocalOpenModelStore
    private let runner: LlamaRunner

    public init(modelStore: LocalOpenModelStore = LocalOpenModelStore(), runner: LlamaRunner = LlamaRunner()) {
        self.modelStore = modelStore
        self.runner = runner
    }

    public func unload() async {
        await runner.unload()
    }

    public func answer(
        question: String,
        about: AIContextItem?,
        grantedRead: Set<ModuleID>,
        grantedPropose: Set<ModuleID>,
        context: [ModuleID: [AIContextItem]],
        now: Date
    ) async throws -> AIEngineReply {
        let lower = question.lowercased()
        let focusedItem = (about != nil && !about!.id.hasSuffix(".home")) ? about : nil
        let grantableModules = Set(AIAccessGrant.defaultOrder.map(\.module))
        let requestedModules = Self.modulesMatching(lower, about: focusedItem == nil ? about : nil)
            .filter { grantableModules.contains($0) }

        // Check if the user asked specifically about a module that isn't granted Read access yet.
        // An explicitly selected single item (e.g. tapping "Ask Totality" on one email or post)
        // can be discussed on its own without granting broad module-wide reads, though questions
        // that reach into other ungranted modules still require permission.
        if let firstMissing = requestedModules.first(where: { !grantedRead.contains($0) && $0 != focusedItem?.module }),
           context[firstMissing] == nil {
            let name = AIAccessGrant.defaultOrder.first { $0.module == firstMissing }?.name ?? firstMissing.rawValue.capitalized
            return AIEngineReply(
                answer: "To answer that, Ask Totality needs permission to read your \(name.lowercased()). Nothing was read.",
                missingPermission: firstMissing
            )
        }

        let candidateOrder: [ModuleID] = requestedModules.isEmpty ? Array(grantedRead) : requestedModules
        var usages: [AIToolUsage] = []
        var lines: [String] = []
        var contextBlocks: [String] = []

        if let focusedItem {
            lines.append(Self.summarizeFocusedItem(focusedItem))
            contextBlocks.append(Self.formatContextBlock(title: "Focused item (\(focusedItem.module.rawValue))", items: [focusedItem], maxItems: 1, maxBodyChars: 1400))
        }

        for module in AIAccessGrant.defaultOrder.map(\.module) where grantedRead.contains(module) && (requestedModules.isEmpty || candidateOrder.contains(module)) {
            let items = context[module] ?? []
            if !items.isEmpty {
                let usage = Self.usage(module: module, items: items)
                usages.append(usage)
                lines.append(Self.summarize(module: module, items: items, now: now))
                let moduleName = AIAccessGrant.defaultOrder.first { $0.module == module }?.name ?? module.rawValue.capitalized
                contextBlocks.append(Self.formatContextBlock(title: moduleName, items: items, maxItems: 6, maxBodyChars: 360))
            }
        }

        let llmAnswer: String?
        if let modelURL = modelStore.readyModelURL {
            let promptBundle = Self.buildLLMPrompts(question: question, blocks: contextBlocks, now: now)
            llmAnswer = try await runner.generate(
                modelURL: modelURL,
                systemPrompt: promptBundle.system,
                userPrompt: promptBundle.user
            )
        } else {
            llmAnswer = nil
        }

        let proposal = Self.buildProposal(
            question: question,
            lower: lower,
            about: about,
            grantedPropose: grantedPropose,
            context: context,
            llmAnswer: llmAnswer,
            now: now
        )

        if let llmAnswer, !llmAnswer.isEmpty {
            let finalText = proposal != nil ? "\(llmAnswer)\n\nHere's what I drafted for your review:" : llmAnswer
            return AIEngineReply(answer: finalText, readSummary: usages, proposal: proposal)
        }

        if lines.isEmpty && proposal == nil {
            let answer = grantedRead.isEmpty
                ? "Turn on Read access for at least one module so Ask Totality can help locally on this iPhone."
                : "I checked your granted modules on this iPhone and didn't find anything matching that yet."
            return AIEngineReply(answer: answer, readSummary: usages)
        }

        let body = lines.joined(separator: "\n\n") + (proposal != nil ? "\n\nHere's what I drafted for your review:" : "")
        return AIEngineReply(answer: body.trimmingCharacters(in: .whitespacesAndNewlines), readSummary: usages, proposal: proposal)
    }

    private static func buildLLMPrompts(question: String, blocks: [String], now: Date) -> (system: String, user: String) {
        let day = now.formatted(date: .complete, time: .shortened)
        let system = """
        You are Ask Totality, a private on-device assistant running locally on the user's device.
        Today is \(day).
        Rules:
        - Answer concisely, directly, and in plain English.
        - Base any facts about emails, calendar events, tasks, messages, docs, weather, contacts, or hikes strictly on the decrypted context provided below.
        - If the user asks about personal data that is not shown in the context, say clearly that it isn't in the granted context.
        - Never invent names, times, email addresses, or content.
        """
        let joined = blocks.isEmpty
            ? "(No module items provided — general question only.)"
            : blocks.joined(separator: "\n\n")
        let user = """
        Decrypted context on this device:
        \(joined)

        User question:
        \(question)
        """
        return (system, user)
    }

    private static func formatContextBlock(title: String, items: [AIContextItem], maxItems: Int, maxBodyChars: Int) -> String {
        let lines = items.prefix(maxItems).map { item -> String in
            var entry = "- Title: \(item.title)"
            if !item.detail.isEmpty { entry += " | Detail: \(item.detail)" }
            if let date = item.date { entry += " | Date: \(date.formatted(date: .abbreviated, time: .shortened))" }
            let trimmedBody = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBody.isEmpty {
                let clipped = String(trimmedBody.prefix(maxBodyChars))
                entry += "\n  Content: \(clipped)"
            }
            return entry
        }
        return "\(title):\n" + lines.joined(separator: "\n")
    }

    static func modulesMatching(_ lower: String, about: AIContextItem?) -> [ModuleID] {
        var result: [ModuleID] = []
        func add(_ m: ModuleID) { if !result.contains(m) { result.append(m) } }
        if let about { add(about.module) }
        let keywords: [(ModuleID, [String])] = [
            (.calendar, ["calendar", "schedule", "event", "meeting", "free", "dinner", "tomorrow", "today", "saturday", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "week", "plan"]),
            (.mail, ["mail", "email", "inbox", "reply", "draft", "newsletter", "sender"]),
            (.tasks, ["task", "todo", "to-do", "remind", "checklist", "due", "grocery", "pack"]),
            (.reader, ["reader", "note", "doc", "book", "pdf", "epub", "article", "writing"]),
            (.weather, ["weather", "forecast", "rain", "snow", "temp", "temperature", "wind", "sun", "trail weather"]),
            (.messages, ["message", "messages", "chat", "group", "text", "dm", "missed"]),
            (.contacts, ["contact", "contacts", "phone", "address", "number"]),
            (.hiking, ["hike", "hiking", "trail", "trails", "climb", "elevation"]),
            (.player, ["music", "song", "songs", "playlist", "playlists", "track", "tracks", "album", "spotify", "youtube music", "apple music"]),
        ]
        for (module, words) in keywords where words.contains(where: { lower.contains($0) }) {
            add(module)
        }
        return result
    }

    private static func usage(module: ModuleID, items: [AIContextItem]) -> AIToolUsage {
        let name = AIAccessGrant.defaultOrder.first { $0.module == module }?.name ?? module.rawValue.capitalized
        let unit = switch module {
        case .mail: items.count == 1 ? "email" : "emails"
        case .calendar: items.count == 1 ? "event" : "events"
        case .tasks: items.count == 1 ? "task" : "tasks"
        case .reader: items.count == 1 ? "doc" : "docs"
        case .weather: items.count == 1 ? "forecast" : "forecasts"
        case .messages: items.count == 1 ? "chat" : "chats"
        case .contacts: items.count == 1 ? "contact" : "contacts"
        case .hiking: items.count == 1 ? "hike" : "hikes"
        case .player: items.count == 1 ? "track" : "tracks"
        default: items.count == 1 ? "item" : "items"
        }
        return AIToolUsage(module: module, count: items.count, label: "Read \(items.count) \(unit) · \(name)")
    }

    private static func summarizeFocusedItem(_ item: AIContextItem) -> String {
        var header = item.title
        if !item.detail.isEmpty {
            header += " (\(item.detail))"
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return "About \(header)."
        }
        return "About \(header):\n\(body)"
    }

    private static func summarize(module: ModuleID, items: [AIContextItem], now: Date) -> String {
        let name = AIAccessGrant.defaultOrder.first { $0.module == module }?.name ?? module.rawValue.capitalized
        let preview = items.prefix(3).map { item in
            item.detail.isEmpty ? "• \(item.title)" : "• \(item.title) (\(item.detail))"
        }.joined(separator: "\n")
        let extra = items.count > 3 ? "\n…and \(items.count - 3) more" : ""
        return "\(name):\n\(preview)\(extra)"
    }

    private static func buildProposal(
        question: String,
        lower: String,
        about: AIContextItem?,
        grantedPropose: Set<ModuleID>,
        context: [ModuleID: [AIContextItem]],
        llmAnswer: String? = nil,
        now: Date
    ) -> AIProposedAction? {
        if (lower.contains("reply") || lower.contains("draft") || lower.contains("email")),
           grantedPropose.contains(.mail),
           let mailItem = (about?.module == .mail ? about : nil) ?? context[.mail]?.first {
            let sender = mailItem.metadata["sender"] ?? mailItem.detail
            let subject = mailItem.title
            let recipientEmail = mailItem.metadata["email"] ?? mailItem.metadata["from"] ?? sender
            let calSummary = context[.calendar]?.first.map { " I noted \($0.title) (\($0.detail))." } ?? ""
            let cleanedLLM = llmAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let draft = (cleanedLLM?.isEmpty == false)
                ? cleanedLLM!
                : "Hi \(sender),\n\nThanks for reaching out about \(subject).\(calSummary) That works on my end."
            return AIProposedAction(
                kind: .replyEmail,
                module: .mail,
                title: "Send this reply?",
                recipientOrTarget: recipientEmail,
                subtitle: "Re: \(subject)",
                body: draft,
                metadata: [
                    "subject": "Re: \(subject)",
                    "to": recipientEmail,
                    "itemID": mailItem.id,
                ]
            )
        }
        if (lower.contains("add task") || lower.contains("create task") || lower.contains("add to tasks") || lower.contains("turn this into a task") || lower.contains("remind me") || lower.contains("todo")),
           grantedPropose.contains(.tasks) {
            let isDeictic = about != nil && (lower.contains("turn this into a task") || lower.contains("add this to tasks") || lower == "add task" || lower == "create task")
            let taskTitle = isDeictic ? (about?.title ?? "Follow up") : cleanedTaskTitle(from: question)
            return AIProposedAction(
                kind: .createTask,
                module: .tasks,
                title: "Add this task?",
                recipientOrTarget: "Tasks",
                subtitle: "New task",
                body: taskTitle,
                metadata: ["title": taskTitle]
            )
        }
        if (lower.contains("add event") || lower.contains("schedule") || lower.contains("book") || lower.contains("calendar event")),
           grantedPropose.contains(.calendar) {
            let eventTitle = cleanedEventTitle(from: question)
            return AIProposedAction(
                kind: .createCalendarEvent,
                module: .calendar,
                title: "Add calendar event?",
                recipientOrTarget: "Calendar",
                subtitle: "Tomorrow · 9:00 AM",
                body: eventTitle,
                metadata: ["title": eventTitle, "when": String(now.addingTimeInterval(24 * 3600).timeIntervalSince1970)]
            )
        }
        if (lower.contains("save note") || lower.contains("create note") || lower.contains("new note")),
           grantedPropose.contains(.reader) {
            let noteTitle = cleanedTaskTitle(from: question)
            return AIProposedAction(
                kind: .saveReaderNote,
                module: .reader,
                title: "Save note to Reader?",
                recipientOrTarget: "Reader",
                subtitle: "New doc",
                body: noteTitle,
                metadata: ["title": noteTitle]
            )
        }
        return nil
    }

    private static func cleanedTaskTitle(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["add a task to ", "add task to ", "add task ", "create a task to ", "create task ", "remind me to ", "save a note about ", "create a note about ", "save note "] {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        return text.isEmpty ? "Follow up" : text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func cleanedEventTitle(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["schedule ", "add event ", "add a calendar event for ", "create calendar event "] {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        return text.isEmpty ? "Planned event" : text.prefix(1).uppercased() + text.dropFirst()
    }
}

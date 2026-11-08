import Foundation
import Observation
import TotalityCore

/// How long Mail's short windows last, in one place so the screens and the tests agree.
public enum MailTiming {
    /// Undo after an action, and before a send goes.
    public static let undo = Duration.seconds(6)
    /// A short note at the bottom of the screen.
    public static let notice = Duration.seconds(4)
    /// How long writing pauses before the draft is saved.
    public static let autosave = Duration.seconds(2)
    /// How often Mail checks for new mail while it's open.
    public static let sync = Duration.seconds(120)
}

/// The three lines a message's people go on.
public enum MailField: Hashable, Sendable, CaseIterable {
    case to, cc, bcc

    public var label: String {
        switch self {
        case .to: "To"
        case .cc: "Cc"
        case .bcc: "Bcc"
        }
    }
}

/// One message being written: its draft, what's half typed on each address line, and the send.
///
/// Send only ever starts from a press, then waits `MailTiming.undo` before anything leaves, so Undo
/// can stop it. Whatever doesn't go stays a draft with its words, and the screen says why.
@MainActor
@Observable
public final class MailComposer: Identifiable {
    public enum Phase: Equatable {
        case writing
        /// Pressed, and waiting out the Undo window. Nothing has left yet.
        case holding(until: Date)
        case sending
        /// It went, to some or all. `MailSendResult` says who and why not.
        case finished(MailSendResult)
        /// Thrown away, on purpose, after a confirm.
        case discarded
    }

    public let id: UUID
    public var draft: MailDraft
    /// What's typed on an address line and not yet made into an address.
    public var typed: [MailField: String] = [:]
    public private(set) var phase = Phase.writing
    /// Why the last press didn't send, or why a file didn't attach. The draft is kept.
    public var problem: String?
    public var showsCopies: Bool

    @ObservationIgnored public let model: MailModel
    @ObservationIgnored private let hold: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var sending: Task<Void, Never>?
    /// What the store has, so autosave only writes a change. A new message's signature alone isn't one.
    @ObservationIgnored private var lastSaved: MailDraft
    /// Whether the store has this draft at all. A new message hasn't until it changes or is sent.
    @ObservationIgnored private var isStored: Bool

    public init(
        draft: MailDraft, model: MailModel, isStored: Bool = false, hold: Duration = MailTiming.undo, now: @escaping () -> Date = { Date() }
    ) {
        self.isStored = isStored
        id = draft.id
        self.draft = draft
        self.model = model
        self.hold = hold
        self.now = now
        lastSaved = draft
        showsCopies = !draft.cc.isEmpty || !draft.bcc.isEmpty
    }

    // MARK: Starting

    /// A new message, signed.
    public static func new(in model: MailModel) -> MailComposer {
        MailComposer(draft: signed(MailDraft(), with: model.mailbox.settings.signature), model: model)
    }

    /// Mail that came to an outside account is answered from it when it can send, so the reply comes
    /// from the address it was sent to. Otherwise from the Totality address.
    public static func reply(to message: MailMessage, all: Bool, in model: MailModel) -> MailComposer {
        let me = message.outsideAccount?.address ?? model.mailbox.address
        var draft = all ? MailDraft.replyAll(to: message, me: me) : MailDraft.reply(to: message, me: me)
        if let outside = message.outsideAccount {
            // Neither address of the person's own is someone to reply to.
            let totality = model.mailbox.address
            draft.to.removeAll { MailDraft.isMe($0, totality) }
            draft.cc.removeAll { MailDraft.isMe($0, totality) }
            draft.from = model.mailbox.senders.first { $0.id == outside.id }?.id
        }
        return MailComposer(draft: signed(draft, with: model.mailbox.settings.signature), model: model)
    }

    /// Reads the original's files from the store first. One that won't read is left off, and the model
    /// says so.
    public static func forward(_ message: MailMessage, in model: MailModel) async -> MailComposer {
        var files: [MailDraftAttachment] = []
        for attachment in message.attachments {
            if let data = await model.data(of: attachment) {
                files.append(MailDraftAttachment(name: attachment.name, mimeType: attachment.mimeType, data: data))
            }
        }
        let draft = MailDraft.forward(message, attachments: files)
        return MailComposer(draft: signed(draft, with: model.mailbox.settings.signature), model: model)
    }

    /// A draft from the Drafts folder, as it was left.
    public static func resume(_ draft: MailDraft, in model: MailModel) -> MailComposer {
        MailComposer(draft: draft, model: model, isStored: true)
    }

    /// The signature goes above anything quoted or forwarded, after a blank line to write in.
    static func signed(_ draft: MailDraft, with signature: String) -> MailDraft {
        let signature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signature.isEmpty else { return draft }
        var signed = draft
        let rest = draft.body.hasPrefix("\n\n") ? String(draft.body.dropFirst(2)) : draft.body
        signed.body = "\n\n-- \n" + signature + (rest.isEmpty ? "" : "\n\n" + rest)
        return signed
    }

    // MARK: Addresses

    public func addresses(_ field: MailField) -> [MailAddress] {
        switch field {
        case .to: draft.to
        case .cc: draft.cc
        case .bcc: draft.bcc
        }
    }

    /// Adds someone once. Someone already on the message stays where they are.
    public func add(_ address: MailAddress, to field: MailField) {
        guard !draft.recipients.contains(where: { $0.key == address.key }) else { return }
        switch field {
        case .to: draft.to.append(address)
        case .cc: draft.cc.append(address)
        case .bcc: draft.bcc.append(address)
        }
    }

    public func remove(_ address: MailAddress, from field: MailField) {
        switch field {
        case .to: draft.to.removeAll { $0 == address }
        case .cc: draft.cc.removeAll { $0 == address }
        case .bcc: draft.bcc.removeAll { $0 == address }
        }
    }

    /// Picking a suggestion replaces what was typed.
    public func choose(_ address: MailAddress, for field: MailField) {
        add(address, to: field)
        typed[field] = ""
    }

    /// Turns what's typed into addresses once it ends in a comma or semicolon, the way people separate them.
    public func typing(in field: MailField) {
        guard let text = typed[field], text.contains(where: { ",;\n".contains($0) }) else { return }
        commit(field)
    }

    /// Everything typed on the line becomes addresses, written as they were, even ones that aren't
    /// right yet, so they can be seen and fixed.
    public func commit(_ field: MailField) {
        for address in Self.addresses(in: typed[field] ?? "") { add(address, to: field) }
        typed[field] = ""
    }

    func commitAll() {
        for field in MailField.allCases { commit(field) }
    }

    /// `Dana <dana@usetotality.com>`, bare addresses, and lists of either.
    static func addresses(in text: String) -> [MailAddress] {
        text.split(whereSeparator: { ",;\n".contains($0) }).flatMap { part -> [MailAddress] in
            let token = part.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return [] }
            if let match = token.wholeMatch(of: /(.*)<([^<>]+)>/) {
                let name = match.1.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
                return [MailAddress(name: name, address: match.2.trimmingCharacters(in: .whitespaces))]
            }
            return token.split(whereSeparator: \.isWhitespace).map { MailAddress(address: String($0)) }
        }
    }

    /// People from this device's own mail who match what's typed. Nothing typed leaves the device.
    public func suggestions(for field: MailField) -> [MailAddress] {
        Self.suggestions(typed[field] ?? "", in: model.mailbox, excluding: draft.recipients)
    }

    /// Everyone on the mail here, outside Spam and apart from the person themselves, who matches the
    /// start of a name or an address. Whoever comes up most comes first, then whoever came most recently.
    static func suggestions(_ typed: String, in mailbox: Mailbox, excluding: [MailAddress], limit: Int = 5) -> [MailAddress] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let taken = Set(excluding.map(\.key))
        struct Seen {
            var address: MailAddress
            var count: Int
            var latest: Date
        }
        var people: [String: Seen] = [:]
        for message in mailbox.messages where message.marks.folder != .spam && !message.isUnreadable {
            for person in [message.from] + message.to + message.cc + message.bcc + message.replyTo {
                guard person.isWellFormed, !taken.contains(person.key), !MailDraft.isMe(person, mailbox.address) else { continue }
                var seen = people[person.key] ?? Seen(address: person, count: 0, latest: message.date)
                seen.count += 1
                if message.date >= seen.latest || seen.address.name.isEmpty, !person.name.isEmpty { seen.address = person }
                seen.latest = max(seen.latest, message.date)
                people[person.key] = seen
            }
        }
        return people.values
            .filter { seen in
                let name = seen.address.name.lowercased()
                return seen.address.key.hasPrefix(query) || name.hasPrefix(query)
                    || name.split(whereSeparator: { $0.isWhitespace || $0 == "." }).contains { $0.hasPrefix(query) }
            }
            .sorted { ($0.count, $0.latest, $1.address.key) > ($1.count, $1.latest, $0.address.key) }
            .prefix(limit)
            .map(\.address)
    }

    // MARK: What it says about itself

    /// The honest line for who it's going to. Between Totality accounts it's sealed; anyone else gets
    /// ordinary email, and the line says so.
    public var routeNote: (text: String, isSealed: Bool)? {
        let people = draft.recipients
        guard !people.isEmpty else { return nil }
        if let sender { return (OutsideWording.sendingThrough(sender.provider), false) }
        if people.allSatisfy({ $0.totalityName != nil }) { return (MailWording.betweenAccounts, true) }
        if people.allSatisfy({ $0.totalityName == nil }) { return (MailWording.outsideSending, false) }
        return (MailWording.mixedSending, false)
    }

    // MARK: From

    /// The addresses it can go from: the Totality address first, then each outside account that sends.
    public var senders: [OutsideAccountLabel] { model.mailbox.senders }

    /// The outside account it's from, or nil for the Totality address.
    public var sender: OutsideAccountLabel? {
        draft.from.flatMap { id in senders.first { $0.id == id } }
    }

    /// The address on the From line.
    public var fromAddress: String { sender?.address ?? model.mailbox.address }

    public func send(from account: OutsideAccountLabel?) {
        guard phase == .writing else { return }
        draft.from = account?.id
    }

    public var canSend: Bool {
        phase == .writing && (!draft.recipients.isEmpty || typed.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    // MARK: Files

    /// Roughly how big it'll be written out: files grow by a third on the way.
    private var writtenSize: Int {
        draft.attachments.reduce(draft.body.utf8.count) { $0 + $1.data.count * 4 / 3 }
    }

    public func attach(name: String, mimeType: String, data: Data) {
        guard writtenSize + data.count * 4 / 3 <= MailDraft.maxBytes else {
            problem = "\(name) would take the message over 25 MB, so it wasn't attached."
            return
        }
        draft.attachments.append(MailDraftAttachment(name: name, mimeType: mimeType, data: data))
    }

    public func removeAttachment(_ id: MailDraftAttachment.ID) {
        draft.attachments.removeAll { $0.id == id }
    }

    // MARK: Saving

    /// Saves a change, sealed, through the model. Only while writing, so it can never bring back a
    /// draft that's just been sent.
    public func autosave() async {
        guard phase == .writing, draft != lastSaved else { return }
        await saveNow()
    }

    private func saveNow() async {
        let saving = draft
        lastSaved = saving
        isStored = true
        await model.save(saving)
    }

    /// Leaving the sheet. Anything half typed is kept as an address.
    public func close() async {
        guard phase == .writing else { return }
        commitAll()
        await autosave()
    }

    public func discard() async {
        sending?.cancel()
        sending = nil
        phase = .discarded
        await model.discard(draft)
    }

    // MARK: Sending

    /// The press. Checks what it can here, saves the draft so a quit can't lose it, then waits out the
    /// Undo window before anything leaves.
    public func pressSend() async {
        guard phase == .writing else { return }
        commitAll()
        problem = nil
        do {
            try draft.checkRecipients()
        } catch {
            problem = MailWording.notSent(error)
            return
        }
        if let wrong = draft.recipients.first(where: { !$0.isWellFormed }) {
            problem = "\(wrong.address) isn't an email address. Fix it or take it off."
            return
        }
        // Saved before the window, changed or not, so a quit or a failed send can't lose it.
        if !isStored || draft != lastSaved { await saveNow() }
        phase = .holding(until: now().addingTimeInterval(TimeInterval(hold.components.seconds)))
        let hold = hold
        sending = Task { [weak self] in
            do {
                try await Task.sleep(for: hold)
            } catch {
                return
            }
            await self?.sendNow()
        }
    }

    /// Stops it inside the window. Nothing has left.
    public func undoSend() {
        guard case .holding = phase else { return }
        sending?.cancel()
        sending = nil
        phase = .writing
    }

    private func sendNow() async {
        guard case .holding = phase, !Task.isCancelled else { return }
        phase = .sending
        do {
            let result = try await model.send(draft)
            if let remaining = result.remaining {
                draft = remaining
                lastSaved = remaining
            } else {
                isStored = false
            }
            phase = .finished(result)
        } catch {
            problem = MailWording.notSent(error)
            phase = .writing
        }
        sending = nil
    }

    /// Back to the draft that's left, to fix it or send it again.
    public func keepWriting() {
        guard case .finished(let result) = phase, result.remaining != nil else { return }
        problem = nil
        phase = .writing
    }

    /// For tests: waits for a send that's been pressed to finish or be undone.
    func waitForSend() async {
        await sending?.value
    }
}

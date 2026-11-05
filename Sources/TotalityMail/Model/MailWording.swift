import Foundation

/// What Mail says about itself. The route lines are the spec's own words, agreed with the owner in issue
/// 37, and they have to stay literally true: nothing here may call mail end-to-end encrypted until
/// people can verify each other's keys.
public enum MailWording {
    public static let betweenAccounts = "Sealed by your device. Totality's servers can't read it."
    public static let outside = "Email isn't end-to-end encrypted. Totality's server handles it as it arrives or leaves, and so do Cloudflare and the mail servers it passes through. Cloudflare's log keeps the subject and addresses of mail to and from outside. The stored copy is sealed."

    public static func route(_ route: MailRoute) -> String {
        switch route {
        case .betweenAccounts: betweenAccounts
        case .outside: outside
        }
    }

    /// The sender's name can say anything, so this names the domain, which is what the checks looked at.
    public static func unproved(_ sender: MailAddress) -> String {
        "This message says it's from \(sender.domain), but that couldn't be proved. Be careful with its links and attachments."
    }

    /// Mail between accounts where the From line names someone other than the account that sent it.
    public static func claimsSomeoneElse(_ claimed: MailAddress, sentBy: MailAddress) -> String {
        "This message says it's from \(claimed.address), but it was sent by \(sentBy.address). Be careful with its links and attachments."
    }

    /// The warning a message needs, if any. Mail between accounts knows who really sent it, so it says so.
    public static func warning(for message: MailMessage) -> String? {
        guard message.proof == .unproved, !message.isUnreadable else { return nil }
        if message.route == .betweenAccounts, let sentBy = message.sentBy, message.from.totalityName != sentBy.totalityName {
            return claimsSomeoneElse(message.from, sentBy: sentBy)
        }
        return unproved(message.from)
    }

    // MARK: Sending

    /// For a draft with anyone outside Totality on it. It says what happens, and promises nothing more.
    public static let outsideNotYet = "Sending outside Totality isn't on yet. Outside addresses stay on the draft until it is."

    /// What happened for one person, in a sentence.
    public static func outcome(_ outcome: MailSendResult.Outcome) -> String {
        switch outcome {
        case .delivered: "Delivered."
        case .noSuchAddress: "Not sent. No Totality account has this address, or they haven't opened Mail yet."
        case .outsideNotYet: "Not sent. Sending outside Totality isn't on yet, so this address stays on the draft."
        case .notAnAddress: "Not sent. This isn't an email address."
        case .recipientFull: "Not sent. Their mailbox is full."
        case .tooBig: "Not sent. It's too big for their mailbox."
        case .offline: "Not sent. You're offline, so it stays a draft. Send it again when you're back."
        case .failed: "Not sent. Something went wrong on the way. Try sending again."
        }
    }

    /// Why a send didn't start. The draft is kept either way.
    public static func notSent(_ error: any Error) -> String {
        switch error {
        case MailSendError.noRecipients: "Add someone to send it to."
        case MailSendError.tooManyRecipients(let count): "A message can go to \(MailDraft.maxRecipients) people at most, and this one has \(count)."
        case MailSendError.tooBig: "It's over 25 MB. Remove an attachment and try again."
        case MailSendError.noAddress: "Your username isn't known yet, so there's no address to send from. Try again in a moment."
        case MailStoreError.offline: "You're offline. It's kept as a draft, so send it when you're back."
        case MailStoreError.waitingForBackup: "Mail can't send until your recovery key is set up. It's kept as a draft."
        case MailStoreError.keyConflict: "There's a problem with your mailbox, so nothing can send. It's kept as a draft."
        case MailStoreError.noKey: "Your key isn't on this device, so nothing can send. It's kept as a draft."
        default: "Totality couldn't reach your mailbox, so nothing was sent. It's kept as a draft."
        }
    }

    public static let copyOnDevice = "Your Sent copy is only on this device for now. Totality tries your mailbox again the next time Mail opens."

    public static let imagesOff = "Images from the internet are off, because senders use them to see when and where you opened a message."

    public static func empty(_ place: MailPlace) -> (title: String, detail: String) {
        switch place {
        case .folder(.inbox): ("Nothing in your Inbox", "New mail lands here.")
        case .starred: ("Nothing starred", "Star a conversation to keep it close.")
        case .folder(.sent): ("Nothing sent", "Mail you send keeps a sealed copy here.")
        case .folder(.drafts): ("No drafts", "Anything you start writing waits here.")
        case .folder(.archive): ("Nothing archived", "Archived mail stays here, out of your Inbox.")
        case .folder(.spam): ("No spam", "Mail that looks like spam lands here.")
        case .folder(.trash): ("Trash is empty", "Mail you delete stays here for 30 days, then it's gone for good.")
        case .folder(.own): ("Nothing in this folder", "Move a conversation here to keep it.")
        }
    }
}

/// How a message's date reads on a row.
enum MailDate {
    static func short(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(timeZone: calendar.timeZone)
        style.calendar = calendar
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, (0..<7).contains(days) {
            return date.formatted(style.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style.month(.abbreviated).day())
        }
        return date.formatted(style.month(.abbreviated).day().year())
    }
}

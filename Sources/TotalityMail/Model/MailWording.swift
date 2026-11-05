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

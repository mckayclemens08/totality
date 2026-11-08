import Foundation

/// What Mail says about outside accounts. The keeper and sending lines are issue 43's own words, agreed
/// with the owner, and have to stay literally true: nothing here calls an outside account's mail sealed
/// or end-to-end encrypted at the provider.
public enum OutsideWording {
    /// On every outside account, and on its mail once reading lands.
    /// Deleting forever in Totality moves an outside account's copy to that account's Trash, and no further.
    public static func deletingForever(_ messages: [MailMessage]) -> String {
        let names = Set(messages.compactMap { $0.outsideAccount?.provider }).map(\.name).sorted()
        guard !names.isEmpty else { return "This can't be undone." }
        return "This can't be undone here. The copy in \(names.joined(separator: " and ")) goes to its Trash there."
    }

    public static func kept(by provider: OutsideProvider) -> String {
        "This mail is kept by \(provider.keeper), who can read it. Totality doesn't seal it there. Your downloaded copy on this device is sealed."
    }

    /// "Gmail", or "Gmail and iCloud", once each.
    public static func names(_ providers: [OutsideProvider]) -> String {
        var seen = Set<OutsideProvider>()
        return providers.filter { seen.insert($0).inserted }.map(\.name).joined(separator: " and ")
    }

    public static func searchNote(_ names: String) -> String {
        "Your search words go to \(names), who already keep that mail. What's found is downloaded to this device and sealed."
    }

    public static func searched(found: Int, in names: String) -> String {
        switch found {
        case 0: "Nothing more was found in \(names)."
        case 1: "1 older message was found in \(names) and downloaded."
        default: "\(found) older messages were found in \(names) and downloaded."
        }
    }

    /// The line in the composer when it's going from an outside account.
    public static func sendingThrough(_ provider: OutsideProvider) -> String {
        "This goes through \(provider.name) as ordinary email. It isn't end-to-end encrypted, even to Totality addresses, and \(provider.keeper) can read it."
    }

    public static func sent(through provider: OutsideProvider) -> String {
        "Sent through \(provider.name). It isn't end-to-end encrypted."
    }

    public static let sendSwitch = "Send from this account"
    public static func sendSwitchOff(_ provider: OutsideProvider) -> String {
        provider.signsInWithGoogle
            ? "Reading this account never lets Totality send from it. Turning this on asks Google to let Totality send too."
            : "Reading this account never lets Totality send from it. Turn this on to choose it as From."
    }

    /// What adding an account involves, before anything is asked for.
    public static func howToAdd(_ provider: OutsideProvider) -> [String] {
        switch provider {
        case .icloud: [
            "Apple doesn't let other apps sign in to iCloud Mail with your Apple Account, so it takes an app-specific password made for Totality.",
            "Tap Make an App Password, sign in to Apple, then choose Sign-In and Security, App-Specific Passwords, and name it Totality. Copy it, come back, and paste it here.",
            "Your iPhone or Mac talks to Apple directly. Totality's server never sees the password or your mail.",
        ]
        case .gmail: [
            "Sign in on Google's own page. Totality never sees your Google password.",
            "Google's page asks to let Totality read and change your mail, so what you read, star, archive or delete here matches the Gmail app. Google's wording says this also allows sending. Totality only sends from Gmail after you turn on Send for the account, and every message waits for your press.",
            "Your iPhone or Mac talks to Google directly. Totality's server never sees your sign-in or your mail.",
        ]
        }
    }

    /// Google shows this warning until it has reviewed Totality, so it's said first.
    public static let googleUnverified = "Google may say it hasn't verified Totality yet. That's expected for now: choose Advanced, then Go to Totality."

    /// For a Gmail account added when Totality could only read it.
    public static let readOnly = "Changes you make in Totality stay here. Allow changes to keep the Gmail app in step: Google will ask once more."

    public static func removing(_ account: OutsideAccount) -> String {
        account.provider.signsInWithGoogle
            ? "Its sign-in and everything downloaded from it leave this device and your others, and Totality's access is taken back at Google. No mail at Google is deleted."
            : "Its sign-in and everything downloaded from it leave this device and your others. Nothing at \(account.provider.keeper) is deleted."
    }

    public static let none = "No outside accounts yet. Add iCloud or Gmail to read them here, beside your Totality mail."

    public static func problem(_ error: OutsideAccountError, provider: OutsideProvider) -> String {
        switch error {
        case .problem(let problem): self.problem(problem, provider: provider)
        case .tooMany: "You can add up to \(OutsideAccountLimits.most) outside accounts for now."
        case .alreadyAdded: "That account is already added."
        case .notFound: "This account's sign-in isn't on this device. Remove it and add it again."
        case .unavailable: "This device can't keep sign-ins until Mail has opened with your content key."
        case .cancelled: ""
        case .notSetUp: "Google sign-in isn't set up in this version of Totality yet."
        case .differentAccount: "That was a different Google account. Sign in with the one you're changing."
        }
    }

    public static func problem(_ problem: OutsideMailProblem, provider: OutsideProvider) -> String {
        switch problem {
        case .offline: "You're offline. Connect, then try again."
        case .unreachable: "\(provider.name) didn't answer. Try again in a moment."
        case .insecure: "Totality couldn't make a secure connection to \(provider.name), so it didn't send your sign-in."
        case .wrongPassword: "\(provider.name) didn't accept that address and app password. Check both, or make a new app password."
        case .notAllowed: provider.signsInWithGoogle
            ? "Google wasn't given permission. Try again and leave Totality's box ticked on Google's page."
            : "\(provider.name) didn't allow it."
        case .expired: "\(provider.name)'s sign-in no longer works. Remove the account and add it again."
        case .needsAppPassword: "That looks like your \(provider.keeper) account password. \(provider.name) needs an app password made for Totality."
        case .refused(let said): said.isEmpty ? "\(provider.name) turned the sign-in down." : "\(provider.name) said: \(said)"
        case .unexpected: "\(provider.name) answered in a way Totality didn't expect. Try again later."
        }
    }
}

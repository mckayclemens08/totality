import Foundation

/// What Mail says about outside accounts. The keeper and sending lines are issue 43's own words, agreed
/// with the owner, and have to stay literally true: nothing here calls an outside account's mail sealed
/// or end-to-end encrypted at the provider.
public enum OutsideWording {
    /// On every outside account, and on its mail once reading lands.
    public static func kept(by provider: OutsideProvider) -> String {
        "This mail is kept by \(provider.keeper), who can read it. Totality doesn't seal it there. Your downloaded copy on this device is sealed."
    }

    public static func sent(through provider: OutsideProvider) -> String {
        "Sent through \(provider.name). It isn't end-to-end encrypted."
    }

    public static let sendSwitch = "Send from this account"
    public static let sendSwitchOff = "Reading this account never lets Totality send from it. Turn this on to choose it as From."

    /// How to make the one password Totality takes, before it's asked for.
    public static func howToAdd(_ provider: OutsideProvider) -> [String] {
        switch provider {
        case .icloud: [
            "Totality signs in to iCloud Mail with an app-specific password, never your Apple Account password.",
            "Make one at account.apple.com, under Sign-In and Security, then App-Specific Passwords. It needs two-factor authentication on.",
            "Your iPhone or Mac talks to Apple directly. Totality's server never sees the password or your mail.",
        ]
        case .gmail: [
            "Totality signs in to Gmail with an app password, never your Google password.",
            "Make one in your Google Account, under Security, then App passwords. It needs 2-Step Verification on. Work and school accounts may not allow it.",
            "Your iPhone or Mac talks to Google directly. Totality's server never sees the password or your mail.",
        ]
        }
    }

    public static func removing(_ account: OutsideAccount) -> String {
        "Its sign-in and everything downloaded from it leave this device and your others. Nothing at \(account.provider.keeper) is deleted."
    }

    public static let none = "No outside accounts yet. Add iCloud or Gmail to read them here, beside your Totality mail."

    public static func problem(_ error: OutsideAccountError, provider: OutsideProvider) -> String {
        switch error {
        case .problem(let problem): self.problem(problem, provider: provider)
        case .tooMany: "You can add up to \(OutsideAccountLimits.most) outside accounts for now."
        case .alreadyAdded: "That account is already added."
        case .notFound: "This account's sign-in isn't on this device. Remove it and add it again."
        case .unavailable: "This device can't keep sign-ins until Mail has opened with your content key."
        }
    }

    public static func problem(_ problem: OutsideMailProblem, provider: OutsideProvider) -> String {
        switch problem {
        case .offline: "You're offline. Connect, then try again."
        case .unreachable: "\(provider.name) didn't answer. Try again in a moment."
        case .insecure: "Totality couldn't make a secure connection to \(provider.name), so it didn't send your sign-in."
        case .wrongPassword: "\(provider.name) didn't accept that address and app password. Check both, or make a new app password."
        case .needsAppPassword: "That looks like your \(provider.keeper) account password. \(provider.name) needs an app password made for Totality."
        case .refused(let said): said.isEmpty ? "\(provider.name) turned the sign-in down." : "\(provider.name) said: \(said)"
        case .unexpected: "\(provider.name) answered in a way Totality didn't expect. Try again later."
        }
    }
}

import SwiftUI
import TotalityCore
import TotalityUI

/// What the Calendar says about Google, in one place so it stays literally true (CLAUDE.md rule 5).
enum GoogleCalendarWording {
    static let intro = "Connect a Google account to show its calendars here. They're read-only in Totality. Google can read them, so they aren't end-to-end encrypted, and this device keeps a copy encrypted with your key so they open straight away. Nothing from them goes to Totality's server."

    static let empty = "No Google account is connected yet."

    static func allowing(_ account: String) -> String {
        "\(account) is connected for other parts of Totality. Allow its calendars with one tap on Google's page."
    }

    static func synced(_ date: Date?) -> String {
        guard let date else { return "Not read from Google yet. Pull down on the Calendar to read it." }
        return "Updated \(date.formatted(.relative(presentation: .named)))."
    }

    static func disconnecting(alsoEnds: Set<GoogleUse>) -> String {
        let base = "Totality's access is taken back at Google, and this account's calendars leave this device. Nothing at Google is deleted."
        let others = GoogleUse.allCases.filter(alsoEnds.contains).map(\.name)
        guard !others.isEmpty else { return base }
        return base + " Google takes back all of Totality's access at once, so \(ListFormatter.localizedString(byJoining: others)) for this account stop too, until you connect it again."
    }

    static func origin(_ calendar: String) -> String {
        "From your \(calendar) Google calendar. It's read-only here. Google can read it, and this device keeps an encrypted copy."
    }
}

/// The Google part of the Calendars sheet: each connected account with a switch per calendar, a way
/// to allow Calendar on an account already connected for something else, and Connect.
struct GoogleCalendarsSection: View {
    let model: CalendarModel
    let signingIn: GoogleWebSignIn
    let disconnect: (String) -> Void

    var body: some View {
        let theme = Theme.current
        Section {
            Text(GoogleCalendarWording.intro)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
            if model.googleAccounts.isEmpty && model.googleNeedsAllowing.isEmpty {
                Text(GoogleCalendarWording.empty)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
            }
            ForEach(model.googleNeedsAllowing, id: \.self) { account in
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(GoogleCalendarWording.allowing(account))
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textSecondary.color)
                    Button("Allow Calendar for \(account)") {
                        Task { await model.connectGoogle(account, signingIn: signingIn) }
                    }
                    .disabled(model.isConnectingGoogle)
                }
            }
            Button {
                Task { await model.connectGoogle(signingIn: signingIn) }
            } label: {
                HStack(spacing: Space.s2) {
                    Label("Connect Google Calendar", systemImage: "plus")
                    if model.isConnectingGoogle { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.isConnectingGoogle)
        } header: {
            Text("Google Calendar")
        }
        ForEach(model.googleAccounts) { account in
            Section {
                if model.isSyncingGoogle && account.calendars.isEmpty {
                    HStack(spacing: Space.s2) {
                        ProgressView().controlSize(.small)
                        Text("Reading this account's calendars")
                    }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
                }
                ForEach(account.calendars) { calendar in
                    Toggle(isOn: visible(calendar, in: account)) {
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(calendar.info.title).font(Typeface.body)
                            if calendar.info.isSubscribed {
                                Text("Subscribed")
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.textSecondary.color)
                            }
                        }
                    }
                }
                if let problem = model.googleProblems[account.address] {
                    Text(problem.message)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.danger.color)
                    if problem == .expired || problem == .notAllowed {
                        Button("Connect \(account.address) again") {
                            Task { await model.connectGoogle(account.address, signingIn: signingIn) }
                        }
                        .disabled(model.isConnectingGoogle)
                    }
                }
                Button("Disconnect", role: .destructive) { disconnect(account.address) }
                    .foregroundStyle(theme.danger.color)
            } header: {
                Text(account.address)
            } footer: {
                Text(GoogleCalendarWording.synced(account.syncedAt))
            }
        }
    }

    private func visible(_ calendar: GoogleCalendarState, in account: GoogleCalendarAccount) -> Binding<Bool> {
        Binding(
            get: { calendar.isOn },
            set: { on in Task { await model.setVisible(on, googleCalendar: calendar, account: account.address) } }
        )
    }
}

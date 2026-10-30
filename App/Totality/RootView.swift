import SwiftUI
import TotalityAccount
import TotalityCore
import TotalityReader
import TotalityUI

/// Home and whichever module is open. The Reader's model stays alive here, so Listen keeps playing
/// after the person goes back to the home screen.
struct RootView: View {
    @State private var open: ModuleID?
    @State private var reader: ReaderModel?
    @State private var readerProblem: ReaderProblem?
    @State private var account = AccountSetup.makeModel()
    @State private var showingAccount = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch open {
            case nil:
                HomeView { module in
                    if module == .reader { prepareReader() }
                    open = module
                }
                .overlay(alignment: .topLeading) { accountButton }
            case .reader:
                if let reader {
                    ReaderHomeView(model: reader) { open = nil }
                } else {
                    let problem = readerProblem ?? .keyUnavailable
                    ModuleMessage(systemImage: "lock.slash", title: problem.title, detail: problem.detail) { open = nil }
                }
            case .some(let module):
                ModuleMessage(
                    systemImage: "hammer",
                    title: ModuleEntry.all.first { $0.id == module }?.name ?? "This module",
                    detail: "This isn't built yet. The Reader is the first module you can use."
                ) { open = nil }
            }
        }
        .animation(Motion.standard, value: open)
        .sheet(isPresented: $showingAccount) {
            if let account {
                AccountView(model: account) { showingAccount = false }
            } else {
                ModuleMessage(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "Sign-in isn't set up",
                    detail: "This build has no backend settings. Your notes aren't affected."
                ) { showingAccount = false }
            }
        }
    }

    private var accountButton: some View {
        Button {
            showingAccount = true
        } label: {
            Image(systemName: "person")
                .font(Typeface.body)
                .foregroundStyle(Theme.current(scheme).textPrimary.color)
                .frame(width: Space.s7, height: Space.s7)
                .neumorphic(.subtle, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(Space.s4)
        .accessibilityLabel("Account")
    }

    private func prepareReader() {
        guard reader == nil else { return }
        do {
            reader = try ReaderSetup.makeModel()
        } catch KeyStoreError.keyMissing {
            readerProblem = .keyMissing
        } catch {
            readerProblem = .keyUnavailable
        }
    }
}

private enum ReaderProblem {
    case keyMissing, keyUnavailable

    var title: String {
        switch self {
        case .keyMissing: "Your key isn't on this device"
        case .keyUnavailable: "Your Reader didn't open"
        }
    }

    var detail: String {
        switch self {
        case .keyMissing:
            "Your items are here, still encrypted, but the key that opens them isn't. Totality has left them untouched and won't make a new key over them."
        case .keyUnavailable:
            "Totality couldn't reach this device's key, and it won't replace one it can't read. Go back and try again."
        }
    }
}

/// A module's full-screen message, with the way back home.
private struct ModuleMessage: View {
    let systemImage: String
    let title: String
    let detail: String
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.current(scheme)
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            Button("Home", action: onClose)
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .padding(.top, Space.s3)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.color)
    }
}

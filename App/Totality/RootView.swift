import SwiftUI
import TotalityAccount
import TotalityCalendar
import TotalityCore
import TotalityReader
import TotalityUI

/// Home and whichever module is open. The Reader's model stays alive here, so Listen keeps playing
/// after the person goes back to the home screen.
struct RootView: View {
    @State private var open: ModuleID?
    // Only which module was last open, on this device. It holds no content.
    @AppStorage("home.recentModule") private var recentModule = ModuleID.reader
    @State private var reader: ReaderModel?
    @State private var calendar: CalendarModel?
    @State private var contentProblem: ContentProblem?
    @State private var contentKeys: DeviceContentKeys
    @State private var account: AccountModel?
    @State private var showingAccount = false
    @Environment(\.colorScheme) private var scheme

    init() {
        let keys = DeviceContentKeys()
        _contentKeys = State(initialValue: keys)
        _account = State(initialValue: AccountSetup.makeModel(content: keys))
    }

    var body: some View {
        Group {
            switch open {
            case nil:
                HomeView(center: recentModule) { module in
                    if module == .reader || module == .calendar { prepareContent() }
                    recentModule = module
                    open = module
                }
                .overlay(alignment: .topLeading) { accountButton }
            case .reader:
                if let reader {
                    ReaderHomeView(model: reader) { open = nil }
                } else {
                    contentMessage
                }
            case .calendar:
                if let calendar {
                    CalendarHomeView(model: calendar, onClose: { open = nil }, onOpen: show)
                } else {
                    contentMessage
                }
            case .some(let module):
                ModuleMessage(
                    systemImage: "hammer",
                    title: ModuleEntry.all.first { $0.id == module }?.name ?? "This module",
                    detail: "This isn't built yet. The Reader and Calendar are ready to use."
                ) { open = nil }
            }
        }
        .animation(Motion.standard, value: open)
        .task {
            contentKeys.willMove = {
                await reader?.stopForKeyChange()
                await calendar?.stopForKeyChange()
                reader = nil
                calendar = nil
                contentProblem = nil
            }
            await account?.backup?.settleDevice()
        }
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

    private var contentMessage: some View {
        let problem = contentProblem ?? .keyUnavailable
        return ModuleMessage(systemImage: "lock.slash", title: problem.title, detail: problem.detail) { open = nil }
    }

    private func prepareContent() {
        guard reader == nil else { return }
        guard !contentKeys.isMoving else {
            contentProblem = .keyUnavailable
            return
        }
        do {
            let content = try ContentSetup.makeModels()
            reader = content.reader
            calendar = content.calendar
        } catch KeyStoreError.keyMissing {
            contentProblem = .keyMissing
        } catch {
            contentProblem = .keyUnavailable
        }
    }

    /// Only the Reader's content can be attached so far, so that's where a ref opens.
    private func show(_ ref: ContentRef) {
        guard ref.module == .reader else { return }
        reader?.requestedItem = ref.id
        recentModule = .reader
        open = .reader
    }
}

private enum ContentProblem {
    case keyMissing, keyUnavailable

    var title: String {
        switch self {
        case .keyMissing: "Your key isn't on this device"
        case .keyUnavailable: "This didn't open"
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

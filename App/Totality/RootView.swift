import SwiftUI
import TotalityCore
import TotalityReader
import TotalityUI

/// Home and whichever module is open. The Reader's model stays alive here, so Listen keeps playing
/// after the person goes back to the home screen.
struct RootView: View {
    @State private var open: ModuleID?
    @State private var reader: ReaderModel?
    @State private var readerFailed = false

    var body: some View {
        Group {
            switch open {
            case nil:
                HomeView { module in
                    if module == .reader { prepareReader() }
                    open = module
                }
            case .reader:
                if let reader {
                    ReaderHomeView(model: reader) { open = nil }
                } else {
                    ModuleMessage(
                        systemImage: "lock.slash",
                        title: "Your Reader didn't open",
                        detail: "Totality couldn't reach this device's key, and it won't replace one it can't read. Go back and try again."
                    ) { open = nil }
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
    }

    private func prepareReader() {
        guard reader == nil else { return }
        reader = try? ReaderSetup.makeModel()
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

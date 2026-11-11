import SwiftUI
import TotalityUI

/// A sender's initials on a soft raised circle. Mail carries no pictures of people, so the initials are
/// what tells senders apart at a glance.
struct MailAvatar: View {
    let name: String
    /// Shown instead of initials, for mail that has no sender to show.
    var systemImage: String?
    var size: CGFloat = Space.s6 + Space.s2

    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = (words.count > 1 ? [words.first!, words.last!] : Array(words.prefix(1))).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                Text(Self.initials(name))
            }
        }
            .font(Typeface.callout)
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .neumorphic(.subtle, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Which account's mail a list shows: all of it, Totality's own address, or one outside account.
public enum MailAccountFilter: Hashable, Sendable {
    case all
    case totality
    case outside(UUID)

    func includes(_ message: MailMessage) -> Bool {
        switch self {
        case .all: true
        case .totality: message.outsideAccount == nil
        case .outside(let id): message.outsideAccount?.id == id
        }
    }
}

/// Chips above the list for picking whose mail it shows, once there's more than one account.
struct MailAccountChips: View {
    @Bindable var model: MailModel

    var body: some View {
        let accounts = model.mailbox.outsideAccounts
        if !accounts.isEmpty, case .folder = model.place {
            ScrollView(.horizontal, showsIndicators: false) {
                row(accounts)
            }
        }
    }

    func row(_ accounts: [OutsideAccountLabel]) -> some View {
        HStack(spacing: Space.s2) {
            chip("All", .all)
            chip("Totality", .totality)
            ForEach(accounts, id: \.id) { account in
                chip(Self.name(account, among: accounts), .outside(account.id))
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
    }

    /// The provider's name, with the address when there's more than one of that provider.
    static func name(_ account: OutsideAccountLabel, among accounts: [OutsideAccountLabel]) -> String {
        accounts.filter { $0.provider == account.provider }.count > 1 ? account.address : account.provider.name
    }

    private func chip(_ title: String, _ filter: MailAccountFilter) -> some View {
        let theme = Theme.current
        let isOn = model.shownFilter == filter
        return Button {
            withAnimation(Motion.quick) { model.accountFilter = filter }
        } label: {
            Text(title)
                .font(Typeface.callout)
                .foregroundStyle(isOn ? theme.accent.color : theme.textSecondary.color)
                .lineLimit(1)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .neumorphic(isOn ? .pressed : .subtle, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

import SwiftUI
import TotalityCore
import TotalityUI
#if os(iOS) && canImport(ContactsUI)
import ContactsUI
#endif

/// One person in the list: face, name and the quiet line, as on the canvas.
struct ContactRow: View {
    let card: ContactCard
    let summary: (text: String, isLink: Bool)

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            PersonFace(photo: card.photo, name: card.shownName, diameter: Space.s6 + Space.s1)
            VStack(alignment: .leading, spacing: 0) {
                Text(card.shownName)
                    .font(Typeface.body.weight(.semibold))
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                if !summary.text.isEmpty {
                    Text(summary.text)
                        .font(Typeface.caption.weight(summary.isLink ? .semibold : .regular))
                        .foregroundStyle(summary.isLink ? theme.accent.color : theme.textSecondary.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if card.isFavourite {
                Image(systemName: "star.fill")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityLabel("Favourite")
            }
            Image(systemName: "chevron.right")
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Space.s7 + Space.s1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The favourites, four across, as raised faces.
struct FavouritesRow: View {
    let cards: [ContactCard]
    let onOpen: (ContactCard) -> Void

    var body: some View {
        let theme = Theme.current
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2), count: 4), spacing: Space.s4) {
            ForEach(cards) { card in
                Button { onOpen(card) } label: {
                    VStack(spacing: Space.s2) {
                        PersonFace(photo: card.photo, name: card.shownName, diameter: Space.s8 - Space.s1)
                        Text(card.shortName)
                            .font(Typeface.caption.weight(.semibold))
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel(card.shownName)
            }
        }
        .padding(.vertical, Space.s2)
    }
}

/// "Priya Patel's birthday is Sunday", on the soft accent wash.
struct BirthdayBanner: View {
    let upcoming: Birthdays.Upcoming
    let calendar: Calendar

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Image(systemName: "birthday.cake")
                .font(Typeface.title)
                .foregroundStyle(theme.accent.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(Birthdays.headline(upcoming, in: calendar))
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary.color)
                Text(Birthdays.detail(upcoming, in: calendar))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(theme.highlight.color))
        .accessibilityElement(children: .combine)
    }
}

/// All, then each label. The chosen one is the group that Mail all writes to.
struct LabelPills: View {
    let labels: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                FilterPill("All", isSelected: selection == nil) { withMotion(Motion.snappy) { selection = nil } }
                ForEach(labels, id: \.self) { label in
                    FilterPill(label, isSelected: selection == label) { withMotion(Motion.snappy) { selection = label } }
                }
            }
            .padding(Space.s2)
        }
    }
}

/// "Encrypting 212 of 480", while an import seals cards.
struct ImportProgress: View {
    let progress: ContactsModel.Progress

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Encrypting \(progress.done) of \(progress.total)")
                .font(Typeface.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .tint(theme.accent.color)
        }
        .itemCard()
    }
}

/// A one-off line about what just happened, with a button to put it away.
struct NoticeLine: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(alignment: .top, spacing: Space.s2) {
            Text(text)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s6, height: Space.s6)
            }
            .buttonStyle(SoftPress())
            .accessibilityLabel("Dismiss")
        }
    }
}

/// The line under the list. It's literally true: cards are sealed on the device and the server holds only
/// ciphertext (rule 5).
struct PrivacyLine: View {
    var body: some View {
        Label("Your contacts are end-to-end encrypted. Totality's server can't read them.", systemImage: "lock")
            .font(Typeface.micro)
            .foregroundStyle(Theme.current.textSecondary.color)
            .padding(.horizontal, Space.s2)
    }
}

struct PlaceholderBlock: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
            .fill(Theme.current.surface.color)
            .frame(height: height)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A plain message filling the screen, for when Contacts can't open.
struct ContactsMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Spacer()
            Image(systemName: systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity)
    }
}

struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(iOS)
        TileButton("Open Settings", systemImage: "gear") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        #endif
    }
}

/// The system's contact access picker, which lets someone on limited access share more contacts without
/// sharing them all (iOS 18 and later).
enum DevicePicker {
    static var isAvailable: Bool {
        #if os(iOS) && canImport(ContactsUI)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }
}

extension View {
    @ViewBuilder
    func devicePicker(isPresented: Binding<Bool>, onDone: @escaping () -> Void) -> some View {
        #if os(iOS) && canImport(ContactsUI)
        if #available(iOS 18.0, *) {
            contactAccessPicker(isPresented: isPresented) { _ in onDone() }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

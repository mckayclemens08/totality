import SwiftUI
import TotalityCore
import TotalityUI

/// Contacts' home tile at each size, as on the approved canvas (artboard ContactsTiles, issue 127's rule).
/// Small is a glance: the next birthday, or the favourites' faces. Medium lists the favourites, each with
/// Message and Call. Large has the favourites with their actions, upcoming birthdays, and a Search button that
/// opens a sheet, since tiles hold no text fields.
public struct ContactsHomeTile: View {
    private let model: ContactsModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void
    @State private var searching = false
    @Environment(\.openURL) private var openURL

    public init(model: ContactsModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            if model.live.isEmpty {
                quiet
            } else {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .tilePadding()
        .sheet(isPresented: $searching) {
            ContactSearchSheet(model: model) { card in
                searching = false
                if let card { open(card) }
            }
        }
    }

    /// The favourites, or the first people in the list when none are chosen yet.
    private var people: [ContactCard] {
        let favourites = model.favourites
        return favourites.isEmpty ? Array(model.live.prefix(4)) : Array(favourites.prefix(4))
    }

    private func open(_ card: ContactCard?) {
        model.requestedCard = card?.id
        onOpen()
    }

    private var quiet: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            TileHeader("Contacts", systemImage: "person.crop.circle")
            Spacer(minLength: 0)
            Text("No contacts yet")
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
        }
    }

    // MARK: Small

    @ViewBuilder
    private var small: some View {
        let theme = Theme.current
        if let next = model.upcoming.first, next.daysAway <= 14 {
            Button { open(next.card) } label: {
                VStack(alignment: .leading, spacing: Space.s1) {
                    TileHeader("Birthday · \(Birthdays.when(next, in: model.calendar).capitalizedFirst)", systemImage: "birthday.cake", isTinted: true)
                    PersonFace(photo: next.card.photo, name: next.card.shownName, diameter: Space.s7)
                        .padding(.top, Space.s2)
                    Spacer(minLength: 0)
                    Text(next.card.shownName)
                        .font(Typeface.callout.weight(.bold))
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Text(next.turning.map { "Turning \($0) · \(Birthdays.dayMonth(next.date, in: model.calendar))" } ?? Birthdays.dayMonth(next.date, in: model.calendar))
                        .font(Typeface.tileDetail)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
        } else {
            VStack(alignment: .leading, spacing: Space.s2) {
                TileHeader("Contacts", systemImage: "person.crop.circle")
                Spacer(minLength: 0)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.s2) {
                    ForEach(people) { card in
                        Button { open(card) } label: { PersonFace(photo: card.photo, name: card.shownName, diameter: Space.s6 + Space.s2) }
                            .buttonStyle(SoftPress())
                            .accessibilityLabel(card.shownName)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Medium

    private var medium: some View {
        let theme = Theme.current
        return HStack(alignment: .top, spacing: Space.s2) {
            ForEach(people) { card in
                VStack(spacing: Space.s1) {
                    Button { open(card) } label: { PersonFace(photo: card.photo, name: card.shownName, diameter: Space.s7) }
                        .buttonStyle(SoftPress())
                        .accessibilityLabel(card.shownName)
                    Text(card.shortName)
                        .font(Typeface.tileLabel)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    HStack(spacing: Space.s1) {
                        if let handle = card.username, model.onMessage != nil {
                            SmallAction("Message \(card.shortName)", systemImage: "message") { model.onMessage?(handle) }
                        }
                        if let phone = card.phoneNumbers.first {
                            SmallAction("Call \(card.shortName)", systemImage: "phone") { call(phone) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Large

    private var large: some View {
        let theme = Theme.current
        let birthdays = Array(model.upcoming.prefix(2))
        return VStack(alignment: .leading, spacing: Space.s2) {
            Button { searching = true } label: {
                Label("Search contacts", systemImage: "magnifyingglass")
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.horizontal, Space.s4)
                    .frame(maxWidth: .infinity, minHeight: Space.s6 + Space.s2, alignment: .leading)
                    .neumorphic(.subtle, in: Capsule())
            }
            .buttonStyle(SoftPress())
            TileList(Array(people.prefix(3))) { card in
                HStack(spacing: Space.s2) {
                    Button { open(card) } label: {
                        HStack(spacing: Space.s2) {
                            PersonFace(photo: card.photo, name: card.shownName, diameter: Space.s6 + Space.s1)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(card.shownName)
                                    .font(Typeface.tileRow.weight(.semibold))
                                    .foregroundStyle(theme.textPrimary.color)
                                    .lineLimit(1)
                                Text(ContactSearch.summary(card, upcoming: model.upcoming(for: card), calendar: model.calendar).text)
                                    .font(Typeface.tileDetail)
                                    .foregroundStyle(theme.textSecondary.color)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPress())
                    if let handle = card.username, model.onMessage != nil {
                        SmallAction("Message \(card.shortName)", systemImage: "message") { model.onMessage?(handle) }
                    }
                    let mails = ContactCardView.mailAddresses(card)
                    if !mails.isEmpty, model.onMail != nil {
                        SmallAction("Mail \(card.shortName)", systemImage: "envelope") { model.onMail?([mails[0]]) }
                    }
                    if let phone = card.phoneNumbers.first {
                        SmallAction("Call \(card.shortName)", systemImage: "phone") { call(phone) }
                    }
                }
                .padding(.horizontal, Space.s2)
                .padding(.vertical, Space.s1)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(theme.bg.color))
            }
            Spacer(minLength: 0)
            if !birthdays.isEmpty {
                HStack(spacing: Space.s2) {
                    ForEach(birthdays) { next in
                        Text(Birthdays.dayMonth(next.date, in: model.calendar))
                            .font(Typeface.tileLabel)
                            .foregroundStyle(theme.accent.color)
                        Text(next.card.shortName)
                            .font(Typeface.tileDetail)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(birthdays.map { Birthdays.headline($0, in: model.calendar) }.joined(separator: ". "))
            }
        }
    }

    private func call(_ number: String) {
        let plus = number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        let digits = ContactSearch.digits(number)
        if !digits.isEmpty, let url = URL(string: "tel:\(plus)\(digits)") { openURL(url) }
    }
}

/// A small raised round action on a tile. Its title is what VoiceOver says.
struct SmallAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.micro)
                .foregroundStyle(Theme.current.accent.color)
                .frame(width: Space.s6, height: Space.s6)
                .neumorphic(.subtle, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(title)
    }
}

extension String {
    /// "sunday" → "Sunday", leaving the rest as it is.
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}

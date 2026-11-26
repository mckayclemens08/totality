import SwiftUI
import TotalityCore
import TotalityUI

/// Contacts' screen, as on the approved canvas (artboards Contacts and ContactsEmpty): Home, Search and New in
/// the header, the title with the count, favourites, the next birthday, the labels, then everyone.
public struct ContactsHomeView: View {
    @Bindable private var model: ContactsModel
    private let onClose: (() -> Void)?
    @State private var opened: ContactCard?
    @State private var editing: ContactEditing?
    @State private var showsSearch = false
    @State private var showsDeleted = false
    @State private var showsSettings = false
    @State private var importing: [DeviceContact]?
    @State private var showsPicker = false

    public init(model: ContactsModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.bg.color)
        .edgeSwipeBack(onClose)
        .task {
            if model.phase == .loading { await model.load() }
            if let card = model.takeRequest() { opened = card }
        }
        .onChange(of: model.requestedCard) {
            if let card = model.takeRequest() { opened = card }
        }
        .sheet(item: $opened) { card in
            ContactCardView(model: model, id: card.id) { opened = nil }
        }
        .sheet(item: $editing) { editing in
            ContactEditor(model: model, original: editing.card) { saved in
                self.editing = nil
                if let saved, editing.card == nil { opened = saved }
            }
        }
        .sheet(isPresented: $showsSearch) {
            ContactSearchSheet(model: model) { card in
                showsSearch = false
                if let card { opened = card }
            }
        }
        .sheet(isPresented: $showsDeleted) {
            RecentlyDeletedSheet(model: model) { showsDeleted = false }
        }
        .sheet(isPresented: $showsSettings) {
            ContactsSettingsSheet(model: model) { showsSettings = false }
        }
        .sheet(item: Binding(get: { importing.map(ImportChoice.init) }, set: { if $0 == nil { importing = nil } })) { choice in
            ImportSheet(model: model, contacts: choice.contacts) { importing = nil }
        }
        .devicePicker(isPresented: $showsPicker) { Task { await chooseFromPhone(afterPicker: true) } }
    }

    struct ImportChoice: Identifiable {
        let contacts: [DeviceContact]
        var id: Int { contacts.count }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            if let onClose {
                HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
            }
            Spacer(minLength: 0)
            if model.phase == .ready, !model.isEmpty {
                HeaderButton("Search contacts", systemImage: "magnifyingglass") { showsSearch = true }
                HeaderMenu("More", systemImage: "ellipsis") {
                    Button("Choose from iPhone Contacts", systemImage: "iphone") { Task { await chooseFromPhone() } }
                    Button("Recently Deleted", systemImage: "trash") { showsDeleted = true }
                    Button("Contacts settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                }
                HeaderButton("New contact", systemImage: "plus") { editing = ContactEditing(card: nil) }
            }
        }
        .frame(minHeight: Metric.headerButton)
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView {
                VStack(spacing: Space.s4) {
                    PlaceholderBlock(height: Space.s8 + Space.s4)
                    PlaceholderBlock(height: Space.s8 * 5)
                }
                .padding(Space.s4)
            }
        case .failed:
            ContactsMessage(
                systemImage: "lock.slash", title: "Contacts can't open",
                detail: "Your contacts couldn't be read on this device. Your other content isn't affected."
            )
        case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if model.isEmpty { emptyState } else { list }
                }
                .padding(.horizontal, Space.s4)
                .padding(.bottom, Space.s6)
            }
            .refreshable { await model.refresher.refresh(.pulled) }
        }
    }

    // MARK: The list

    @ViewBuilder
    private var list: some View {
        let theme = Theme.current
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Text(model.label ?? "Contacts")
                .font(Typeface.display)
                .foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            Text("\(model.shown.count)")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
            if model.label != nil, !model.groupAddresses.isEmpty {
                HeaderPill("Mail all \(model.groupAddresses.count)", isProminent: true) {
                    model.onMail?(Array(model.groupAddresses.prefix(ContactsModel.mailLimit)))
                }
                .disabled(model.onMail == nil)
            }
        }
        if let progress = model.progress {
            ImportProgress(progress: progress)
        }
        if let notice = model.notice {
            NoticeLine(text: notice) { model.notice = nil }
        }
        if model.label == nil, !model.favourites.isEmpty {
            FavouritesRow(cards: Array(model.favourites.prefix(8))) { opened = $0 }
        }
        if model.label == nil, let next = model.upcoming.first, next.daysAway <= 14 {
            Button { opened = next.card } label: { BirthdayBanner(upcoming: next, calendar: model.calendar) }
                .buttonStyle(SoftPress())
        }
        if !model.labels.isEmpty {
            LabelPills(labels: model.labels, selection: $model.label)
        }
        if let label = model.label, model.groupAddresses.count > ContactsModel.mailLimit {
            Text("\(label) has \(model.groupAddresses.count) addresses. Mail writes to the first \(ContactsModel.mailLimit) at once.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        if model.unreadable > 0 {
            Label("\(model.unreadable) \(model.unreadable == 1 ? "card" : "cards") couldn't be opened on this device. \(model.unreadable == 1 ? "It's" : "They're") kept.", systemImage: "exclamationmark.triangle")
                .font(Typeface.caption)
                .foregroundStyle(theme.danger.color)
        }
        LazyVStack(spacing: 0) {
            ForEach(model.shown) { card in
                Button { opened = card } label: {
                    ContactRow(card: card, summary: ContactSearch.summary(card, upcoming: model.upcoming(for: card), calendar: model.calendar))
                }
                .buttonStyle(SoftPress())
                .contextMenu { rowMenu(card) }
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s1)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        PrivacyLine()
    }

    @ViewBuilder
    private func rowMenu(_ card: ContactCard) -> some View {
        Button(card.isFavourite ? "Remove from Favourites" : "Add to Favourites", systemImage: card.isFavourite ? "star.slash" : "star") {
            Task { await model.toggleFavourite(card) }
        }
        Button("Edit", systemImage: "pencil") { editing = ContactEditing(card: card) }
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(card) } }
    }

    // MARK: Empty

    private var emptyState: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s4) {
            ScreenTitle("Contacts")
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: Space.s6 + Space.s2))
                .foregroundStyle(theme.accent.color)
                .frame(width: Space.s8 + Space.s6, height: Space.s8 + Space.s6)
                .neumorphic(.raised, in: Circle())
                .padding(.top, Space.s7)
                .accessibilityHidden(true)
            Text("No contacts yet")
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Text("Bring in people from your iPhone, or add someone yourself.")
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            if let notice = model.notice {
                NoticeLine(text: notice) { model.notice = nil }
            }
            if let progress = model.progress {
                ImportProgress(progress: progress)
            }
            if model.device != nil, model.deviceAccess != .denied {
                TileButton("Choose from iPhone Contacts", systemImage: "iphone", isProminent: true) { Task { await chooseFromPhone() } }
            }
            TileButton("Add a contact", systemImage: "plus") { editing = ContactEditing(card: nil) }
            if model.deviceAccess == .denied, model.device != nil {
                Text("Totality can't see your iPhone contacts. You can still add contacts here, or allow access in Settings.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
                OpenSettingsButton()
            }
            HStack(alignment: .top, spacing: Space.s3) {
                Image(systemName: "lock")
                    .foregroundStyle(theme.accent.color)
                    .accessibilityHidden(true)
                Text("You pick which contacts Totality can see. They're encrypted on this iPhone before they sync. Totality never uploads your address book or checks it against other people on Totality.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .itemCard()
            .padding(.top, Space.s5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: iPhone Contacts

    /// Asks for access the first time, then lists what can be copied. With limited access the system
    /// picker adds more first, without asking for everything (section 4).
    private func chooseFromPhone(afterPicker: Bool = false) async {
        let access = await model.askForDeviceAccess()
        switch access {
        case .denied, .notAsked:
            model.notice = "Totality can't see your iPhone contacts. You can still add contacts here, or allow access in Settings."
        case .limited where !afterPicker && DevicePicker.isAvailable:
            showsPicker = true
        case .limited, .full:
            let waiting = await model.notYetCopied()
            if waiting.isEmpty {
                model.notice = access == .limited
                    ? "Every contact you've shared with Totality is already here. Choose from iPhone Contacts again to share more."
                    : "Every contact on this iPhone is already here."
            } else {
                importing = waiting
            }
        }
    }
}

/// A new card, or one being edited.
struct ContactEditing: Identifiable {
    let card: ContactCard?
    var id: UUID { card?.id ?? Self.new }
    private static let new = UUID()
}

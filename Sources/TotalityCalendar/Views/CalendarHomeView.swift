import AuthenticationServices
import SwiftUI
import TotalityCore
import TotalityUI

/// The Calendar's front screen: one header, and whichever of the four views is showing.
public struct CalendarHomeView: View {
    /// How far a swipe has to go, so a scroll that drifts sideways doesn't change the page.
    private static let swipeDistance = Space.s7

    @Bindable private var model: CalendarModel
    private let onClose: (() -> Void)?
    private let onOpen: (ContentRef) -> Void
    @State private var path: [CalendarEntry] = []
    @State private var creating: EventDraft?
    @State private var showingSources = false
    @State private var movingForward = true

    public init(model: CalendarModel, onClose: (() -> Void)? = nil, onOpen: @escaping (ContentRef) -> Void = { _ in }) {
        self.model = model
        self.onClose = onClose
        self.onOpen = onOpen
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack(path: $path) {
            content
                .background(theme.bg.color)
                .edgeSwipeBack(onClose)
                .navigationDestination(for: CalendarEntry.self) { entry in
                    EventDetailView(entry: entry, model: model, onOpen: onOpen) { path.removeAll() }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                // The Calendar draws its own header (redesign, 2026-11-17).
                .toolbar(.hidden, for: .navigationBar)
                #else
                .navigationTitle("Calendar")
                #endif
        }
        .tint(theme.accent.color)
        .safeAreaInset(edge: .bottom) {
            if model.skippedAlerts > 0, path.isEmpty {
                Text("\(model.skippedAlerts) \(model.skippedAlerts == 1 ? "alert is" : "alerts are") waiting. Totality keeps \(ReminderPlanner.limit) calendar alerts set at once. The rest are set up as these ring and when you open Calendar.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .padding(.horizontal, Space.s4)
                    .padding(.trailing, Metric.headerButton + Space.s4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.phase == .ready, path.isEmpty {
                AddButton("New event") { creating = model.newDraft() }
                    .padding(Space.s4)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: isCreating) {
            if let creating {
                NavigationStack {
                    EventEditorView(model: model, draft: creating, occurrence: nil) { self.creating = nil }
                }
                .tint(theme.accent.color)
            }
        }
        .sheet(isPresented: $showingSources) {
            NavigationStack {
                DeviceCalendarsView(model: model) { showingSources = false }
            }
            .tint(theme.accent.color)
        }
        .alert("Calendar", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .task {
            model.showFront()
            await model.load()
            model.takeRequestedDay()
            if let entry = model.takeRequestedEntry() { path = [entry] }
        }
        // The app keeps every source fresh before the Calendar opens. Pulling down asks straight away.
        .pullsToRefresh(with: model.refresher)
    }

    private var isCreating: Binding<Bool> {
        Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    /// Home, back to today, and the view menu, which also reaches Google and device calendars.
    private var buttons: some View {
        HStack(spacing: Space.s3) {
            if let onClose {
                HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
            }
            Spacer(minLength: 0)
            if model.phase == .ready {
                if !model.isShowingToday {
                    HeaderPill("Today") {
                        movingForward = model.selectedDay < model.today
                        withMotion(Motion.snappy) { model.showToday() }
                    }
                }
                HeaderMenu("View", systemImage: model.mode.toolbarImage) {
                    Picker("View", selection: $model.mode) {
                        ForEach(CalendarModel.Mode.allCases, id: \.self) { mode in
                            Label(model.name(of: mode), systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    Divider()
                    Button("Calendars", systemImage: "calendar.badge.checkmark") { showingSources = true }
                }
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: Space.s3) {
            buttons
            phaseContent
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .loading:
            ProgressView("Opening your calendar")
                .font(Typeface.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            CalendarMessage(
                systemImage: "exclamationmark.triangle",
                title: "Your calendar didn't open",
                detail: "This device's storage couldn't be read. Close the Calendar and try again."
            )
        case .ready:
            VStack(spacing: Space.s3) {
                header
                if model.mode == .day { WeekStrip(model: model) }
                if model.mode == .day || model.mode == .week, let forecast = model.dayForecast {
                    DayForecastChip(forecast: forecast)
                }
                UnreadableNote(model: model)
                RefreshStatusLine(model.refresher)
                GoogleSyncNote(model: model)
                page
                    .id(model.title)
                    .transition(.push(from: movingForward ? .trailing : .leading))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            #if os(iOS)
            .simultaneousGesture(swipe)
            #endif
        }
    }

    @ViewBuilder private var page: some View {
        switch model.mode {
        case .month:
            MonthView(model: model) { path.append($0) }
        case .day, .week:
            DayTimelineView(model: model, onOpen: { path.append($0) }) { day, hour in
                creating = model.newDraft(on: day, hour: hour)
            }
        case .schedule:
            schedule
        }
    }

    private var header: some View {
        ScreenTitle(model.title)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityAction(named: "Previous") { move(by: -1) }
            .accessibilityAction(named: "Next") { move(by: 1) }
            #if os(macOS)
            .overlay(alignment: .trailing) {
                if model.canMove {
                    HStack {
                        Button("Previous", systemImage: "chevron.left") { move(by: -1) }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("Next", systemImage: "chevron.right") { move(by: 1) }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }
            }
            #endif
            .padding(.horizontal, Space.s4)
    }

    private func move(by steps: Int) {
        guard model.canMove else { return }
        movingForward = steps > 0
        withMotion(Motion.snappy) { model.move(by: steps) }
    }

    #if os(iOS)
    private var swipe: some Gesture {
        DragGesture(minimumDistance: Space.s5).onEnded { drag in
            let across = drag.translation.width
            guard abs(across) > Self.swipeDistance, abs(across) > abs(drag.translation.height) * 2 else { return }
            move(by: across < 0 ? 1 : -1)
        }
    }
    #endif

    @ViewBuilder private var schedule: some View {
        let theme = Theme.current
        let days = model.schedule
        if days.isEmpty && model.unreadable == 0 {
            CalendarMessage(
                systemImage: "calendar",
                title: "Nothing coming up",
                detail: model.isSynced
                    ? "Add an event, or show your Apple and Google calendars here. Events you add here are encrypted, and sync between your devices."
                    : "Add an event, or show your Apple and Google calendars here. Events you add here are encrypted and aren't synced between your devices yet."
            )
        } else {
            let next = model.nextEntry?.id
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s3, pinnedViews: .sectionHeaders) {
                    ForEach(days, id: \.day) { day in
                        Section {
                            ForEach(day.entries) { entry in
                                EventTile(entry: entry, isNext: entry.id == next)
                                    .tappable { path.append(entry) }
                            }
                        } header: {
                            Text(scheduleHeading(day.day, count: day.entries.count))
                                .font(Typeface.caption.weight(.semibold))
                                .foregroundStyle(theme.textSecondary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Space.s1)
                                .background(theme.bg.color)
                        }
                    }
                }
                .padding(.horizontal, Space.s4)
                // Room for the + button over the last event.
                .padding(.bottom, Metric.addButton + Space.s5)
            }
        }
    }

    /// "Tuesday · 4 events", as on the canvas.
    private func scheduleHeading(_ day: CalendarDay, count: Int) -> String {
        "\(model.heading(for: day)) · \(count == 1 ? "1 event" : "\(count) events")"
    }
}

/// The week around the chosen day, over the Day view: the chosen day filled with the accent, and a dot
/// under each day that has something on it.
struct WeekStrip: View {
    let model: CalendarModel

    private var days: [CalendarDay] {
        let display = model.display
        let weekday = display.component(.weekday, from: model.selectedDay.start(in: display))
        let first = model.selectedDay.adding(days: -((weekday - display.firstWeekday + 7) % 7), in: display)
        return (0..<7).map { first.adding(days: $0, in: display) }
    }

    var body: some View {
        HStack(spacing: Space.s1 / 2) {
            ForEach(days, id: \.self) { day in
                cell(day)
            }
        }
        .padding(Space.s1 + Space.s1 / 2)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .padding(.horizontal, Space.s4)
    }

    private func cell(_ day: CalendarDay) -> some View {
        let theme = Theme.current
        let isChosen = day == model.selectedDay
        let hasEvents = !model.entries(on: day).isEmpty
        return VStack(spacing: Space.s1) {
            Text(model.written(day, .dateTime.weekday(.narrow)))
                .font(Typeface.micro)
                .foregroundStyle(isChosen ? theme.accentOn.color : theme.textSecondary.color)
            Text("\(day.day)")
                .font(Typeface.headline)
                .monospacedDigit()
                .foregroundStyle(isChosen ? theme.accentOn.color : (day == model.today ? theme.accent.color : theme.textPrimary.color))
            Circle()
                .fill(isChosen ? theme.accentOn.color : theme.accent.color)
                .frame(width: Space.s1, height: Space.s1)
                .opacity(hasEvents ? 1 : 0)
        }
        .padding(.vertical, Space.s2)
        .frame(maxWidth: .infinity)
        .background {
            if isChosen {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(theme.accent.color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.written(day, .dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(hasEvents ? "Has events" : "")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .tappable { withMotion(Motion.snappy) { model.select(day) } }
    }
}

/// The one note that stays on the main screen, because it's a problem the person should see.
struct UnreadableNote: View {
    let model: CalendarModel

    private var text: String {
        model.unreadable == 1
            ? "1 event can't be opened on this device."
            : "\(model.unreadable) events can't be opened on this device."
    }

    var body: some View {
        if model.unreadable > 0 {
            Label(text, systemImage: "lock.slash")
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.danger.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
        }
    }
}

/// Says when Google Calendar couldn't be read, and why.
struct GoogleSyncNote: View {
    let model: CalendarModel

    var body: some View {
        let theme = Theme.current
        // The refresh line covers being offline for every source, so this only adds Google's own problems.
        if model.refresher.problem == nil, let status = model.googleStatus {
            Label(status, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(Typeface.caption)
                .foregroundStyle(theme.danger.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
        }
    }
}

struct CalendarMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
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
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceCalendarsView: View {
    let model: CalendarModel
    let onDone: () -> Void
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var disconnecting: String?
    @State private var disconnectingAlsoEnds: Set<GoogleUse> = []

    var body: some View {
        let theme = Theme.current
        Form {
            if model.canUseGoogle { GoogleCalendarsSection(model: model, signingIn: signIn, disconnect: askToDisconnect) }
            Section("Events you add here") {
                Label(
                    model.isSynced
                        ? "Encrypted, and synced between your devices."
                        : "Encrypted, and can't be recovered on a new device yet.",
                    systemImage: model.isSynced ? "lock" : "iphone"
                )
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
            }
            switch model.deviceAccess {
            case .notAsked:
                Section {
                    Text("Show the calendars already on this device, including any Google account you've added to it. They're read-only here, Totality doesn't copy or encrypt them, and Apple or Google keeps them in sync.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                    Button("Show my calendars") { Task { await model.allowDeviceCalendars() } }
                }
            case .denied:
                Section {
                    Text("Totality can't see this device's calendars. You can allow it in Settings, under Privacy & Security, then Calendars.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                }
            case .allowed:
                Section {
                    if model.deviceCalendars.isEmpty {
                        Text("There are no calendars on this device yet.")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    ForEach(model.deviceCalendars) { calendar in
                        Toggle(isOn: visible(calendar)) {
                            VStack(alignment: .leading, spacing: Space.s1) {
                                Text(calendar.title).font(Typeface.body)
                                if !calendar.account.isEmpty {
                                    Text(calendar.account)
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textSecondary.color)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Read-only here. Totality doesn't copy or encrypt these.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .navigationTitle("Calendars")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
        .confirmationDialog(
            "Disconnect \(disconnecting ?? "this Google account")?", isPresented: isDisconnecting, titleVisibility: .visible,
            presenting: disconnecting
        ) { account in
            Button("Disconnect", role: .destructive) { Task { await model.disconnectGoogle(account) } }
        } message: { _ in
            Text(GoogleCalendarWording.disconnecting(alsoEnds: disconnectingAlsoEnds))
        }
    }

    private var signIn: GoogleWebSignIn {
        let session = webAuthenticationSession
        return { page, scheme in
            try await session.authenticate(using: page, callbackURLScheme: scheme, preferredBrowserSession: .shared)
        }
    }

    private func askToDisconnect(_ account: String) {
        Task {
            disconnectingAlsoEnds = await model.googleAlsoEnds(account)
            disconnecting = account
        }
    }

    private var isDisconnecting: Binding<Bool> {
        Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })
    }

    private func visible(_ calendar: DeviceCalendar) -> Binding<Bool> {
        Binding(
            get: { !model.hiddenCalendars.contains(calendar.id) },
            set: { model.setVisible($0, calendar: calendar) }
        )
    }
}

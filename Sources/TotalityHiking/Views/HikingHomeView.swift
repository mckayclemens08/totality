import SwiftUI
import TotalityCore
import TotalityUI

/// Hiking's screen, as in the mockup (issue 240): Nearby, Saved and Hikes, with Record in the header.
/// Pull down on Nearby for a fresh list.
public struct HikingHomeView: View {
    @Bindable private var model: HikingModel
    private let onClose: (() -> Void)?
    @State private var section = Section.nearby
    @State private var openTrail: TrailChoice?
    @State private var openHike: Hike?
    @State private var showsRecording = false
    @State private var showsStatistics = false
    @State private var showsImporter = false
    @State private var importing: ImportChoice?
    @State private var moving: Trail?
    @State private var groupChoice = GroupChoice.all
    @State private var newGroupName = ""
    @State private var makingGroup = false
    @State private var managing: HikeGroup?
    @State private var renamedGroup = ""
    @State private var renamingGroup = false
    @State private var confirmsDeleteGroup = false

    struct ImportChoice: Identifiable {
        let url: URL
        var id: URL { url }
    }

    enum GroupChoice: Hashable {
        case all, group(UUID)
    }

    enum Section: String, CaseIterable, Hashable {
        case nearby = "Nearby", saved = "Saved", hikes = "Hikes"
    }

    struct TrailChoice: Identifiable {
        let id: String
    }

    public init(model: HikingModel, onClose: (() -> Void)? = nil) {
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
        .overlay(alignment: .bottom) { undoBar }
        .task {
            if model.phase == .loading { await model.load() }
            openRequested()
            takePendingImport()
            if model.nearbyState == .idle { await model.loadNearby() }
        }
        .onChange(of: model.requestedItem) { openRequested() }
        .onChange(of: model.pendingImport) { takePendingImport() }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.gpx, .xml]) { result in
            if case .success(let url) = result { importing = ImportChoice(url: url) }
        }
        .sheet(item: $importing) { choice in
            GPXImportView(model: model, url: choice.url) { importing = nil }
        }
        .sheet(item: $moving) { trail in
            MoveToGroupView(model: model, trail: trail) { moving = nil }
        }
        .sheet(isPresented: $showsStatistics) {
            StatisticsView(model: model) { showsStatistics = false } onOpenHike: { hike in
                showsStatistics = false
                section = .hikes
                openHike = hike
            }
        }
        .alert("New group", isPresented: $makingGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                Task {
                    if let group = await model.createGroup(named: newGroupName) { groupChoice = .group(group.id) }
                    newGroupName = ""
                }
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        } message: {
            Text("Up to \(HikeGroup.maxNameLength) characters. Sealed with your key like the trails.")
        }
        .alert("Rename group", isPresented: $renamingGroup) {
            TextField("Name", text: $renamedGroup)
            Button("Rename") {
                if let managing { Task { await model.renameGroup(managing, to: renamedGroup) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this group?", isPresented: $confirmsDeleteGroup, titleVisibility: .visible) {
            Button("Delete group", role: .destructive) {
                if let managing {
                    groupChoice = .all
                    Task { await model.deleteGroup(managing) }
                }
            }
        } message: {
            Text("Its trails move to All saved. None are deleted.")
        }
        .onChange(of: model.recording != nil) { _, isOn in if isOn { showsRecording = true } }
        .sheet(item: $openTrail) { choice in
            TrailDetailView(model: model, trailID: choice.id) { openTrail = nil } onStart: {
                openTrail = nil
            }
        }
        .sheet(item: $openHike) { hike in
            HikeDetailView(model: model, hike: hike) { openHike = nil }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsRecording) {
            RecordingView(model: model) { showsRecording = false }
        }
        #else
        .sheet(isPresented: $showsRecording) {
            RecordingView(model: model) { showsRecording = false }
        }
        #endif
    }

    /// A .gpx handed over from Files or a share sheet opens the import screen on Saved.
    private func takePendingImport() {
        guard model.phase == .ready, let url = model.pendingImport else { return }
        model.pendingImport = nil
        section = .saved
        importing = ImportChoice(url: url)
    }

    private func openRequested() {
        guard model.phase == .ready, let item = model.requestedItem else { return }
        model.requestedItem = nil
        if let id = UUID(uuidString: item), let hike = model.hikes.first(where: { $0.id == id }) {
            section = .hikes
            openHike = hike
        } else if model.trail(item) != nil {
            section = .saved
            openTrail = TrailChoice(id: item)
        }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            if let onClose {
                HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
            }
            Spacer(minLength: 0)
            AskTotalityButton(context: AIAskContext(id: "hiking.home", module: .hiking, title: "Hiking"))
            if model.phase == .ready {
                HeaderButton("Statistics", systemImage: "chart.bar.fill") { showsStatistics = true }
                if model.recording != nil {
                    HeaderPill("Recording", systemImage: "record.circle", isProminent: true) { showsRecording = true }
                } else {
                    HeaderPill("Record", systemImage: "figure.hiking", isProminent: true) { model.startRecording() }
                        .disabled(model.locationAccess == .denied)
                }
            }
        }
        .frame(minHeight: Metric.headerButton)
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }

    @ViewBuilder
    private var content: some View {
        let theme = Theme.current
        switch model.phase {
        case .loading:
            ScrollView { loadingCards.padding(Space.s4) }
        case .failed:
            HikingMessage(
                systemImage: "lock.slash", title: "Hiking can't open",
                detail: "Your hikes couldn't be read on this iPhone. Your other content isn't affected."
            )
            .frame(maxHeight: .infinity)
        case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    ScreenTitle(title, subtitle: subtitle)
                    FilterPills(Section.allCases, selection: $section) { $0.rawValue }
                    if let notice = model.notice {
                        Text(notice)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .task(id: notice) {
                                try? await Task.sleep(for: .seconds(4))
                                if model.notice == notice { model.notice = nil }
                            }
                    }
                    switch section {
                    case .nearby: nearby
                    case .saved: savedList
                    case .hikes: hikeList
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.bottom, Space.s7)
            }
            .refreshable { if section == .nearby { await model.pull() } }
        }
    }

    private var title: String {
        switch section {
        case .nearby: "Trails near you"
        case .saved: "Saved trails"
        case .hikes: "Your hikes"
        }
    }

    private var subtitle: String? {
        switch section {
        case .nearby: "Within \(model.units.distance(Double(OverpassTrails.radius))) · pull to refresh"
        case .saved: "Kept on this iPhone for offline use"
        case .hikes: "Sealed on this iPhone"
        }
    }

    // MARK: Nearby

    @ViewBuilder
    private var nearby: some View {
        let theme = Theme.current
        switch model.nearbyState {
        case .idle, .loading where model.nearby.isEmpty:
            loadingCards
        case .noLocation:
            HikingMessage(
                systemImage: "location.slash", title: "Location is off for Totality",
                detail: "Turn it on in Settings › Privacy › Location Services to see trails nearby and record hikes. Your saved trails still open."
            )
        case .offline where model.nearby.isEmpty:
            HikingMessage(systemImage: "wifi.slash", title: "You're offline", detail: "Trails nearby need a connection. Your saved trails and hikes still open, and recording works with no signal.")
        case .failed where model.nearby.isEmpty:
            HikingMessage(systemImage: "exclamationmark.arrow.triangle.2.circlepath", title: "Trails couldn't load", detail: "OpenStreetMap's free servers are busy or didn't answer. Pull down to try again.")
        default:
            if model.nearbyState == .offline || model.nearbyState == .failed {
                Label(model.nearbyState == .offline ? "You're offline. This is the last list." : "Couldn't refresh. This is the last list.", systemImage: "wifi.slash")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            if model.nearby.isEmpty {
                HikingMessage(systemImage: "map", title: "No named trails nearby", detail: "OpenStreetMap has no named hiking trails within this distance.")
            }
            ForEach(model.nearby) { trail in
                trailRow(trail)
            }
            credit
        }
    }

    private func trailRow(_ trail: Trail) -> some View {
        let theme = Theme.current
        let units = model.units
        return Button {
            openTrail = TrailChoice(id: trail.id)
        } label: {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trail.name)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: Space.s2)
                    DifficultyBadge(difficulty: model.trail(trail.id)?.difficulty ?? trail.difficulty)
                }
                HStack(spacing: Space.s3) {
                    Text(units.distance(trail.metres)).foregroundStyle(theme.textPrimary.color)
                    if let climb = model.trail(trail.id)?.climb { Text(units.climb(climb)) }
                    if let here = model.here { Text("\(units.distance(trail.distance(from: here))) away") }
                    if let group = model.group(named: model.trail(trail.id)?.groupID) { Text(group.name) }
                    if model.isSaved(trail) { Label("Saved", systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon) }
                }
                .font(Typeface.caption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
            }
            .itemCard()
        }
        .buttonStyle(SoftPress())
        .accessibilityHint("Shows the trail")
    }

    private var credit: some View {
        Text(OverpassTrails.credit)
            .font(Typeface.micro)
            .foregroundStyle(Theme.current.textSecondary.color)
    }

    // MARK: Saved

    @ViewBuilder
    private var savedList: some View {
        let theme = Theme.current
        let selected: UUID? = { if case .group(let id) = groupChoice { id } else { nil } }()
        // A group deleted elsewhere falls back to All saved.
        let shown = model.savedTrails(in: selected.flatMap { model.group(named: $0) == nil ? nil : $0 })
        if !model.groups.isEmpty || !model.saved.isEmpty {
            groupChips
        }
        if model.saved.isEmpty {
            HikingMessage(systemImage: "arrow.down.circle", title: "No saved trails", detail: "Open a trail and tap Save for offline, or import a GPX file. Its route and details stay on this iPhone, so it opens with no signal.")
        } else if shown.isEmpty, let group = model.group(named: selected) {
            HikingMessage(systemImage: "folder", title: "Nothing in \(group.name) yet", detail: "Press and hold a saved trail and choose Move to group, or import a GPX file.")
        } else {
            ForEach(shown) { trail in
                trailRow(trail)
                    .contextMenu {
                        Button("Move to group", systemImage: "folder") { moving = trail }
                        Button("Remove from saved", systemImage: "trash", role: .destructive) { Task { await model.forget(trail) } }
                    }
            }
            credit
        }
        Button {
            showsImporter = true
        } label: {
            Label("Import a GPX file", systemImage: "square.and.arrow.down")
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .frame(maxWidth: .infinity)
                .padding(Space.s3)
                .neumorphic(.raised, in: Capsule())
        }
        .buttonStyle(SoftPress())
    }

    /// "All saved" and each group, then New group and the group menu.
    private var groupChips: some View {
        let theme = Theme.current
        let selected: GroupChoice = {
            if case .group(let id) = groupChoice, model.group(named: id) != nil { return .group(id) }
            return .all
        }()
        let choices = [GroupChoice.all] + model.groups.map { GroupChoice.group($0.id) }
        return VStack(alignment: .leading, spacing: Space.s2) {
            FilterPills(choices, selection: $groupChoice) { choice in
                switch choice {
                case .all: "All saved · \(model.saved.count)"
                case .group(let id): "\(model.group(named: id)?.name ?? "Group") · \(model.savedTrails(in: id).count)"
                }
            }
            HStack(spacing: Space.s4) {
                Button { makingGroup = true } label: { Label("New group", systemImage: "plus") }
                if case .group(let id) = selected, let group = model.group(named: id) {
                    Menu {
                        Button("Rename \u{201C}\(group.name)\u{201D}", systemImage: "pencil") {
                            managing = group
                            renamedGroup = group.name
                            renamingGroup = true
                        }
                        Button("Delete group", systemImage: "trash", role: .destructive) {
                            managing = group
                            confirmsDeleteGroup = true
                        }
                    } label: {
                        Label("Manage group", systemImage: "ellipsis.circle")
                    }
                }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.accent.color)
        }
    }

    // MARK: Hikes

    @ViewBuilder
    private var hikeList: some View {
        let theme = Theme.current
        if model.hikes.isEmpty {
            HikingMessage(systemImage: "figure.hiking", title: "No hikes yet", detail: "Tap Record when you set off. Where you go stays on this iPhone.")
        } else {
            ForEach(model.hikes) { hike in
                Button {
                    openHike = hike
                } label: {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(hike.title)
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                        HStack(spacing: Space.s3) {
                            Text(model.units.distance(hike.metres)).foregroundStyle(theme.textPrimary.color)
                            Text(model.units.climb(hike.climb))
                            Text(HikeUnits.shortDuration(hike.seconds))
                            Spacer(minLength: 0)
                            Text(hike.startedAt.formatted(date: .abbreviated, time: .omitted))
                        }
                        .font(Typeface.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                    }
                    .itemCard()
                }
                .buttonStyle(SoftPress())
            }
        }
    }

    private var loadingCards: some View {
        VStack(spacing: Space.s3) {
            ForEach(0..<3, id: \.self) { _ in
                HikingCard { Text("Finding trails").font(Typeface.caption).foregroundStyle(Theme.current.textSecondary.color) }
                    .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel("Loading")
    }

    @ViewBuilder
    private var undoBar: some View {
        if let deleted = model.recentlyDeleted {
            let theme = Theme.current
            HStack {
                Text("Deleted \(deleted.title)")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer()
                Button("Undo") { model.undoDelete() }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
            }
            .itemCard()
            .padding(Space.s4)
        }
    }
}

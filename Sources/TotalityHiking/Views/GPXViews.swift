import SwiftUI
import TotalityCore
import TotalityUI
import UniformTypeIdentifiers

extension UTType {
    /// GPS Exchange files. Declared by the app as an imported type so the share sheet offers Totality.
    public static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

/// New trail from a GPX file: a preview of the route and its figures, a name, a group, and Save. Nothing is
/// saved until Save is pressed, and the file is read on this iPhone and never uploaded.
struct GPXImportView: View {
    let model: HikingModel
    let url: URL
    let onClose: () -> Void
    @State private var phase = Phase.reading
    @State private var name = ""
    @State private var groupID: UUID?

    enum Phase {
        case reading
        case ready(GPXImport.Result)
        case failed(GPXError?)
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                switch phase {
                case .reading:
                    VStack(spacing: Space.s3) {
                        ProgressView()
                        Text("Reading the file…").font(Typeface.callout).foregroundStyle(theme.textSecondary.color)
                        Text(url.lastPathComponent).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.s8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Reading the file")
                case .failed(let error):
                    VStack(spacing: Space.s3) {
                        HikingMessage(
                            systemImage: "exclamationmark.triangle", title: error?.title ?? "That file couldn't be read",
                            detail: error?.detail ?? "Totality couldn't open this file. Try another."
                        )
                        Button("Choose another file", action: onClose)
                            .font(Typeface.callout)
                            .foregroundStyle(theme.accent.color)
                    }
                    .padding(Space.s4)
                case .ready(let result):
                    preview(result).padding(Space.s4)
                }
            }
            .background(theme.bg.color)
            .navigationTitle("New trail from GPX")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
                ToolbarItem(placement: .confirmationAction) {
                    if case .ready(let result) = phase {
                        Button("Save") {
                            Task {
                                if await model.saveImported(result, name: name, groupID: groupID) { onClose() }
                            }
                        }
                        .disabled(GPXImport.cleanName(name) == nil)
                    }
                }
            }
        }
        .task {
            do {
                let result = try await model.prepareImport(from: url)
                name = result.trail.name
                phase = .ready(result)
            } catch let error as GPXError {
                phase = .failed(error)
            } catch {
                phase = .failed(nil)
            }
        }
    }

    @ViewBuilder
    private func preview(_ result: GPXImport.Result) -> some View {
        let theme = Theme.current
        let trail = result.trail
        let units = model.units
        VStack(alignment: .leading, spacing: Space.s4) {
            RouteMap(lines: trail.lines)
                .frame(height: Space.s8 * 3)
            TextField("Name", text: $name)
                .raisedField()
                .accessibilityLabel("Name")
            HStack(spacing: Space.s3) {
                StatBox(value: units.distance(trail.metres), label: "Distance")
                StatBox(value: result.hasElevation ? (trail.climb.map(units.climb) ?? "–") : "–", label: "Climb")
            }
            HStack(spacing: Space.s3) {
                StatBox(value: result.hasElevation ? (trail.highest.map(units.height) ?? "–") : "–", label: "Highest")
                StatBox(value: trail.difficulty.name, label: "Difficulty")
            }
            if !result.hasElevation {
                Label("No elevation in this file", systemImage: "mountain.2")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            HikingCard("Save in") {
                Picker("Group", selection: $groupID) {
                    Text("No group").tag(UUID?.none)
                    ForEach(model.groups) { group in Text(group.name).tag(UUID?.some(group.id)) }
                }
                .pickerStyle(.menu)
                .tint(theme.accent.color)
            }
            Label("Read on this iPhone and sealed with your key. The file isn't uploaded. Waypoints and photos in the file are left out.", systemImage: "lock.fill")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
    }
}

/// Export GPX from a hike: what goes in the file, the plain warning that it isn't encrypted, and Share.
struct GPXExportView: View {
    let model: HikingModel
    let hike: Hike
    let onClose: () -> Void
    @State private var options = GPXExport.Options()
    @State private var file: URL?
    @State private var error: GPXError?

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HikingCard {
                        Text(GPXExport.fileName(for: hike)).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        Text("\(GPXExport.pointCount(of: hike, options: options)) points")
                            .font(Typeface.caption).monospacedDigit().foregroundStyle(theme.textSecondary.color)
                    }
                    HikingCard {
                        Toggle(isOn: $options.includeTimeAndElevation) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Include time and elevation").font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                Text("Lets other apps work out pace and climb").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                            }
                        }
                        .tint(theme.accent.color)
                        Toggle(isOn: $options.trimEnds) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Leave off the first and last \(model.units.distance(HikingModel.privacyTrim))").font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                Text("Hides where you start, such as home").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                            }
                        }
                        .tint(theme.accent.color)
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A GPX file isn't encrypted").font(Typeface.callout).foregroundStyle(theme.textPrimary.color)
                            Text("Anyone you send it to, and any app you share it with, can see where you walked. Totality doesn't protect it once it leaves.")
                                .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger.color)
                    }
                    .itemCard()
                    if let error {
                        Text(error.detail).font(Typeface.caption).foregroundStyle(theme.danger.color)
                    }
                    if let file {
                        ShareLink(item: file) {
                            Label("Share GPX file", systemImage: "square.and.arrow.up")
                                .font(Typeface.headline)
                                .foregroundStyle(theme.accentOn.color)
                                .frame(maxWidth: .infinity)
                                .padding(Space.s4)
                                .background(Capsule().fill(theme.accent.color))
                        }
                        .buttonStyle(SoftPress())
                    }
                    Text("Opens the iOS share sheet: Files, Mail, AirDrop and more.")
                        .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Export GPX")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) } }
        }
        .task(id: options) { make() }
        .onDisappear { remove() }
    }

    private func make() {
        remove()
        do {
            file = try model.exportFile(for: hike, options: options)
            error = nil
        } catch let failure as GPXError {
            file = nil
            error = failure
        } catch {
            file = nil
            self.error = nil
        }
    }

    /// The temporary copy goes when the screen does.
    private func remove() {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
}

/// Pick one group for a saved trail, or none, or make a new one.
struct MoveToGroupView: View {
    let model: HikingModel
    let trail: Trail
    let onClose: () -> Void
    @State private var choice: UUID?
    @State private var newName = ""
    @State private var makingNew = false

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text(trail.name).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    row("No group", id: nil)
                    ForEach(model.groups) { row($0.name, id: $0.id) }
                    Button {
                        makingNew = true
                    } label: {
                        Label("New group…", systemImage: "plus")
                            .font(Typeface.callout)
                            .foregroundStyle(theme.accent.color)
                            .itemCard()
                    }
                    .buttonStyle(SoftPress())
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Move to group")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        Task {
                            await model.move(trail, to: choice)
                            onClose()
                        }
                    }
                }
            }
            .alert("New group", isPresented: $makingNew) {
                TextField("Name", text: $newName)
                Button("Create") {
                    Task {
                        if let group = await model.createGroup(named: newName) { choice = group.id }
                        newName = ""
                    }
                }
                Button("Cancel", role: .cancel) { newName = "" }
            } message: {
                Text("Up to \(HikeGroup.maxNameLength) characters. Sealed with your key like the trails.")
            }
        }
        .onAppear { choice = trail.groupID }
    }

    private func row(_ title: String, id: UUID?) -> some View {
        let theme = Theme.current
        return Button {
            choice = id
        } label: {
            HStack {
                Text(title).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                Spacer()
                if choice == id { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent.color) }
            }
            .itemCard()
        }
        .buttonStyle(SoftPress())
        .accessibilityAddTraits(choice == id ? .isSelected : [])
    }
}

/// Statistics: totals for a week, month, year or all time, a bar chart, and personal bests. It opens on
/// Month. Only hikes recorded in Totality count, never a trail brought in from a GPX file.
struct StatisticsView: View {
    let model: HikingModel
    let onClose: () -> Void
    let onOpenHike: (Hike) -> Void
    @State private var period = HikeStatistics.Period.month

    var body: some View {
        let theme = Theme.current
        let stats = model.statistics(for: period)
        let units = model.units
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    FilterPills(HikeStatistics.Period.allCases, selection: $period) { $0.rawValue }
                    if model.unreadableHikes > 0 {
                        Label("Couldn't open \(model.unreadableHikes) hike\(model.unreadableHikes == 1 ? "" : "s"). They're left out of these totals.", systemImage: "exclamationmark.triangle.fill")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                    }
                    if model.phase != .ready {
                        HikingMessage(systemImage: "lock.slash", title: "Statistics can't open", detail: "Your hikes couldn't be read on this iPhone.")
                    } else if stats.totals.hikes == 0 {
                        HikingMessage(
                            systemImage: "chart.bar", title: "No hikes \(period == .allTime ? "yet" : stats.periodName)",
                            detail: "Record a hike and your distance, climb and time show up here. Imported GPX trails don't count until you hike them."
                        )
                    } else {
                        let t = stats.totals
                        HStack(spacing: Space.s3) {
                            StatBox(value: "\(t.hikes)", label: "Hikes \(stats.periodName)")
                            StatBox(value: units.distance(t.metres), label: "Distance · avg \(units.distance(t.averageMetres))")
                        }
                        HStack(spacing: Space.s3) {
                            StatBox(value: units.height(t.climb), label: "Climb · avg \(units.height(t.averageClimb))")
                            StatBox(value: HikeUnits.shortDuration(t.seconds), label: "Time · avg \(HikeUnits.shortDuration(t.averageSeconds))")
                        }
                        chart(stats)
                    }
                    if model.phase == .ready, !model.hikes.isEmpty { bests(stats.bests) }
                    Label("Worked out on this iPhone from your sealed hikes. Nothing is sent anywhere.", systemImage: "lock.fill")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Statistics")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back", action: onClose) } }
        }
    }

    private func chart(_ stats: HikeStatistics) -> some View {
        let theme = Theme.current
        let top = max(1, stats.bars.map(\.hikes).max() ?? 1)
        return HikingCard("Hikes per \(stats.period == .week ? "day" : stats.period == .month ? "week" : "month")") {
            HStack(alignment: .bottom, spacing: Space.s1) {
                ForEach(stats.bars) { bar in
                    VStack(spacing: Space.s1) {
                        Text(bar.hikes > 0 ? "\(bar.hikes)" : " ").font(Typeface.micro).foregroundStyle(theme.textPrimary.color)
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(theme.accent.color.opacity(bar.hikes > 0 ? 1 : 0.2))
                            .frame(height: max(4, 90 * CGFloat(bar.hikes) / CGFloat(top)))
                        Text(bar.label).font(Typeface.micro).foregroundStyle(theme.textSecondary.color).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(bar.label): \(bar.hikes) hike\(bar.hikes == 1 ? "" : "s")")
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
    }

    private func bests(_ bests: HikeStatistics.Bests) -> some View {
        let units = model.units
        return VStack(alignment: .leading, spacing: Space.s3) {
            Text("PERSONAL BESTS").font(Typeface.micro).tracking(0.4).foregroundStyle(Theme.current.textSecondary.color)
            if let hike = bests.longest { best("Longest hike", hike, units.distance(hike.metres)) }
            if let hike = bests.mostClimb { best("Most climb", hike, units.height(hike.climb)) }
            if let hike = bests.highest, let height = hike.highest { best("Highest point", hike, units.height(height)) }
            if let hike = bests.longestTime { best("Longest time", hike, HikeUnits.shortDuration(hike.seconds)) }
            if let month = bests.busiestMonth {
                plain("Most hikes in a month", month.start.formatted(.dateTime.month(.wide).year()), "\(month.count)")
            }
            if bests.streakWeeks > 0 { plain("Longest streak", "Weeks in a row with a hike", "\(bests.streakWeeks) wk") }
        }
    }

    private func best(_ title: String, _ hike: Hike, _ value: String) -> some View {
        Button { onOpenHike(hike) } label: {
            line(title, "\(hike.title), \(hike.startedAt.formatted(.dateTime.day().month(.abbreviated)))", value)
        }
        .buttonStyle(SoftPress())
        .accessibilityHint("Opens that hike")
    }

    private func plain(_ title: String, _ detail: String, _ value: String) -> some View {
        line(title, detail, value)
    }

    private func line(_ title: String, _ detail: String, _ value: String) -> some View {
        let theme = Theme.current
        return HStack {
            Image(systemName: "trophy.fill").foregroundStyle(theme.accent.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                Text(detail).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: Space.s2)
            Text(value).font(Typeface.headline).monospacedDigit().foregroundStyle(theme.textPrimary.color)
        }
        .itemCard()
        .accessibilityElement(children: .combine)
    }
}

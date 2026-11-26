import Foundation

/// Groups, GPX import and export, and Statistics (owner, 2026-11-26). All of it is sealed on this iPhone,
/// and nothing here sends anything anywhere.
extension HikingModel {
    // MARK: Groups

    /// Makes a group. Returns nil for a name with nothing in it.
    @discardableResult
    public func createGroup(named name: String) async -> HikeGroup? {
        guard let clean = HikeGroup.clean(name) else { return nil }
        let group = HikeGroup(name: clean)
        let before = groups
        groups.append(group)
        guard await persistGroups() else {
            groups = before
            return nil
        }
        return group
    }

    public func renameGroup(_ group: HikeGroup, to name: String) async {
        guard let clean = HikeGroup.clean(name), let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = clean
        _ = await persistGroups()
    }

    /// Deletes the group and moves its trails to All saved. No trail is deleted.
    public func deleteGroup(_ group: HikeGroup) async {
        for index in saved.indices where saved[index].groupID == group.id {
            saved[index].groupID = nil
            try? await log?.save(saved[index])
        }
        groups.removeAll { $0.id == group.id }
        _ = await persistGroups()
    }

    /// Puts a saved trail in one group, or in none with nil.
    public func move(_ trail: Trail, to groupID: UUID?) async {
        guard let index = saved.firstIndex(where: { $0.id == trail.id }) else { return }
        if let groupID, !groups.contains(where: { $0.id == groupID }) { return }
        saved[index].groupID = groupID
        try? await log?.save(saved[index])
    }

    public func group(named id: UUID?) -> HikeGroup? {
        id.flatMap { id in groups.first { $0.id == id } }
    }

    /// The saved trails in one group, or every one for nil.
    public func savedTrails(in groupID: UUID?) -> [Trail] {
        guard let groupID else { return saved }
        return saved.filter { $0.groupID == groupID }
    }

    private func persistGroups() async -> Bool {
        guard let log else { return false }
        do {
            try await log.saveGroups(groups)
            return true
        } catch {
            notice = "Groups couldn't be saved on this iPhone"
            return false
        }
    }

    // MARK: GPX import

    /// Reads a GPX file into a trail, to preview before anything is saved. Reading happens off the main
    /// actor so a large file doesn't hold the screen.
    public func prepareImport(from url: URL, groupID: UUID? = nil) async throws -> GPXImport.Result {
        let fallback = url.deletingPathExtension().lastPathComponent
        let now = self.now()
        return try await Task.detached {
            let data = try GPXImport.read(contentsOf: url)
            return try GPXImport.trail(from: data, fallbackName: fallback, now: now, groupID: groupID)
        }.value
    }

    /// Seals the previewed trail on this iPhone under the name and group chosen. The file isn't uploaded.
    @discardableResult
    public func saveImported(_ result: GPXImport.Result, name: String, groupID: UUID?) async -> Bool {
        var trail = result.trail
        trail.name = GPXImport.cleanName(name) ?? trail.name
        trail.groupID = group(named: groupID)?.id
        trail.savedAt = now()
        do {
            try await log?.save(trail)
            saved.insert(trail, at: 0)
            let place = group(named: trail.groupID).map { "Saved to \($0.name)" } ?? "Saved \(trail.name)"
            notice = place
            return true
        } catch {
            notice = "\(trail.name) couldn't be saved on this iPhone"
            return false
        }
    }

    // MARK: GPX export

    /// Writes the hike's GPX to a temporary file to hand to the share sheet. The file is plain text, so the
    /// screen says so before this runs.
    public func exportFile(for hike: Hike, options: GPXExport.Options) throws -> URL {
        let data = try GPXExport.data(for: hike, options: options)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GPXExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(GPXExport.fileName(for: hike))
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Statistics

    public func statistics(for period: HikeStatistics.Period, now: Date = Date(), calendar: Calendar = .current) -> HikeStatistics {
        HikeStatistics(hikes: hikes, period: period, now: now, calendar: calendar)
    }
}

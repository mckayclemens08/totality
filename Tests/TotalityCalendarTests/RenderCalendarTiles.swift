#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityCore
@testable import TotalityUI
@testable import TotalityCalendar

/// Writes the Calendar's home tiles to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set,
/// with the square's Next up card (issue 127).
@MainActor
@Suite struct RenderCalendarTiles {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view.padding(Space.s4).background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func tile(_ model: CalendarModel, size: BigTileSize, height: CGFloat) -> some View {
        TileLabel(
            module: ModuleEntry.all.first { $0.id == .calendar }!, glance: model.glance, size: size,
            content: AnyView(CalendarHomeTile(model: model, size: size)), isEditing: false
        )
        .frame(width: 361, height: height)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private func model() throws -> CalendarModel {
        CalendarModel(
            vault: CalendarVault(store: MemoryBlobs(), rootKey: try ContentRootKey.generate()), devices: FakeDevices(), reminders: FakeReminders(),
            display: Dates.calendar(), defaults: UserDefaults(suiteName: "render-\(UUID())")!, now: { Dates.date(2026, 11, 16, 8, 30) }
        )
    }

    private func event(_ title: String, hour: Int, minute: Int = 0, hours: Int = 1, day: Int = 16, location: String = "") -> EventDraft {
        var draft = EventDraft(start: Dates.date(2026, 11, day, hour, minute), end: Dates.date(2026, 11, day, hour + hours, minute))
        draft.title = title
        draft.location = location
        return draft
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let full = try model()
        await full.load()
        _ = await full.create(event("Dentist", hour: 9, minute: 30, location: "Lakeview Dental, 210 Shore Rd"))
        _ = await full.create(event("Budget review", hour: 14))
        _ = await full.create(event("Climbing with Dana", hour: 18, hours: 2, day: 18, location: "Granite Arch Gym"))
        let noPlace = try model()
        await noPlace.load()
        _ = await noPlace.create(event("Call with Sam", hour: 11))
        let empty = try model()
        await empty.load()
        for (name, model) in [("full", full), ("no-place", noPlace), ("empty", empty)] {
            try write(VStack(spacing: Space.s4) {
                tile(model, size: .medium, height: 172)
                tile(model, size: .large, height: 266)
                tile(model, size: .square, height: 361)
            }, name: "calendar-tile-\(name).png", to: directory)
        }
    }
}
#endif

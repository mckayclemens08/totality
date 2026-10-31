import Foundation
import TotalityCalendar
import TotalityCore
import TotalityReader

/// Connects the modules that seal content to this device's key and storage. They share one key, so
/// they're set up together.
@MainActor
enum ContentSetup {
    /// Storage opens first, so the key step can see whether anything is already sealed under it.
    static func makeModels() throws -> (reader: ReaderModel, calendar: CalendarModel) {
        let base = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Totality", isDirectory: true)
        let readerStore = try FileBlobStore(directory: base.appendingPathComponent("Reader", isDirectory: true))
        let calendarStore = try FileBlobStore(directory: base.appendingPathComponent("Calendar", isDirectory: true))
        let rootKey = try ContentRootKey.loadOrCreate(in: KeychainKeyStore(), sealedIn: [readerStore, calendarStore])

        let readerVault = ReaderVault(store: readerStore, rootKey: rootKey)
        let registry = try ModuleRegistry(handlers: [ReaderModule(vault: readerVault), CalendarModule()])
        #if os(iOS)
        let startingMode = CalendarModel.Mode.agenda
        #else
        let startingMode = CalendarModel.Mode.month
        #endif
        return (
            ReaderModel(vault: readerVault, listen: ListenController(engine: SystemSpeechEngine())),
            CalendarModel(
                vault: CalendarVault(store: calendarStore, rootKey: rootKey),
                devices: SystemCalendarSource(), reminders: SystemReminders(),
                registry: registry, startingMode: startingMode
            )
        )
    }
}

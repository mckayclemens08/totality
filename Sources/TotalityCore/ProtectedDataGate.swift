import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Holds launch until the phone's protected data can be read. A push, a background refresh or a place
/// reminder can start Totality while the phone is locked, and then the Keychain answers nothing: the
/// saved sign-in and the content key are kept "when unlocked" only. Opening Home then would find nobody
/// signed in and no key, and the tiles would stay empty until a module was opened by hand (owner,
/// 2026-11-26, TestFlight build 11). Launch waits here instead, and goes on the moment the phone unlocks.
@MainActor
public final class ProtectedDataGate {
    private let isAvailable: @MainActor () -> Bool
    private let center: NotificationCenter
    private let name: Notification.Name

    public init(
        isAvailable: @escaping @MainActor () -> Bool, center: NotificationCenter = .default, becameAvailable name: Notification.Name
    ) {
        self.isAvailable = isAvailable
        self.center = center
        self.name = name
    }

    #if canImport(UIKit) && !os(watchOS)
    /// The phone's own: readable once it's unlocked.
    public static let system = ProtectedDataGate(
        isAvailable: { UIApplication.shared.isProtectedDataAvailable },
        becameAvailable: UIApplication.protectedDataDidBecomeAvailableNotification
    )
    #else
    /// A Mac's files and Keychain are readable whenever the app runs.
    public static let system = ProtectedDataGate(isAvailable: { true }, becameAvailable: Notification.Name("ProtectedDataGate.never"))
    #endif

    public var canRead: Bool { isAvailable() }

    /// Returns at once when the data can be read, otherwise when it next can. A cancelled wait returns too.
    public func waitUntilAvailable() async {
        // Listening starts before the check, so an unlock between the two can't be missed.
        let unlocks = center.notifications(named: name)
        guard !isAvailable() else { return }
        for await _ in unlocks {
            if isAvailable() || Task.isCancelled { return }
        }
    }
}

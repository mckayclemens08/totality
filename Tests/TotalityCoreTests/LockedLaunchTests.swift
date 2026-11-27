import Foundation
import Testing
@testable import TotalityCore

/// Home's tiles were empty until a module was opened (TestFlight build 11). A push or a background
/// refresh starts Totality while the phone is locked; the saved sign-in and the content key are kept
/// "when unlocked" only, so launch found nobody signed in and no key, and nothing tried again when the
/// phone was unlocked. Opening a module did, which is why that "fixed" it. These tests launch Home the way
/// `RootView` does, with its tiles, and no module ever opened.
@MainActor
@Suite struct LockedLaunchTests {
    /// The phone's Keychain: nothing comes out while it's locked.
    @MainActor final class Phone {
        var isUnlocked: Bool
        let center = NotificationCenter()
        static let unlocked = Notification.Name("test.unlocked")

        init(isUnlocked: Bool) { self.isUnlocked = isUnlocked }

        func read(_ item: String) -> String? { isUnlocked ? item : nil }

        func unlock() {
            isUnlocked = true
            center.post(name: Self.unlocked, object: nil)
        }

        var gate: ProtectedDataGate {
            ProtectedDataGate(isAvailable: { [unowned self] in isUnlocked }, center: center, becameAvailable: Self.unlocked)
        }
    }

    /// Home's tiles and what each says, as `RootView.glances` builds them. A tile with no model says
    /// nothing, which is the empty Home the owner saw.
    @MainActor final class Home {
        static let tiles: [ModuleID] = [.mail, .messages, .social, .reader, .tasks, .calendar, .web, .photos, .weather, .clock, .contacts, .hiking]
        let phone: Phone
        var signedIn: String?
        var glances: [ModuleID: ModuleGlance] = [:]

        init(phone: Phone) { self.phone = phone }

        /// `account.restore()`, then `warmUp()`: who's signed in, the content key, then each tile reads
        /// what it has saved. Each module's own empty state counts as content.
        func launch() async {
            signedIn = phone.read("mckay")
            guard signedIn != nil, phone.read("content key") != nil else { return }
            for tile in Self.tiles {
                await Task.yield()
                glances[tile] = tile == .tasks
                    ? ModuleGlance(lines: ["Nothing due today"], isQuiet: true)
                    : ModuleGlance(lines: ["\(tile.rawValue): saved content"])
            }
        }

        var unfilled: [ModuleID] { Self.tiles.filter { glances[$0]?.lines.isEmpty != false } }
    }

    @Test func aLockedLaunchWaitsForTheUnlockAndFillsEveryTile() async {
        let phone = Phone(isUnlocked: false)
        let home = Home(phone: phone)
        let launching = Task { @MainActor in
            await phone.gate.waitUntilAvailable()
            await home.launch()
        }
        // Woken by a push while locked: nothing is read, so nothing is decided as signed out.
        for _ in 0..<20 { await Task.yield() }
        #expect(home.signedIn == nil && home.glances.isEmpty)
        phone.unlock()
        await launching.value
        #expect(home.signedIn == "mckay")
        #expect(home.unfilled.isEmpty, "Every tile has content or its empty state without opening a module")
    }

    /// What build 11 did: launch went ahead locked and Home stayed empty.
    @Test func launchingWhileLockedWithoutTheGateLeavesHomeEmpty() async {
        let phone = Phone(isUnlocked: false)
        let home = Home(phone: phone)
        await home.launch()
        phone.unlock()
        #expect(home.unfilled == Home.tiles)
    }

    @Test func anUnlockedLaunchDoesNotWait() async {
        let phone = Phone(isUnlocked: true)
        let home = Home(phone: phone)
        await phone.gate.waitUntilAvailable()
        await home.launch()
        #expect(home.unfilled.isEmpty)
    }

    @Test func anotherNoticeWhileStillLockedKeepsWaiting() async {
        let phone = Phone(isUnlocked: false)
        var passed = false
        let waiting = Task { @MainActor in
            await phone.gate.waitUntilAvailable()
            passed = true
        }
        for _ in 0..<10 { await Task.yield() }
        phone.center.post(name: Phone.unlocked, object: nil)
        for _ in 0..<10 { await Task.yield() }
        #expect(!passed)
        phone.unlock()
        await waiting.value
        #expect(passed)
    }
}

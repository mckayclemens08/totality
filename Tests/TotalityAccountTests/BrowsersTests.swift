import Foundation
import Testing
@testable import TotalityAccount

private actor FakeBrowsers: BrowsersService {
    var list: [WebBrowser]
    var deleted: [String] = []
    var failRemove = false
    var failMatrix = false
    init(_ list: [WebBrowser]) { self.list = list }
    func browsers() async throws -> [WebBrowser] { list }
    func removeBrowser(_ id: UUID) async throws -> String? {
        if failRemove { throw AccountError.offline }
        let device = list.first { $0.id == id }?.matrixDevice
        list.removeAll { $0.id == id }
        return device
    }
    func deleteWebMatrixDevice(_ device: String) async throws {
        if failMatrix { throw AccountError.failed }
        deleted.append(device)
    }
    func set(failRemove: Bool = false, failMatrix: Bool = false) { self.failRemove = failRemove; self.failMatrix = failMatrix }
}

@MainActor
@Suite struct BrowsersTests {
    let mac = WebBrowser(id: UUID(), label: "Safari on a Mac", lastSeen: .now, matrixDevice: "ABCDEFGHIJ")
    let windows = WebBrowser(id: UUID(), label: "Chrome on Windows", lastSeen: .now.addingTimeInterval(-3 * 86_400), matrixDevice: nil)

    @Test func removingEndsTheSignInAndDeletesItsMatrixDevice() async {
        let service = FakeBrowsers([mac, windows])
        let model = BrowsersModel(service: service)
        await model.load()
        await model.remove(mac)
        #expect(model.phase == .loaded([windows]))
        #expect(await service.deleted == ["ABCDEFGHIJ"])
        #expect(model.message == nil)
    }

    @Test func aBrowserWithoutMessagesNeedsNoMatrixStep() async {
        let service = FakeBrowsers([windows])
        let model = BrowsersModel(service: service)
        await model.load()
        await model.remove(windows)
        #expect(model.phase == .loaded([]))
        #expect(await service.deleted.isEmpty)
    }

    @Test func aFailedRemoveChangesNothingAndSaysSo() async {
        let service = FakeBrowsers([mac])
        await service.set(failRemove: true)
        let model = BrowsersModel(service: service)
        await model.load()
        await model.remove(mac)
        #expect(model.phase == .loaded([mac]))
        #expect(model.message?.contains("Nothing changed") == true)
    }

    @Test func aMatrixFailureStillSignsTheBrowserOut() async {
        let service = FakeBrowsers([mac])
        await service.set(failMatrix: true)
        let model = BrowsersModel(service: service)
        await model.load()
        await model.remove(mac)
        #expect(model.phase == .loaded([]))
        #expect(model.message?.contains("signed out") == true)
    }

    @Test func lastActiveReadsPlainly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(BrowsersModel.lastActive(now.addingTimeInterval(-60), now: now) == "Active now")
        #expect(BrowsersModel.lastActive(now.addingTimeInterval(-3 * 86_400), now: now).hasPrefix("Last active "))
    }

    @Test func postgresTimestampsParse() {
        #expect(SupabaseAccountService.timestamp("2026-11-19T00:20:00.123456+00:00") == Date(timeIntervalSince1970: 1_795_047_600))
        #expect(SupabaseAccountService.timestamp("2026-11-19T00:20:00+00:00") == Date(timeIntervalSince1970: 1_795_047_600))
        #expect(SupabaseAccountService.timestamp("nonsense") == nil)
    }

    @Test func onlySafeMatrixDeviceIDsAreAccepted() {
        #expect(MatrixSession.isDeviceID("ABCDEFGHIJ"))
        #expect(!MatrixSession.isDeviceID("../logout"))
        #expect(!MatrixSession.isDeviceID(""))
        #expect(!MatrixSession.isDeviceID(String(repeating: "A", count: 65)))
    }
}

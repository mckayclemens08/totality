import Foundation
import Observation
import Supabase

/// A browser paired with the website, as the account server lists it (supabase/migrations/20261119000001_web_browsers.sql).
public struct WebBrowser: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let lastSeen: Date
    /// Its Matrix device, if Messages is on there.
    public let matrixDevice: String?

    public init(id: UUID, label: String, lastSeen: Date, matrixDevice: String?) {
        self.id = id
        self.label = label
        self.lastSeen = lastSeen
        self.matrixDevice = matrixDevice
    }
}

public protocol BrowsersService: Sendable {
    func browsers() async throws -> [WebBrowser]
    /// Ends that browser's sign-in on the account server. Returns its Matrix device, if it had one.
    func removeBrowser(_ id: UUID) async throws -> String?
    /// Deletes a website Matrix device, and only one named "Totality web".
    func deleteWebMatrixDevice(_ device: String) async throws
}

/// Devices › Browsers (owner, 2026-11-19: "Whole sign-in"). Remove ends the browser's website sign-in and deletes
/// its Matrix device; the browser wipes itself within five minutes, or the next time it opens.
@MainActor
@Observable
public final class BrowsersModel {
    public enum Phase: Equatable {
        case loading
        case loaded([WebBrowser])
        case failed(String)
    }

    public private(set) var phase = Phase.loading
    public private(set) var removing: UUID?
    public private(set) var message: String?
    private let service: any BrowsersService

    public init(service: any BrowsersService) {
        self.service = service
    }

    public func load() async {
        do {
            phase = .loaded(try await service.browsers())
        } catch {
            if case .loaded = phase { return } // keep what's showing
            phase = .failed("Couldn't load your browsers. Check your connection and pull to try again.")
        }
    }

    public func remove(_ browser: WebBrowser) async {
        guard removing == nil else { return }
        removing = browser.id
        message = nil
        defer { removing = nil }
        let device: String?
        do {
            device = try await service.removeBrowser(browser.id)
        } catch {
            message = "Couldn't remove \(browser.label). Nothing changed. Try again."
            return
        }
        if case .loaded(let list) = phase { phase = .loaded(list.filter { $0.id != browser.id }) }
        if let device {
            do { try await service.deleteWebMatrixDevice(device) } catch {
                // Signed out of the website already; the browser logs its own Matrix device out when it clears itself.
                message = "\(browser.label) is signed out. Its Messages will end when it next opens."
            }
        }
        await load()
    }

    /// "Active now" within five minutes (the website checks in that often), otherwise how long ago.
    public static func lastActive(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 6 * 60 { return "Active now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last active \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

extension SupabaseAccountService: BrowsersService {
    private struct Row: Decodable {
        let id: UUID
        let device_label: String
        let last_seen_at: String
        let matrix_device: String?
    }

    public func browsers() async throws -> [WebBrowser] {
        try await mapErrors {
            let rows: [Row] = try await client.rpc("my_browsers").execute().value
            return rows.map { WebBrowser(id: $0.id, label: $0.device_label, lastSeen: Self.timestamp($0.last_seen_at) ?? .distantPast, matrixDevice: $0.matrix_device) }
        }
    }

    public func removeBrowser(_ id: UUID) async throws -> String? {
        try await mapErrors {
            let device: String? = try await client.rpc("remove_browser", params: ["p_id": id.uuidString.lowercased()]).execute().value
            return device
        }
    }

    public func deleteWebMatrixDevice(_ device: String) async throws {
        guard MatrixSession.isDeviceID(device) else { throw AccountError.failed }
        // A short-lived session of its own, like key backup's; the Messages device on this phone is never used.
        let session = try await MatrixSession.signIn(with: try await matrixPass())
        do {
            try await session.deleteWebDevice(device, pass: { try await matrixPass() })
            await session.signOut()
        } catch {
            await session.signOut()
            throw error
        }
    }

    /// Postgres timestamps, with or without fractional seconds.
    static func timestamp(_ text: String) -> Date? {
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: plain) ?? formatter.date(from: plain.replacingOccurrences(of: " ", with: "T"))
    }
}

extension MatrixSession {
    static let webDeviceName = "Totality web"

    static func isDeviceID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil
    }

    private struct Device: Decodable { let display_name: String? }
    private struct Challenge: Decodable { let session: String? }

    /// Deletes one of the account's website devices. Tuwunel asks for proof it's you, and a fresh sign-in pass is
    /// that proof (its org.matrix.login.jwt flow), so no password is involved. Refuses any device not named
    /// "Totality web", so a tampered browser record can't point this at the phone.
    func deleteWebDevice(_ id: String, pass: () async throws -> String) async throws {
        guard Self.isDeviceID(id) else { throw AccountError.failed }
        let path = "_matrix/client/v3/devices/\(id)"
        let (data, response) = try await Self.urlSession.data(for: authorized(path: path, method: "GET"))
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: break
        case 404: return // already gone
        default: throw AccountError.failed
        }
        guard (try? JSONDecoder().decode(Device.self, from: data))?.display_name == Self.webDeviceName else { throw AccountError.failed }

        var ask = authorized(path: path, method: "DELETE")
        ask.httpBody = Data("{}".utf8)
        let (challengeData, challengeResponse) = try await Self.urlSession.data(for: ask)
        let status = (challengeResponse as? HTTPURLResponse)?.statusCode
        if status == 200 || status == 404 { return }
        guard status == 401, let uia = try? JSONDecoder().decode(Challenge.self, from: challengeData).session else { throw AccountError.failed }

        var confirm = authorized(path: path, method: "DELETE")
        confirm.httpBody = try JSONSerialization.data(withJSONObject: [
            "auth": ["type": "org.matrix.login.jwt", "token": try await pass(), "session": uia],
        ])
        let (_, done) = try await Self.urlSession.data(for: confirm)
        guard [200, 404].contains((done as? HTTPURLResponse)?.statusCode) else { throw AccountError.failed }
    }
}

import Foundation

public enum PushError: Error, Equatable, Sendable {
    case signedOut, refused, offline, unavailable
}

/// Talks to Totality's push service (`server/push/`, issue 164). A phone registers its Apple push token
/// there, and the server wakes it with an empty silent push. For instant Gmail sync the phone also links
/// each Gmail address with Google's ID token for it, and the server keeps only a keyed hash.
public struct PushClient: Sendable {
    public static let server = URL(string: "https://usetotality.com")!

    private let server: URL
    private let session: URLSession
    private let token: @Sendable () async throws -> String

    public init(server: URL = PushClient.server, session: URLSession? = nil, token: @escaping @Sendable () async throws -> String) {
        self.server = server
        self.token = token
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    /// `sandbox` names Apple's development push service, which builds signed for development use.
    public func register(device: Data, sandbox: Bool) async throws {
        try await post("push/device", ["token": Self.hex(device), "sandbox": sandbox])
    }

    public func remove(device: Data) async throws {
        try await post("push/device/remove", ["token": Self.hex(device)])
    }

    /// Asks the server to wake these people's phones, after a like, comment or follow (issue 232). It says
    /// nothing about what happened: their phones ask Social themselves.
    public func poke(_ usernames: [String]) async throws {
        let names = Array(Set(usernames)).sorted()
        for start in stride(from: 0, to: names.count, by: Self.pokeNames) {
            try await post("push/poke", ["to": Array(names[start..<min(start + Self.pokeNames, names.count)])])
        }
    }

    /// Names one poke may carry, as `server/push` allows.
    public static let pokeNames = 20

    /// Links the Gmail address Google's ID token names to this account's phones.
    public func linkGmail(idToken: String) async throws {
        try await post("push/gmail/link", ["idToken": idToken])
    }

    /// Unlinks an address from this account, for a Gmail account being removed or the setting turned off.
    public func unlinkGmail(address: String) async throws {
        try await post("push/gmail/unlink", ["address": address])
    }

    private func post(_ path: String, _ fields: [String: Any]) async throws {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw PushError.offline
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return
        case 401: throw PushError.signedOut
        case 400, 403: throw PushError.refused
        default: throw PushError.unavailable
        }
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this build gets its pushes from Apple's development service. It's whatever the build's
    /// provisioning profile says, so a TestFlight build and a build run from Xcode each ask the right one.
    /// A build with no profile is a TestFlight or App Store build on a phone, which uses the production
    /// service; only the simulator counts as development without one.
    public static var isSandbox: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            #if targetEnvironment(simulator)
            return true
            #else
            return false
            #endif
        }
        return sandbox(inProfile: data)
    }

    /// The profile is a signed plist. Its text sits in the clear inside the signature's wrapper.
    public static func sandbox(inProfile data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return true }
        let rest = text[key.upperBound...].prefix(200)
        return !rest.contains("<string>production</string>")
    }
}

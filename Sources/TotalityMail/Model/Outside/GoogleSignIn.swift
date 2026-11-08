import Foundation
import TotalityCore

/// One HTTPS request and its answer, so tests can stand in for Google. The same thing Core's Google
/// sign-in uses, so Gmail's requests go through the same cookie-free, cache-free connection.
public typealias OutsideHTTP = GoogleHTTP

/// The page Google's sign-in opens on, and why Mail opened it. The verifier and state stay on the
/// device, in memory, and never print.
public struct GoogleSignInRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let authorization: GoogleAuthorization
    let purpose: GoogleSignInPurpose

    public var url: URL { authorization.url }
    /// The scheme Google sends the person back on, for the web sign-in sheet to catch.
    public var callbackScheme: String { authorization.callbackScheme }
    var scopes: [String] { authorization.scopes }
    var state: String { authorization.state }
    var verifier: String { authorization.verifier }

    public var description: String { "Google sign-in" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Gmail through a Google sign-in. Signing in, tokens and taking access back are Core's
/// `GoogleSignIn`, which every module shares. What's here is Gmail's own: its scopes, and its API.
public struct GoogleOAuth: Sendable {
    /// Read only. What accounts added before 2026-11-07 were given. They're asked once to allow changes.
    public static let readScope = "https://www.googleapis.com/auth/gmail.readonly"
    /// Read and change, so read state, stars, archiving and Trash reach Gmail. Asked for when the
    /// account is added. Google lets this one send too, which the owner agreed (CLAUDE.md rule 8), but
    /// Totality sends only after `sendScope` is separately allowed for the account.
    public static let changeScope = "https://www.googleapis.com/auth/gmail.modify"
    /// Send. Asked for separately, only when the Send switch is turned on.
    public static let sendScope = "https://www.googleapis.com/auth/gmail.send"

    static let tokenURL = GoogleSignIn.tokenURL
    static let revokeURL = GoogleSignIn.revokeURL
    static let profileURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!

    let signIn: GoogleSignIn
    /// How long to wait the first time Gmail says it's being asked too fast. Doubles each time after.
    let pause: Duration

    public var clientID: String { signIn.clientID }

    /// Nil when this build has no Google client, or it isn't the shape Google gives an iOS app.
    public init?(clientID: String?, http: any OutsideHTTP = EphemeralHTTP(), pause: Duration = .seconds(1)) {
        guard let signIn = GoogleSignIn(clientID: clientID, http: http) else { return nil }
        self.signIn = signIn
        self.pause = pause
    }

    var callbackScheme: String { signIn.callbackScheme }

    /// To add an account, choosing which Google account. To allow changes, or sending as well, for an
    /// account already added.
    func request(_ purpose: GoogleSignInPurpose = .add) -> GoogleSignInRequest {
        let scopes = purpose.sends ? [Self.changeScope, Self.sendScope] : [Self.changeScope]
        return GoogleSignInRequest(authorization: signIn.authorization(scopes: scopes, account: purpose.address), purpose: purpose)
    }

    /// Checks what Google sent back and swaps it for tokens. It has to be the answer to this request,
    /// and every scope asked for has to have been allowed: Google lets the person untick each one.
    func finish(_ request: GoogleSignInRequest, callback: URL) async throws -> GoogleTokens {
        let tokens = try await Self.mapped { try await signIn.finish(request.authorization, callback: callback) }
        guard request.scopes.allSatisfy(tokens.granted.contains) else {
            // Taking a token back at Google takes back everything this app was given, so it's only done
            // when nothing was added yet. Turning sending on for an account that reads keeps its reading.
            if request.purpose == .add { await revoke(tokens.refreshToken) }
            throw OutsideMailProblem.notAllowed
        }
        return GoogleTokens(refreshToken: tokens.refreshToken, accessToken: tokens.accessToken)
    }

    /// A fresh access token, which lasts about an hour and is never kept.
    func accessToken(for grant: GoogleGrant) async throws -> String {
        try await Self.mapped { try await signIn.accessToken(refreshToken: grant.refreshToken) }
    }

    /// The Gmail address the token belongs to, which is also proof it can read.
    func address(accessToken: String) async throws -> String {
        var request = URLRequest(url: Self.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await sendRequest(request)
        switch response.statusCode {
        case 200: break
        case 401: throw OutsideMailProblem.expired
        case 403: throw OutsideMailProblem.notAllowed
        default: throw OutsideMailProblem.unreachable
        }
        struct Profile: Decodable { let emailAddress: String }
        guard let address = try? JSONDecoder().decode(Profile.self, from: data).emailAddress,
              OutsideSignIn.isAddress(address) else { throw OutsideMailProblem.unexpected }
        return address
    }

    /// Takes Totality's access away at Google, for every scope. Best effort: the account goes from
    /// Totality whether or not Google is reached.
    func revoke(_ refreshToken: String) async {
        await signIn.revoke(refreshToken)
    }

    func sendRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await signIn.send(request)
        } catch {
            throw OutsideMailProblem.from(error)
        }
    }

    static func form(_ fields: [String: String]) -> Data { GoogleSignIn.form(fields) }
    static func base64URL(_ data: Data) -> String { GoogleSignIn.base64URL(data) }

    /// Core's sign-in errors, said the way Mail says the rest.
    private static func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as GoogleSignInError {
            switch error {
            case .cancelled: throw OutsideAccountError.cancelled
            case .refused(let said): throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(said))
            case .expired: throw OutsideMailProblem.expired
            case .unreachable: throw OutsideMailProblem.unreachable
            case .unexpected: throw OutsideMailProblem.unexpected
            }
        } catch {
            throw OutsideMailProblem.from(error)
        }
    }
}

/// Why Google's page is being opened.
enum GoogleSignInPurpose: Equatable, Sendable {
    case add
    /// An account added with read only, asked to allow changes.
    case change(String)
    /// Sending turned on, with changes as well.
    case send(String)

    var address: String? {
        switch self {
        case .add: nil
        case .change(let address), .send(let address): address
        }
    }

    var sends: Bool { if case .send = self { true } else { false } }
}

/// What a finished Google sign-in hands back. The access token is used straight away and dropped.
struct GoogleTokens: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let refreshToken: String
    let accessToken: String

    var description: String { "Google tokens" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

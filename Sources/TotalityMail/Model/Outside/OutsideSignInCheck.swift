import Foundation

/// Checks an outside account before anything about it is saved: that it signs in for reading, and, when
/// its Send switch is turned on, for sending. Each connection signs straight out again.
public struct OutsideSignInCheck: Sendable {
    let maker: any OutsideWireMaker

    public init(maker: any OutsideWireMaker = StreamTaskWireMaker()) {
        self.maker = maker
    }

    public func checkReading(_ signIn: OutsideSignIn) async -> OutsideMailProblem? {
        do {
            try await IMAPConnection.signIn(signIn, with: maker).signOut()
            return nil
        } catch {
            return OutsideMailProblem.from(error)
        }
    }

    public func checkSending(_ signIn: OutsideSignIn) async -> OutsideMailProblem? {
        do {
            try await SMTPConnection.signIn(signIn, with: maker).signOut()
            return nil
        } catch {
            return OutsideMailProblem.from(error)
        }
    }
}

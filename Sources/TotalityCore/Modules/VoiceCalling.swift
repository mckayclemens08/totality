import SwiftUI

private enum StartVoiceCallKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

public extension EnvironmentValues {
    /// The app supplies a call action to direct chat screens when voice calling is available.
    var startVoiceCall: (@MainActor (String) -> Void)? {
        get { self[StartVoiceCallKey.self] }
        set { self[StartVoiceCallKey.self] = newValue }
    }
}

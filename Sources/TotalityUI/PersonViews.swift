import ImageIO
import SwiftUI
import TotalityCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Someone's face: their profile photo on a raised disc, or their initials when there's no photo.
/// The photo is always one `SafeAvatar` rebuilt on this device.
public struct PersonFace: View {
    let photo: Data?
    let name: String
    let diameter: CGFloat

    public init(photo: Data?, name: String, diameter: CGFloat = Space.s7) {
        self.photo = photo
        self.name = name
        self.diameter = diameter
    }

    public var body: some View {
        let theme = Theme.current
        Group {
            if let image = Self.image(from: photo) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Text(PublicProfile.initials(of: name))
                    .font(diameter > Space.s7 ? Typeface.title : Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .neumorphic(.raised, in: Circle())
        .accessibilityHidden(true)
    }

    static func image(from data: Data?) -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Someone else's public profile: photo, name, handle and bio, with what can be done from it. Account
/// and Messages both show it, so neither has to import the other.
public struct PersonProfileView: View {
    public enum Phase: Equatable {
        case loading
        case found(PublicProfile)
        /// There's no profile this account can see.
        case missing
        /// It couldn't be fetched, and nothing was saved from before.
        case failed(String)
    }

    let username: String
    let phase: Phase
    let onMessage: (() -> Void)?
    let onRetry: (() -> Void)?
    @State private var copied = false

    public init(username: String, phase: Phase, onMessage: (() -> Void)? = nil, onRetry: (() -> Void)? = nil) {
        self.username = username
        self.phase = phase
        self.onMessage = onMessage
        self.onRetry = onRetry
    }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s4) {
            switch phase {
            case .loading:
                PersonFace(photo: nil, name: username, diameter: Space.s8 * 1.5)
                ProgressView()
            case .found(let profile):
                PersonFace(photo: profile.photo, name: profile.name, diameter: Space.s8 * 1.5)
                VStack(spacing: Space.s1) {
                    Text(profile.name)
                        .font(Typeface.title)
                        .foregroundStyle(theme.textPrimary.color)
                    if profile.name != profile.username {
                        Text("@\(profile.username)")
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                }
            case .missing:
                PersonFace(photo: nil, name: username, diameter: Space.s8 * 1.5)
                Text("@\(username) hasn't set up a profile yet.")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
            case .failed(let reason):
                PersonFace(photo: nil, name: username, diameter: Space.s8 * 1.5)
                Text(reason)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                if let onRetry {
                    Button("Try again", action: onRetry)
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                        .buttonStyle(.plain)
                }
            }
            HStack(spacing: Space.s3) {
                if let onMessage {
                    ProfileAction("Message", systemImage: "bubble.left.fill", action: onMessage)
                }
                ProfileAction(copied ? "Copied" : "Copy handle", systemImage: copied ? "checkmark" : "at") {
                    Pasteboard.copyHandle("@\(username)")
                    copied = true
                }
            }
            .padding(.top, Space.s2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(Space.s5)
    }
}

private struct ProfileAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, Space.s4)
                .frame(minHeight: Space.s7)
                .neumorphic(.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A handle is public, so copying it can go everywhere the clipboard does.
enum Pasteboard {
    static func copyHandle(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

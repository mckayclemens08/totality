import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import TotalityCore
import TotalityUI

/// Your card, a QR code, and your link. Opening it is the choice to share, so the web page goes up then,
/// with a way to take it down again. Only what's already public is on it.
struct ShareProfileView: View {
    let model: AccountModel
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(spacing: Space.s5) {
                if let profile = model.profile {
                    ProfileHeader(profile: profile)
                    content(for: profile)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(Space.s5)
        }
        .background(theme.bg.color)
        .navigationTitle("Share profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if model.webPage != true { await model.setWebPage(published: true) }
        }
    }

    @ViewBuilder private func content(for profile: Profile) -> some View {
        let link = ProfileLink.web(for: profile.username)
        if model.webPage == true {
            ProfileQRCode(url: link)
            AddressLine("Your profile link", address: link.absoluteString)
                .padding(Space.s4)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
            AccountDetail(text: "Anyone with this link or code can see your name, photo, and bio. Nothing else is on the page.")
            Button("Stop sharing on the web") {
                Task { if await model.setWebPage(published: false) { onDone() } }
            }
            .font(Typeface.callout)
            .foregroundStyle(Theme.current.danger.color)
            .disabled(model.isChangingWebPage)
        } else if let problem = model.webPageProblem, !model.isChangingWebPage {
            AccountDetail(text: "Your page didn't go up. \(problem)")
            Button("Try again") { Task { await model.setWebPage(published: true) } }
                .font(Typeface.callout)
        } else {
            VStack(spacing: Space.s3) {
                ProgressView()
                AccountDetail(text: "Putting your page on the web.")
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// A QR code for a link, drawn in the text colour on a white card so any camera can read it.
struct ProfileQRCode: View {
    private static let side = Space.s8 * 5

    let url: URL

    var body: some View {
        let theme = Theme.current
        Group {
            if let image = Self.mask(for: url) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .renderingMode(.template)
                    .foregroundStyle(theme.textPrimary.color)
            } else {
                Image(systemName: "qrcode").font(Typeface.display)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .padding(Space.s4)
        .background(theme.accentOn.color, in: RoundedRectangle(cornerRadius: Radius.md))
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityLabel("QR code for your profile link")
    }

    /// The code's dark squares as opaque pixels and the rest clear, so it can take any colour.
    nonisolated static func mask(for url: URL) -> CGImage? {
        let code = CIFilter.qrCodeGenerator()
        code.message = Data(url.absoluteString.utf8)
        code.correctionLevel = "M"
        let invert = CIFilter.colorInvert()
        invert.inputImage = code.outputImage
        let alpha = CIFilter.maskToAlpha()
        alpha.inputImage = invert.outputImage
        guard let output = alpha.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// Someone else's profile, opened from their link. It shows only what their profile makes public.
public struct OtherProfileView: View {
    private enum State: Equatable {
        case loading
        case found(Profile)
        case missing
        case failed
    }

    private let model: AccountModel
    private let username: String
    private let onDone: () -> Void
    @SwiftUI.State private var state = State.loading

    public init(model: AccountModel, username: String, onDone: @escaping () -> Void) {
        self.model = model
        self.username = username
        self.onDone = onDone
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.s5) {
                    switch state {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity)
                    case .found(let profile):
                        ProfileHeader(profile: profile)
                    case .missing:
                        AccountDetail(text: "There's no profile for @\(username) that you can see.")
                    case .failed:
                        AccountDetail(text: isSignedIn ? "That profile didn't load." : "Sign in to see profiles on Totality.")
                        if isSignedIn {
                            Button("Try again") { Task { await load() } }
                                .font(Typeface.callout)
                        }
                    }
                }
                .padding(Space.s5)
            }
            .background(theme.bg.color)
            .navigationTitle("@\(username)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .tint(theme.accent.color)
        .task { await load() }
    }

    private var isSignedIn: Bool {
        if case .signedIn = model.phase { true } else { false }
    }

    private func load() async {
        guard isSignedIn else {
            state = .failed
            return
        }
        state = .loading
        do {
            state = try await model.lookUp(username).map(State.found) ?? .missing
        } catch {
            state = .failed
        }
    }
}

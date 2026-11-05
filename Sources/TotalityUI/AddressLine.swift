import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// An address people are meant to hand out, with Copy and Share right beside it. Mail and the account
/// screen both show the person's own address this way.
public struct AddressLine: View {
    /// How long "Copied" stays before the button reads Copy again.
    private static let copiedTime = Duration.seconds(2)

    private let label: String
    private let address: String
    @State private var copied = false

    public init(_ label: String, address: String) {
        self.label = label
        self.address = address
    }

    public var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(label)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            Text(address)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
            HStack(spacing: Space.s4) {
                Button(copied ? "Copied" : "Copy") { copy() }
                ShareLink("Share", item: address)
            }
            .font(Typeface.caption)
            .foregroundStyle(theme.accent.color)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: Self.copiedTime)
            copied = false
        }
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = address
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        #endif
        copied = true
    }
}

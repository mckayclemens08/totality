import Foundation
import SwiftUI
import TotalityUI

/// One message in a conversation, folded to a line or open in full.
struct MailMessageView: View {
    let message: MailMessage
    let model: MailModel
    let isOpen: Bool
    let onToggle: () -> Void
    let onOpenLink: (URL) -> Void

    @State private var showingDetails = false

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            header
            if isOpen {
                if showingDetails { details }
                notes
                MailBodyView(message: message, model: model, onOpenLink: onOpenLink)
                ForEach(message.attachments) { attachment in
                    MailAttachmentView(attachment: attachment, model: model)
                }
                if let route = message.route, message.marks.folder != .drafts {
                    Label(MailWording.route(route), systemImage: route == .betweenAccounts ? "lock" : "info.circle")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.top, Space.s1)
                }
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(isOpen ? .raised : .subtle, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private var header: some View {
        let theme = Theme.current
        return HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(message.from.displayName)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                if isOpen {
                    Button {
                        withAnimation(Motion.quick) { showingDetails.toggle() }
                    } label: {
                        Text("To \(ListFormatter.localizedString(byJoining: message.to.map(\.displayName)))")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the full addresses")
                } else {
                    Text(message.preview)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(MailDate.short(message.date, now: model.today))
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        .tappable(onToggle)
    }

    /// The address itself, because a display name can say anything.
    private var details: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            detail("From", [message.from])
            detail("To", message.to)
            if !message.cc.isEmpty { detail("Cc", message.cc) }
            Text(message.date.formatted(date: .complete, time: .shortened))
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        .textSelection(.enabled)
    }

    private func detail(_ label: String, _ people: [MailAddress]) -> some View {
        Text("\(label): \(people.map(\.address).joined(separator: ", "))")
            .font(Typeface.caption)
            .foregroundStyle(Theme.current.textSecondary.color)
    }

    @ViewBuilder private var notes: some View {
        if message.proof == .unproved {
            MailStrip(systemImage: "exclamationmark.shield", text: MailWording.unproved(message.from), isWarning: true)
        }
        switch message.delivery {
        case .fine:
            EmptyView()
        case .notSent(let reason):
            MailStrip(systemImage: "exclamationmark.triangle", text: "Not sent. \(reason)", isWarning: true)
        case .bounced(let reason):
            MailStrip(systemImage: "exclamationmark.triangle", text: "Couldn't be delivered. \(reason)", isWarning: true)
        }
    }
}

/// A short inset note inside a message.
struct MailStrip: View {
    let systemImage: String
    let text: String
    var isWarning = false

    var body: some View {
        let theme = Theme.current
        Label(text, systemImage: systemImage)
            .font(Typeface.caption)
            .foregroundStyle(isWarning ? theme.danger.color : theme.textSecondary.color)
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}

/// A message's words. Plain mail is ordinary text. HTML goes in the sealed-off web view, and only once
/// its rules are ready, so a page can never appear before what contains it.
struct MailBodyView: View {
    let message: MailMessage
    let model: MailModel
    let onOpenLink: (URL) -> Void

    @State private var loadedImages = false
    @State private var rules: MailPageRules?
    @State private var didPrepare = false
    @State private var height = Space.s8

    private var allowsImages: Bool {
        loadedImages || model.mailbox.loadsImages(for: message)
    }

    var body: some View {
        switch message.body {
        case .plain(let text):
            plain(text)
        case .html(let html, let text):
            page(html, fallback: text)
        case .unreadable:
            EmptyView()
        }
    }

    private func plain(_ text: String) -> some View {
        Text(MailText.linked(text))
            .font(Typeface.body)
            .foregroundStyle(Theme.current.textPrimary.color)
            .tint(Theme.current.accent.color)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                onOpenLink(url)
                return .handled
            })
    }

    private func page(_ html: String, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if MailHTML.hasRemoteImages(html), !allowsImages { imagesQuestion }
            if let rules, rules.allowsImages == allowsImages {
                MailPage(document: MailHTML.document(html, allowingImages: rules.allowsImages), rules: rules, height: $height, onOpenLink: onOpenLink)
                    .frame(height: height)
                    .id(rules.allowsImages)
            } else if didPrepare, rules == nil {
                plain(fallback)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: allowsImages) {
            let images = allowsImages
            rules = await model.rules.list(allowingImages: images).map { MailPageRules(list: $0, allowsImages: images) }
            didPrepare = true
        }
    }

    private var imagesQuestion: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text(MailWording.imagesOff)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            HStack(spacing: Space.s4) {
                Button("Load Images") { loadedImages = true }
                if message.proof == .proved {
                    Button("Always load") {
                        Task { await model.alwaysLoadImages(from: message.from) }
                    }
                }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.accent.color)
            .buttonStyle(.plain)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}

/// Plain mail, with its web links made tappable.
enum MailText {
    static func linked(_ text: String) -> AttributedString {
        var linked = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return linked }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, url.scheme == "https" || url.scheme == "http",
                  let found = Range(match.range, in: text),
                  let range = Range(found, in: linked)
            else { continue }
            linked[range].link = url
        }
        return linked
    }
}

import PDFKit
import SwiftUI
import TotalityUI

/// An attachment on a message. Opening it reads it from the store into memory, and nothing is written
/// out in readable form to show it.
struct MailAttachmentView: View {
    let attachment: MailAttachment
    let model: MailModel

    @State private var data: Data?
    @State private var isOpen = false

    private var systemImage: String {
        switch attachment.preview {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case nil: "doc"
        }
    }

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Image(systemName: systemImage)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.name)
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Text(detail)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                Spacer(minLength: 0)
                if model.canSaveToReader {
                    Button {
                        Task { await model.saveToReader(attachment) }
                    } label: {
                        Image(systemName: "text.book.closed")
                            .font(Typeface.body)
                            .foregroundStyle(theme.accent.color)
                            .frame(width: Space.s6, height: Space.s6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save \(attachment.name) to the Reader")
                }
            }
            .contentShape(Rectangle())
            .tappable(toggle)
            if isOpen, let data {
                MailAttachmentPreview(kind: attachment.preview, data: data)
            }
        }
        .padding(Space.s3)
        .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private var detail: String {
        let size = attachment.size.formatted(.byteCount(style: .file))
        return attachment.preview == nil ? "\(size). This kind of file can't be previewed." : size
    }

    private func toggle() {
        guard attachment.preview != nil else { return }
        if isOpen {
            withAnimation(Motion.quick) { isOpen = false }
            return
        }
        Task {
            if data == nil { data = await model.data(of: attachment) }
            if data != nil { withAnimation(Motion.quick) { isOpen = true } }
        }
    }
}

private struct MailAttachmentPreview: View {
    private static let pageHeight = Space.s8 * 6

    let kind: MailAttachment.Preview?
    let data: Data

    var body: some View {
        switch kind {
        case .image:
            if let image = Image(mailData: data) {
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    .accessibilityLabel("Attached image")
            } else {
                unreadable
            }
        case .pdf:
            if let document = PDFDocument(data: data) {
                MailPDFView(document: document)
                    .frame(height: Self.pageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            } else {
                unreadable
            }
        case .text:
            Text(String(decoding: data, as: UTF8.self))
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.textPrimary.color)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }

    private var unreadable: some View {
        Text("This file couldn't be read.")
            .font(Typeface.caption)
            .foregroundStyle(Theme.current.danger.color)
    }
}

private extension Image {
    init?(mailData data: Data) {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #else
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #endif
    }
}

#if os(iOS)
private struct MailPDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
#else
private struct MailPDFView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
#endif

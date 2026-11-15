import SwiftUI
import TotalityUI
import UniformTypeIdentifiers

/// The two kinds of file a doc exports to.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, word

    var id: String { rawValue }
    var name: String { self == .pdf ? "PDF" : "Word (.docx)" }
    var contentType: UTType { self == .pdf ? .pdf : ExportFile.docx }
    var fileExtension: String { self == .pdf ? "pdf" : "docx" }
}

/// A finished export, handed to the system's save sheet. It's an ordinary file from here on.
struct ExportFile: FileDocument {
    static let docx = UTType(filenameExtension: "docx") ?? .data
    static var readableContentTypes: [UTType] { [.pdf, docx] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Chooses how a doc exports, makes the file, and hands it to the save sheet.
struct ExportSheet: View {
    let item: ReaderItem
    let model: ReaderModel
    /// Reads Markdown for export through the writing page, which knows the citations and notes.
    let read: (String) async -> ExportDocument?
    /// The open doc's words, saved first.
    let currentText: () async -> String

    private enum Phase: Equatable {
        case choosing, working, failed(String)
    }

    @AppStorage("reader.export.format") private var format = ExportFormat.pdf
    @AppStorage("reader.export.template") private var template = ExportTemplate.doc
    @AppStorage("reader.export.paper") private var paper = PaperSize.local
    @AppStorage("reader.writing.serif") private var serif = false
    @State private var chapters = false
    @State private var phase = Phase.choosing
    @State private var file: ExportFile?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var siblings: [ReaderItem] {
        guard let folder = item.folderID else { return [] }
        return model.items
            .filter { $0.kind == .note && $0.folderID == folder }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.name).tag($0) }
                    }
                    Picker("Layout", selection: $template) {
                        ForEach(ExportTemplate.allCases) { Text($0.name).tag($0) }
                    }
                    Picker("Paper", selection: $paper) {
                        ForEach(PaperSize.allCases) { Text($0.name).tag($0) }
                    }
                } footer: {
                    Text(template.detail)
                }
                if siblings.count > 1 {
                    Section {
                        Toggle("Every doc in this folder", isOn: $chapters)
                    } footer: {
                        Text("The \(siblings.count) docs in this folder go in as chapters, in title order, each on a new page. Number their titles, like 01 Opening, to set the order.")
                    }
                }
                Section {
                    switch phase {
                    case .working:
                        HStack(spacing: Space.s3) {
                            ProgressView()
                            Text("Making the file").foregroundStyle(theme.textSecondary.color)
                        }
                    case .failed(let reason):
                        Text(reason).foregroundStyle(theme.textPrimary.color)
                        exportButton
                    case .choosing:
                        exportButton
                    }
                } footer: {
                    Text("The exported file isn't sealed. It's an ordinary file, and anyone you give it to can read it. Citations, footnotes, images from your Reader and the bibliography go in. Images on the internet are left as their captions.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg.color)
            .navigationTitle("Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileExporter(
                isPresented: $saving, document: file, contentType: format.contentType,
                defaultFilename: "\(Self.filename(item.displayTitle)).\(format.fileExtension)"
            ) { result in
                if case .failure = result { phase = .failed("The file wasn't saved. Try again.") } else { dismiss() }
            }
        }
    }

    private var exportButton: some View {
        Button("Export") { Task { await export() } }
            .foregroundStyle(Theme.current.accent.color)
    }

    private func export() async {
        phase = .working
        let text = chapters ? await chapterText() : await currentText()
        guard let document = await read(text) else {
            phase = .failed("The doc couldn't be read for export.")
            return
        }
        let images = await model.exportImages(for: document, near: item.folderID)
        let data: Data? = switch format {
        case .word: WordExporter.docx(document, template: template, paper: paper, images: images)
        case .pdf: PDFExporter.pdf(document, template: template, paper: paper, images: images, serif: serif)
        }
        guard let data else {
            phase = .failed("The PDF couldn't be made. Try again.")
            return
        }
        file = ExportFile(data: data)
        phase = .choosing
        saving = true
    }

    private func chapterText() async -> String {
        var texts: [String] = []
        for doc in siblings {
            texts.append(doc.id == item.id ? await currentText() : await model.markdownForExport(doc.id) ?? "")
        }
        return ExportDocument.manuscript(texts)
    }

    /// A filename without the characters file systems refuse.
    static func filename(_ title: String) -> String {
        let cleaned = title.unicodeScalars.map { "/\\:*?\"<>|".unicodeScalars.contains($0) || $0.value < 0x20 ? "-" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
    }
}

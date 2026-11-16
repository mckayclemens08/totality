import CoreGraphics
import CoreText
import Darwin
import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

/// The memory check issue 124 asks for: a big scanned PDF imported, opened, drawn and read for Listen,
/// with the process's memory footprint (what Instruments shows) at its peak. It's skipped unless
/// `TOTALITY_MEMORY_CHECK` names a folder. With `TOTALITY_MEMORY_CHECK_MB` (default 300) it makes the PDF
/// there first, in its own run, so making it doesn't count, then measures in the next run:
///
///     TOTALITY_MEMORY_CHECK=/tmp/check swift test --filter LargePDFMemoryCheck/make
///     TOTALITY_MEMORY_CHECK=/tmp/check swift test --filter LargePDFMemoryCheck/measure
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOTALITY_MEMORY_CHECK"] != nil))
struct LargePDFMemoryCheck {
    private var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOTALITY_MEMORY_CHECK"] ?? NSTemporaryDirectory())
    }

    private var megabytes: Int {
        Int(ProcessInfo.processInfo.environment["TOTALITY_MEMORY_CHECK_MB"] ?? "") ?? 300
    }

    private var pdfURL: URL { folder.appendingPathComponent("scan-\(megabytes)mb.pdf") }

    @Test("Make the scanned PDF, written straight to its file")
    func make() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let side = 900
        let perPage = side * side * 4
        // Each grainy picture still shrinks to about three quarters in the file.
        let pages = megabytes * 1024 * 1024 / (perPage * 3 / 4) + 2
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: pdfURL as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for number in 0..<pages {
            autoreleasepool {
                var grain = [UInt8](repeating: 0, count: perPage)
                for index in grain.indices {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    grain[index] = UInt8(truncatingIfNeeded: state)
                }
                guard let provider = CGDataProvider(data: Data(grain) as CFData),
                      let picture = CGImage(
                          width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                      )
                else { return }
                context.beginPDFPage(nil)
                context.draw(picture, in: CGRect(x: 56, y: 140, width: 500, height: 500))
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: "Survey plate \(number + 1): the coast road north of Whitby, measured in 1923.",
                    attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
                ))
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        let size = try FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int ?? 0
        print("Memory check PDF: \(pages) pages, \(size / 1024 / 1024) MB")
        #expect(size > megabytes * 1024 * 1024)
    }

    @Test("Import, open, draw and read the PDF, and report the memory footprint at its peak")
    func measure() async throws {
        let size = try FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int ?? 0
        let storeFolder = folder.appendingPathComponent("vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeFolder) }
        let vault = ReaderVault(store: try FileBlobStore(directory: storeFolder), rootKey: try ContentRootKey.generate())
        let start = Self.footprint()

        let item = try await vault.importFile(at: pdfURL, filename: "Survey plates.pdf")
        let afterImport = Self.footprint()
        let file = try await vault.file(of: item.id)
        guard case .large(let pdf) = try #require(PDFSource.open(file)) else {
            Issue.record("Opened whole")
            return
        }
        var drawn = 0
        for index in stride(from: 0, to: pdf.pageCount, by: max(1, pdf.pageCount / 12)) {
            autoreleasepool {
                if pdf.image(of: index, pixelWidth: 1170) != nil { drawn += 1 }
                _ = pdf.textPage(index)
            }
        }
        let afterDrawing = Self.footprint()
        let text = try await vault.text(of: item.id)
        let map = ReadableText.pageMap(file)
        let afterReading = Self.footprint()

        print("""
        Memory check, \(size / 1024 / 1024) MB PDF, \(pdf.pageCount) pages:
          footprint at start \(start.now / 1_048_576) MB
          after import \(afterImport.now / 1_048_576) MB
          after drawing \(drawn) pages \(afterDrawing.now / 1_048_576) MB
          after reading all its words \(afterReading.now / 1_048_576) MB (\(text.count) characters, \(map.pages.count) pages mapped)
          peak \(afterReading.peak / 1_048_576) MB
        """)
        #expect(text.contains("Whitby"))
        #expect(map.pages.count == pdf.pageCount)
        // Far less than the file: it's never held whole.
        #expect(afterReading.peak < start.peak + UInt64(size / 2))
    }

    /// The process's memory footprint, now and at its highest, as Instruments and Xcode's gauge show it.
    private static func footprint() -> (now: UInt64, peak: UInt64) {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return (0, 0) }
        return (usage.ri_phys_footprint, usage.ri_lifetime_max_phys_footprint)
    }
}

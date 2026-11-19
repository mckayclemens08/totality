import SwiftUI
import TotalityCore
import TotalityUI
#if canImport(UIKit)
import AVFoundation
import UIKit
#endif

/// "Pair a browser" (website canvas, iPhone board, owner approved 2026-11-18). Scan, check, approve.
struct PairBrowserScreen: View {
    let model: PairBrowserModel

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                switch model.phase {
                case .scanning: scanner
                case .checking, .sending: ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                case .confirming(let label, let code): confirm(label: label, code: code)
                case .done: finished
                case .failed(let message): failure(message)
                }
                Label("Approve only if you started this and the code matches. Approving lets this browser open all your sealed content.", systemImage: "lock.fill")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.bg.color)
        .navigationTitle("Pair a browser")
        .onDisappear { model.restart() }
    }

    private var scanner: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s3) {
            #if canImport(UIKit)
            CodeScanner { text in Task { await model.scanned(text) } }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .accessibilityLabel("Camera for scanning the code on your computer")
            #endif
            Text("Point at the code on your computer. Open \(PairBrowserModel.website) and sign in to see it.")
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    private func confirm(label: String, code: String) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Check before you approve").font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.accent.color)
                detail("Website", PairBrowserModel.website)
                detail("Browser", label)
                detail("Code on screen", code)
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            AccountButton(title: "Approve", isWorking: false) { Task { await model.approve() } }
            Button("It's not me") { model.decline() }
                .font(Typeface.callout.weight(.semibold))
                .foregroundStyle(theme.textPrimary.color)
                .frame(maxWidth: .infinity, minHeight: Metric.headerButton)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .buttonStyle(SoftPress())
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.current.textSecondary.color)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(Theme.current.textPrimary.color).multilineTextAlignment(.trailing)
        }
        .font(Typeface.body)
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Browser added").font(Typeface.title)
            AccountDetail(text: "It will open on your computer in a moment. You can see it and remove it any time under Devices.")
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            AccountDetail(text: message)
            AccountButton(title: "Try again", isWorking: false) { model.restart() }
        }
    }
}

#if canImport(UIKit)
/// A camera that reads QR codes and reports each one's text. It reads only; nothing is saved.
private struct CodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    /// Delivered on the main queue (set above), so it's safe to step onto the main actor.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let texts = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            for text in texts { onCode?(text) }
        }
    }
}
#endif

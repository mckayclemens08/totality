import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif

/// Tells when the person scrolls, as opposed to the page following Listen. SwiftUI has no way to tell
/// on iOS 17, and a drag gesture on a scroll view competes with its scrolling.
@MainActor
final class ScrollWatch: NSObject {
    var onScroll: () -> Void = {}

    #if canImport(UIKit)
    private weak var scrollView: UIScrollView?

    func watch(_ view: UIView) {
        guard let found = Self.scrollView(around: view), found !== scrollView else { return }
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned))
        scrollView = found
        found.panGestureRecognizer.addTarget(self, action: #selector(panned))
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { onScroll() }
    }

    /// A SwiftUI scroll view is above the view, and the one inside a PDF view is below it.
    private static func scrollView(around view: UIView) -> UIScrollView? {
        var parent = view.superview
        while let current = parent {
            if let found = current as? UIScrollView { return found }
            parent = current.superview
        }
        return scrollView(in: view)
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        for child in view.subviews {
            if let found = (child as? UIScrollView) ?? scrollView(in: child) { return found }
        }
        return nil
    }
    #else
    private var monitor: Any?
    private weak var view: NSView?

    func watch(_ view: NSView) {
        self.view = view
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard let view, let area = view.enclosingScrollView ?? Optional(view), event.window === area.window else { return }
        if area.bounds.contains(area.convert(event.locationInWindow, from: nil)) { onScroll() }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    #endif
}

#if canImport(UIKit)
struct ScrollWatcher: UIViewRepresentable {
    let onScroll: () -> Void

    func makeCoordinator() -> ScrollWatch { ScrollWatch() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onScroll = onScroll
        // It has no superview yet on the first pass.
        Task { @MainActor in context.coordinator.watch(view) }
    }
}
#else
struct ScrollWatcher: NSViewRepresentable {
    let onScroll: () -> Void

    func makeCoordinator() -> ScrollWatch { ScrollWatch() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.watch(view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ScrollWatch) {
        coordinator.stop()
    }
}
#endif

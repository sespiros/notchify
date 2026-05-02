import AppKit
import SwiftUI

/// Vertical scroll container for the hover-expanded chip list.
/// Mirrors `HorizontalChipScroll`: SwiftUI's preference-key scroll
/// reporting is unreliable inside a `nonactivatingPanel` (the
/// hover-list bug had `listScrollOffset` stuck at 0 regardless of
/// actual scroll position), so we host the SwiftUI content inside
/// an explicit NSScrollView and publish the clip view's
/// `bounds.origin.y` to a SwiftUI binding via notifications.
struct VerticalListScroll<Content: View>: NSViewRepresentable {
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    @Binding var scrollOffset: CGFloat
    @Binding var contentHeight: CGFloat
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.usesPredominantAxisScrolling = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let host = NSHostingView(rootView: content())
        scroll.documentView = host
        sizeHostToFit(host: host, viewportWidth: viewportWidth)

        scroll.contentView.postsBoundsChangedNotifications = true
        host.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        context.coordinator.boundsObserver = center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [coord = context.coordinator] _ in
            // queue: .main keeps us on the main thread; Swift's
            // concurrency checker can't see that, so assert it for
            // the @MainActor-isolated method.
            MainActor.assumeIsolated { coord.publishScrollState() }
        }
        context.coordinator.frameObserver = center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: host,
            queue: .main
        ) { [coord = context.coordinator] _ in
            MainActor.assumeIsolated { coord.publishScrollState() }
        }

        context.coordinator.scrollView = scroll
        Task { @MainActor [coord = context.coordinator] in coord.publishScrollState() }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.scrollOffsetSetter = { v in
            if scrollOffset != v { scrollOffset = v }
        }
        context.coordinator.contentHeightSetter = { v in
            if contentHeight != v { contentHeight = v }
        }
        if let host = nsView.documentView as? NSHostingView<Content> {
            host.rootView = content()
            sizeHostToFit(host: host, viewportWidth: viewportWidth)
        }
        Task { @MainActor [coord = context.coordinator] in coord.publishScrollState() }
    }

    private func sizeHostToFit(host: NSView, viewportWidth: CGFloat) {
        let target = NSSize(width: viewportWidth, height: 0)
        let fitting = host.fittingSize
        let height = max(fitting.height, target.height)
        host.frame = NSRect(x: 0, y: 0, width: viewportWidth, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        var scrollOffsetSetter: ((CGFloat) -> Void)?
        var contentHeightSetter: ((CGFloat) -> Void)?
        var boundsObserver: NSObjectProtocol?
        var frameObserver: NSObjectProtocol?

        deinit {
            if let o = boundsObserver { NotificationCenter.default.removeObserver(o) }
            if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
        }

        @MainActor
        func publishScrollState() {
            guard let sv = scrollView else { return }
            // NSScrollView with default flipped=false uses a
            // bottom-origin coordinate system on the document. We
            // want a top-down "how far have we scrolled past the
            // top" value. With a flipped clip view this is just
            // bounds.origin.y; with the default it's docHeight -
            // (bounds.origin.y + bounds.height).
            let cv = sv.contentView
            let docH = sv.documentView?.frame.height ?? 0
            let visibleH = cv.bounds.height
            let offset: CGFloat
            if cv.isFlipped {
                offset = cv.bounds.origin.y
            } else {
                offset = max(0, docH - (cv.bounds.origin.y + visibleH))
            }
            scrollOffsetSetter?(offset)
            contentHeightSetter?(docH)
        }
    }
}

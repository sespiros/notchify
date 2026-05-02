import AppKit
import SwiftUI

/// Horizontal scroll container for the chip shelf. SwiftUI's macOS
/// ScrollView wraps NSScrollView but does not translate vertical
/// mouse-wheel events into horizontal scroll, so a wheel-only mouse
/// over a horizontal-only ScrollView produces no motion. This wraps
/// an NSScrollView whose `scrollWheel(with:)` synthesizes horizontal
/// motion from any vertical wheel delta, while leaving native
/// trackpad two-finger horizontal swipes untouched. Programmatic
/// auto-scroll-to-trailing is exposed via `scrollToTrailingTrigger`:
/// bump the value to request the document scroll fully to the right.
struct HorizontalChipScroll<Content: View>: NSViewRepresentable {
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    /// Desired clip-view bounds origin x, computed by the caller
    /// to put the active chip in view. nil means "leave the scroll
    /// position alone" (e.g., between same-chipstack body swaps the
    /// livestack is briefly empty and we don't want to chase a
    /// fallback target like the newest chip).
    let scrollTargetX: CGFloat?
    /// Mirrors `clipView.bounds.origin.x` so SwiftUI can drive
    /// scroll-position-dependent overlays (leading/trailing fades).
    @Binding var scrollOffset: CGFloat
    /// Mirrors `documentView.frame.width` so the SwiftUI side can
    /// compute whether there's content past the trailing edge.
    @Binding var contentWidth: CGFloat
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> WheelTranslatingScrollView {
        let scroll = WheelTranslatingScrollView()
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.usesPredominantAxisScrolling = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let host = ScrollPassthroughHostingView(rootView: content())
        scroll.documentView = host
        sizeHostToFit(host: host, viewportHeight: viewportHeight)

        // Observe clip-view bounds changes (i.e., scrolls) and
        // document-view frame changes (i.e., chip count delta) so
        // the SwiftUI bindings stay in sync.
        scroll.contentView.postsBoundsChangedNotifications = true
        host.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        context.coordinator.boundsObserver = center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [coord = context.coordinator] _ in
            // queue: .main guarantees we're on the main thread, but
            // Swift's concurrency checker can't see that, so we have
            // to assert it for the @MainActor-isolated method.
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
        DispatchQueue.main.async { context.coordinator.publishScrollState() }
        return scroll
    }

    func updateNSView(_ nsView: WheelTranslatingScrollView, context: Context) {
        context.coordinator.scrollOffsetSetter = { newValue in
            // Avoid feedback loops by writing the binding only when
            // it actually changed.
            if scrollOffset != newValue { scrollOffset = newValue }
        }
        context.coordinator.contentWidthSetter = { newValue in
            if contentWidth != newValue { contentWidth = newValue }
        }
        if let host = nsView.documentView as? NSHostingView<Content> {
            host.rootView = content()
            sizeHostToFit(host: host, viewportHeight: viewportHeight)
        }
        if let requested = scrollTargetX,
           context.coordinator.lastAppliedTargetX != requested {
            context.coordinator.lastAppliedTargetX = requested
            DispatchQueue.main.async {
                guard let doc = nsView.documentView else { return }
                let visible = nsView.contentView.bounds.width
                let maxX = max(0, doc.frame.width - visible)
                let target = min(maxX, max(0, requested))
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.allowsImplicitAnimation = true
                    nsView.contentView.animator().setBoundsOrigin(NSPoint(x: target, y: 0))
                    nsView.reflectScrolledClipView(nsView.contentView)
                }
            }
        }
        DispatchQueue.main.async { context.coordinator.publishScrollState() }
    }

    private func sizeHostToFit(host: NSView, viewportHeight: CGFloat) {
        let fitting = host.fittingSize
        let width = max(fitting.width, 1)
        host.frame = NSRect(x: 0, y: 0, width: width, height: viewportHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var scrollView: WheelTranslatingScrollView?
        var lastAppliedTargetX: CGFloat = .nan
        var scrollOffsetSetter: ((CGFloat) -> Void)?
        var contentWidthSetter: ((CGFloat) -> Void)?
        var boundsObserver: NSObjectProtocol?
        var frameObserver: NSObjectProtocol?

        deinit {
            if let o = boundsObserver { NotificationCenter.default.removeObserver(o) }
            if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
        }

        @MainActor
        func publishScrollState() {
            guard let sv = scrollView else { return }
            scrollOffsetSetter?(sv.contentView.bounds.origin.x)
            contentWidthSetter?(sv.documentView?.frame.width ?? 0)
        }
    }
}

/// NSHostingView subclass that forwards scroll-wheel events up
/// the responder chain. Default NSHostingView consumes these for
/// SwiftUI gesture handling, which prevents our enclosing
/// NSScrollView from ever seeing them.
private final class ScrollPassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// NSScrollView subclass that lets the mouse's vertical wheel
/// scroll the chip shelf horizontally without manual smoothing.
/// Trackpad and Magic-Mouse continuous gestures are forwarded as-is
/// (so horizontal swipes scroll natively with bounce, and vertical
/// swipes are intentionally ignored). Discrete legacy wheel ticks
/// from a wheel mouse are translated by directly shifting the clip
/// view's bounds — no rubber-band, no snap-back, no animation
/// proxy. Choppy is the cost of native-only behavior.
final class WheelTranslatingScrollView: NSScrollView {
    /// Lines-per-tick from a non-precise wheel are small integers;
    /// multiply to get a meaningful pixel shift per click.
    private static let pixelsPerLine: CGFloat = 22

    override func scrollWheel(with event: NSEvent) {
        // Trackpad / Magic Mouse: continuous gestures carry a phase.
        // Forward unchanged so NSScrollView handles them natively
        // (horizontal swipe scrolls + bounces; vertical swipe is
        // ignored because the view has no vertical axis).
        if event.phase != [] || event.momentumPhase != [] {
            super.scrollWheel(with: event)
            return
        }
        // Discrete mouse wheel: translate vertical-only ticks to
        // horizontal motion so the wheel can reach hidden chips.
        let dy = event.scrollingDeltaY
        guard event.scrollingDeltaX == 0, dy != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let pixelDelta = event.hasPreciseScrollingDeltas
            ? dy
            : dy * Self.pixelsPerLine
        let cv = contentView
        let docWidth = documentView?.frame.width ?? 0
        let maxX = max(0, docWidth - cv.bounds.width)
        var origin = cv.bounds.origin
        origin.x = min(maxX, max(0, origin.x - pixelDelta))
        cv.setBoundsOrigin(origin)
        reflectScrolledClipView(cv)
    }
}

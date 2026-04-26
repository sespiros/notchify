import AppKit
import SwiftUI

// nonactivatingPanel windows swallow the first mouse-down by default,
// so SwiftUI tap gestures inside only register on the SECOND click.
// Overriding the host view's acceptsFirstMouse makes the first click
// register, so tap-to-dismiss / tap-to-run-action works immediately.
private final class FirstMouseHosting<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    // Reuse a single panel + NSHostingView across notifications. Building
    // them fresh per-notification adds noticeable first-frame lag because
    // SwiftUI reruns its initial layout each time.
    private let panel: NSPanel
    private let hosting: FirstMouseHosting<AnyView>
    private var queue: [Message] = []
    private var presenting = false

    init() {
        // Pick a panel size large enough for the maximum expanded form.
        // The actual visible rectangle is constrained by the SwiftUI view.
        let panelSize = NSSize(
            width: NotchController.maxNotchWidth + NotchView.leftExtra,
            height: NotchController.maxNotchHeight + NotchView.extraHeight
        )
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        hosting = FirstMouseHosting(rootView: AnyView(EmptyView()))
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    func present(_ message: Message) {
        if Focus.doNotDisturbActive() {
            NSLog("notchify: DND active, dropping \"\(message.title)\"")
            return
        }
        if presenting {
            queue.append(message)
            return
        }
        showNow(message)
    }

    private func showNow(_ message: Message) {
        presenting = true
        Sound.play(message.sound)

        // Match macOS Notification Center behavior: render on the primary
        // display. NSScreen.screens.first is documented as the main display
        // (the one with the menubar in System Settings → Displays). When
        // that display has a hardware notch the overlay is flush; on a
        // notch-less primary the rectangle hangs from the top edge.
        let screen = NSScreen.screens.first
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let notchSize = Self.notchSize(for: screen)
        let panelWidth = notchSize.width + NotchView.leftExtra
        let panelHeight = notchSize.height + NotchView.extraHeight

        // Right edge of the panel pinned to the right edge of the centered notch.
        let notchRight = screen.frame.midX + notchSize.width / 2
        let originX = notchRight - panelWidth
        let originY = screen.frame.maxY - panelHeight

        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            display: false
        )

        hosting.rootView = AnyView(
            NotchView(
                message: message,
                notchSize: notchSize,
                onClick: { [weak self] in self?.runAction(message.action) },
                onDismiss: { [weak self] in self?.handleDismissed() }
            )
        )

        panel.orderFrontRegardless()
    }

    private func handleDismissed() {
        panel.orderOut(nil)
        // Replace with EmptyView so the previous message's SwiftUI state
        // is released and the next show starts clean.
        hosting.rootView = AnyView(EmptyView())
        presenting = false
        if !queue.isEmpty {
            let next = queue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showNow(next)
            }
        }
    }

    private func runAction(_ action: String?) {
        guard let action, !action.isEmpty else { return }
        if let url = URL(string: action), let scheme = url.scheme, !scheme.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", action]
        try? task.run()
    }

    // Generous upper bound used for sizing the persistent panel; actual
    // sizing per-notification is `notchSize(for:) + NotchView.leftExtra`.
    private static let maxNotchWidth: CGFloat = 240
    private static let maxNotchHeight: CGFloat = 40

    private static func notchSize(for screen: NSScreen) -> CGSize {
        let height = screen.safeAreaInsets.top
        if height <= 0 {
            return CGSize(width: 200, height: 32)
        }
        let envWidth = ProcessInfo.processInfo.environment["NOTCHIFY_NOTCH_WIDTH"]
            .flatMap { Double($0) }.map { CGFloat($0) }
        let width = envWidth ?? 178
        return CGSize(width: width, height: height)
    }
}

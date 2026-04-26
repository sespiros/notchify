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
    private var currentMessage: Message?
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
        guard let geometry = NotchGeometry.current() else {
            NSLog("notchify: no active display, dropping \"\(message.title)\"")
            advanceQueueAfterDrop()
            return
        }

        currentMessage = message
        presenting = true
        Sound.play(message.sound)

        let notchSize = geometry.notchSize
        let panelWidth = notchSize.width + NotchView.leftExtra
        let panelHeight = notchSize.height + NotchView.extraHeight

        // Right edge of the panel pinned to the right edge of the centered notch.
        let notchRight = geometry.notchRect.maxX
        let originX = notchRight - panelWidth
        let originY = geometry.notchRect.maxY - panelHeight

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
        currentMessage = nil
        presenting = false
        if !queue.isEmpty {
            let next = queue.removeFirst()
            scheduleNext(next)
        }
    }

    func screenConfigurationDidChange() {
        guard presenting, let currentMessage else { return }

        panel.orderOut(nil)
        hosting.rootView = AnyView(EmptyView())
        self.currentMessage = nil
        presenting = false

        scheduleNext(currentMessage, delay: .milliseconds(100))
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
    // sizing per-notification is `NotchGeometry.current()?.notchSize + NotchView.leftExtra`.
    private static let maxNotchWidth: CGFloat = 320
    private static let maxNotchHeight: CGFloat = 40

    private func advanceQueueAfterDrop() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        scheduleNext(next)
    }

    private func scheduleNext(_ message: Message, delay: Duration = .milliseconds(250)) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.showNow(message)
        }
    }
}

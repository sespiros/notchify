import AppKit
import SwiftUI

// nonactivatingPanel windows swallow the first mouse-down by default,
// so SwiftUI tap gestures inside only register on the SECOND click.
// Overriding the host view's acceptsFirstMouse makes the first click
// register, so tap-to-dismiss / tap-to-run-action works immediately.
private final class FirstMouseHosting<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One queued/in-flight notification with an identity stable across
/// the data model. The id lets the SwiftUI side address a specific
/// row when rendering the expanded list and lets focus-detection
/// dismiss a single row out of a stack.
struct StoredNotification: Identifiable {
    let id = UUID()
    let message: Message
    let stackID: String
    let arrivedAt = Date()
}

/// All notifications sharing a chip slot. `id` is "g:<group>" for
/// named groups or "a:_anon" for the shared anonymous chip.
/// `notifications` is newest-first to match the standard
/// notification-center sort.
struct NotificationStack: Identifiable {
    let id: String
    let isAnonymous: Bool
    var notifications: [StoredNotification] = []

    /// Resolved chip icon and color, locked from the *first*
    /// notification that supplied them. Subsequent notifications
    /// can't repaint the slot.
    var resolvedIcon: String?
    var resolvedColor: String?
}

@MainActor
final class NotchController {
    private let panel: NSPanel
    private let hosting: FirstMouseHosting<AnyView>
    private let model = NotchModel()

    /// Authoritative stack store keyed by stackID. The model's `stacks`
    /// array is a projection of this through `stackOrder`, rebuilt on
    /// every mutation so SwiftUI sees a clean snapshot.
    private var stacks: [String: NotificationStack] = [:]
    /// Display order, left-to-right. New stacks append (sit closest
    /// to the notch); existing stacks shift further left.
    private var stackOrder: [String] = []

    /// Sequenced slide-in queue. At most one notification animates
    /// at a time, the rest wait here.
    private var arrivals: [StoredNotification] = []

    /// The dwell timer for the in-flight notification. Cancellable on
    /// click so the retraction proceeds immediately instead of waiting
    /// out the full dwell.
    private var dwellTask: Task<Void, Never>?
    /// Cleanup task scheduled after a retraction starts. Re-scheduled
    /// per retraction; tracked here only so `screenConfigurationDidChange`
    /// can cancel an in-flight teardown.
    private var cleanupTask: Task<Void, Never>?
    /// Slide-in task scheduled when the pill is going from hidden to
    /// visible. Used to distinguish "genuine mid-slide-in" (where
    /// `midSlide` should silently queue) from "mid-teardown that was
    /// cancelled" (where the new arrival should publish + start now).
    private var slideInTask: Task<Void, Never>?
    /// 1 Hz poll that auto-dismisses `-focus` notifications once the
    /// user visits their source. Runs only while there are
    /// dismissKey-bearing rows in the stacks.
    private var focusTimer: Timer?

    init() {
        // Pre-allocate enough horizontal room for the notch plus a row
        // of slots, and enough vertical room for the in-flight drop +
        // hover-expanded list. The panel is invisible; only its
        // content paints, so over-sizing just costs empty pixels.
        let panelSize = NSSize(
            width: NotchController.maxNotchWidth + NotchController.shelfBudget,
            height: NotchController.maxNotchHeight + NotchPillView.extraHeight + NotchController.expansionShelf
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

        // Bind the unified pill view to the model exactly once.
        // Subsequent updates flow via @Published mutations on `model`.
        hosting.rootView = AnyView(
            NotchPillView(
                model: model,
                onClick: { [weak self] n in self?.handleClick(n) },
                onRowClick: { [weak self] n in self?.handleRowClick(n) },
                onChipClick: { [weak self] stackID in self?.handleChipClick(stackID) },
                onInflightHover: { [weak self] hovering in self?.handleInflightHover(hovering) },
                onEngagementChange: { [weak self] engaged in self?.handleEngagementChange(engaged) }
            )
        )
    }

    func present(_ message: Message) {
        if Focus.doNotDisturbActive() {
            // Don't play the in-flight or sound while DND is active,
            // but still ingest into the stack so the user can see
            // what they missed once they take their headphones off.
            // Equivalent to "engagement-piled" arrivals: persistent
            // row, no animation, no sound. They'll resume normal
            // lifecycle if DND clears (left to a future tweak).
            let stackID = stackIDFor(message)
            let notification = StoredNotification(message: message, stackID: stackID)
            ingest(notification)
            ensurePanelOnScreen()
            publishStacks()
            return
        }

        // Already-focused-at-arrival → drop. If the user is already
        // looking at the source, the notification's job is done
        // before the slide-in even starts.
        if let key = message.dismissKey {
            let bundle = FocusDetector.frontmostBundleID()
            var paneCache: [String?: Set<String>] = [:]
            let provider: (String?) -> Set<String> = { socket in
                if let cached = paneCache[socket] { return cached }
                let panes = FocusDetector.activeTmuxPanes(socket: socket)
                paneCache[socket] = panes
                return panes
            }
            if FocusDetector.matches(key, bundle: bundle, activePanesProvider: provider) {
                NSLog("%@", "notchify: \"\(message.title)\" — source already focused, dropping")
                return
            }
        }

        // Cancel any in-progress teardown so a freshly arrived
        // notification keeps the pill on screen instead of fighting
        // a slide-up.
        teardownTask?.cancel()
        teardownTask = nil
        // A fresh arrival exits the "retracting" UX state.
        model.inRetraction = false

        let stackID = stackIDFor(message)
        let isNewStack = (stacks[stackID] == nil)
        let notification = StoredNotification(message: message, stackID: stackID)
        ingest(notification)

        ensurePanelOnScreen()

        // Always queue. Engagement just postpones playback; when the
        // user disengages, the queue resumes naturally.
        arrivals.append(notification)

        if model.isUserEngaged {
            // While the user is reading the pill, update the chip
            // badge / shelf but don't trigger phase c. The
            // notification sits in `arrivals` and will be picked up
            // once the user disengages (via handleEngagementChange).
            publishStacks()
            return
        }

        // Three arrival regimes, picked by the *current* model state
        // (which the user sees right now):
        //
        // 1. pillCurrentlyHidden: pill is off-screen. Phase a (slide
        //    down) plays first with no slots. After it finishes, we
        //    publish the new stack (b) and let the icon fade (b'),
        //    then drop for text (c). Bursts arriving mid-slide just
        //    queue and get picked up when the slide-task fires.
        //
        // 2. midSlide: pill is mid-slide-in (forcedVisible but no
        //    stacks published yet). Just queue; the slide-task
        //    publishes everything together when it fires.
        //
        // 3. visible: pill is already showing. New stacks publish
        //    immediately (b plays in isolation). Existing stacks
        //    just publish to bump the badge.
        let pillCurrentlyHidden =
            model.stacks.isEmpty && model.inflight == nil && !model.forcedVisible
        // Genuine mid-slide-in: forcedVisible set + stacks empty AND
        // there's an actual slide-in task pending. If slideInTask is
        // nil and we're in this state, we're mid-teardown (or
        // post-cancel teardown) and should fall through to publish
        // + start, NOT silently queue.
        let midSlide = model.forcedVisible && model.stacks.isEmpty && slideInTask != nil

        if pillCurrentlyHidden {
            model.forcedVisible = true
            slideInTask?.cancel()
            slideInTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(NotchController.slideInDuration))
                guard let self else { return }
                self.slideInTask = nil
                self.completeSlideIn()
            }
            return
        }

        if midSlide {
            // The slide-task will publish + start everything when it
            // fires; nothing to do here beyond the ingest above.
            return
        }

        publishStacks()
        if model.inflight == nil {
            startNext(newStack: isNewStack)
        }
    }

    /// Fires once the slide-in animation has played. Publishes every
    /// stack ingested during the slide so the slot transitions begin
    /// (b), then kicks off the first in-flight (c).
    private func completeSlideIn() {
        publishStacks()
        if model.inflight == nil && !arrivals.isEmpty {
            startNext(newStack: true)
        }
    }

    private func stackIDFor(_ message: Message) -> String {
        if let g = message.group, !g.isEmpty { return "g:\(g)" }
        // Ungrouped notifications:
        // - If customized (any -icon or -color set), each gets its
        //   own throwaway chip — treat the customization as an
        //   implicit one-shot group.
        // - If plain (no customization), coalesce under a shared
        //   default chip so a flurry of vanilla notifications doesn't
        //   spawn a chip per arrival.
        let isCustomized = (message.icon != nil) || (message.color != nil)
        if isCustomized {
            return "a:\(UUID().uuidString)"
        }
        return "a:_default"
    }

    private func ingest(_ notification: StoredNotification) {
        let id = notification.stackID
        let isAnon = id.hasPrefix("a:")
        if stacks[id] == nil {
            stacks[id] = NotificationStack(id: id, isAnonymous: isAnon)
            stackOrder.append(id)
        }
        let m = notification.message
        var stack = stacks[id]!
        if stack.resolvedIcon == nil {
            stack.resolvedIcon = m.icon
        }
        if stack.resolvedColor == nil {
            stack.resolvedColor = m.color
        }
        stack.notifications.insert(notification, at: 0)
        stacks[id] = stack
        // Track the latest-ingested stack so the view can expand it
        // when the user hovers a generic (non-chip) part of the pill.
        model.mostRecentStackID = id
    }

    private func publishStacks() {
        model.stacks = stackOrder.compactMap { stacks[$0] }
        // Once stacks are non-empty, pillVisible is satisfied by them.
        // Clear forcedVisible so the slide-up logic works naturally
        // when the last stack is later removed.
        if !model.stacks.isEmpty {
            model.forcedVisible = false
        }
        updateFocusTimer()
    }

    /// Start/stop the focus poll based on whether any notification in
    /// the current stacks carries a dismissKey. Idempotent.
    private func updateFocusTimer() {
        let needsPoll = stacks.values.contains { stack in
            stack.notifications.contains { $0.message.dismissKey != nil }
        }
        if needsPoll {
            if focusTimer == nil {
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkFocus() }
                }
                timer.tolerance = 0.2
                RunLoop.main.add(timer, forMode: .common)
                focusTimer = timer
            }
        } else {
            focusTimer?.invalidate()
            focusTimer = nil
        }
    }

    /// One tick of the focus poll: dismiss any rows whose dismissKey
    /// matches what the user is currently looking at.
    private func checkFocus() {
        let bundle = FocusDetector.frontmostBundleID()
        // Cache active panes per tmux socket so we make at most one
        // tmux subprocess per server, regardless of how many rows
        // reference it.
        var paneCache: [String?: Set<String>] = [:]
        let provider: (String?) -> Set<String> = { socket in
            if let cached = paneCache[socket] { return cached }
            let panes = FocusDetector.activeTmuxPanes(socket: socket)
            paneCache[socket] = panes
            return panes
        }

        var toDismiss: [StoredNotification] = []
        for stackID in stackOrder {
            guard let stack = stacks[stackID] else { continue }
            for n in stack.notifications {
                if let key = n.message.dismissKey,
                   FocusDetector.matches(key, bundle: bundle, activePanesProvider: provider) {
                    toDismiss.append(n)
                }
            }
        }
        guard !toDismiss.isEmpty else { return }

        for n in toDismiss {
            if model.inflight?.id == n.id {
                // Remove from stack first so cleanup's removeNotification
                // is a no-op; then play the in-flight retract.
                removeNotification(n)
                beginRetraction(of: n, viaClick: true)
            } else {
                removeNotification(n)
            }
        }
        publishStacks()
        if stacks.isEmpty && model.inflight == nil {
            scheduleEndOfPillRetract()
        }
    }

    /// Make sure the panel is positioned on the active display and
    /// ordered front. Idempotent — safe to call on every `present`.
    @discardableResult
    private func ensurePanelOnScreen() -> Bool {
        guard let geometry = NotchGeometry.current() else { return false }
        let notchSize = geometry.notchSize
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height
        let notchRight = geometry.notchRect.maxX
        let originX = notchRight - panelWidth
        let originY = geometry.notchRect.maxY - panelHeight

        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            display: false
        )
        model.notchSize = notchSize
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        return true
    }

    private func startNext(newStack: Bool) {
        guard model.inflight == nil else { return }
        guard !arrivals.isEmpty else { return }
        let next = arrivals.removeFirst()

        guard ensurePanelOnScreen() else {
            NSLog("notchify: no active display, dropping \"\(next.message.title)\"")
            removeNotification(next)
            publishStacks()
            startNext(newStack: false)
            return
        }

        Sound.play(next.message.sound)

        // For a new group, wait for the shelf-grow + slot slide to
        // play before triggering the height drop. The slot fade-in
        // completes well within the slide (~60ms vs 200ms slide), so
        // we only need to wait for the slide itself. For an existing
        // group the shelf is already at the right width, so drop
        // almost immediately.
        let arrivalDelay: Duration = newStack
            ? .milliseconds(NotchController.phaseBToCDelay)
            : .milliseconds(50)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: arrivalDelay)
            guard let self else { return }
            // If engagement started during phase a/b, push the
            // arrival back onto the queue. It resumes when the user
            // disengages (handleEngagementChange picks it up).
            if self.model.isUserEngaged {
                self.arrivals.insert(next, at: 0)
                return
            }
            self.model.inflight = next
            self.scheduleDwell(for: next)
        }
    }

    private func scheduleDwell(for n: StoredNotification) {
        dwellTask?.cancel()
        let dwell: TimeInterval = isPersistent(n) ? 4.0 : (n.message.timeout ?? 5.0)
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            self?.beginRetraction(of: n, viaClick: false)
        }
    }

    private func handleClick(_ n: StoredNotification) {
        runAction(n.message.action)
        beginRetraction(of: n, viaClick: true)
    }

    /// Engagement transitions. While engaged, new arrivals are
    /// queued silently; once the user disengages, queued arrivals
    /// resume their normal lifecycle (slide-in, dwell, retract).
    private func handleEngagementChange(_ engaged: Bool) {
        guard !engaged else { return }
        guard !arrivals.isEmpty, model.inflight == nil else { return }
        let nextIsNewStack = arrivals.first.map {
            stacks[$0.stackID]?.notifications.count == 1
        } ?? false
        startNext(newStack: nextIsNewStack)
    }

    /// Hover on the in-flight body pauses the dwell timer (so the
    /// notification waits while the user reads it). Un-hover restarts
    /// the dwell from full duration. Mirrors the original NotchView's
    /// pause-on-hover behavior.
    private func handleInflightHover(_ hovering: Bool) {
        guard let n = model.inflight else { return }
        if hovering {
            dwellTask?.cancel()
            dwellTask = nil
        } else {
            scheduleDwell(for: n)
        }
    }

    /// Click on a chip slot. Dismisses the topmost (newest)
    /// notification in that stack — repeated clicks dismiss
    /// successively older ones, top-to-bottom. Runs the row's
    /// action if any. If the top is also the currently in-flight
    /// notification, kicks off the retraction so the body actually
    /// goes away instead of waiting out the dwell.
    private func handleChipClick(_ stackID: String) {
        guard let top = stacks[stackID]?.notifications.first else { return }
        runAction(top.message.action)
        if model.inflight?.id == top.id {
            beginRetraction(of: top, viaClick: true)
            return
        }
        // Hold the pill visible across the slot retract (e) so it
        // doesn't immediately slide up when stacks empties under us.
        // Without this, pillVisible flips false at publishStacks
        // time and the pill races up while the slot is still
        // animating out.
        let willEmptyEverything = (stacks.count == 1)
            && (stacks[stackID]?.notifications.count ?? 0) <= 1
            && model.inflight == nil
        if willEmptyEverything {
            model.forcedVisible = true
        }
        removeNotification(top)
        publishStacks()
        if willEmptyEverything {
            scheduleEndOfPillRetract()
        }
    }

    /// Click on a row in an expanded chip list. Independent of the
    /// in-flight: removes that single row from its stack (collapsing
    /// the slot if it was the last), runs its action.
    private func handleRowClick(_ n: StoredNotification) {
        runAction(n.message.action)
        let willEmptyEverything = (stacks.count == 1)
            && (stacks[n.stackID]?.notifications.count ?? 0) <= 1
            && model.inflight == nil
        if willEmptyEverything {
            // Hold the pill visible during the slot retract (e) so it
            // doesn't get caught up in the pill slide-up (f). The
            // teardown task clears `forcedVisible` once e has played.
            model.forcedVisible = true
        }
        removeNotification(n)
        publishStacks()
        if willEmptyEverything {
            scheduleEndOfPillRetract()
        }
    }

    /// Tear the in-flight notification back down. The view animates
    /// the text-out + height-retract; we wait for that to finish, then
    /// decide whether the row stays in its stack (persistent + auto)
    /// or gets removed (clicked or non-persistent).
    private func beginRetraction(of n: StoredNotification, viaClick: Bool) {
        guard model.inflight?.id == n.id else { return }
        dwellTask?.cancel()
        dwellTask = nil
        model.inRetraction = true
        model.inflight = nil

        cleanupTask?.cancel()
        cleanupTask = Task { @MainActor [weak self] in
            // Wait for body fade-out + pillHeight retract to play
            // before the next phase (slot retract / startNext).
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }

            let willRemove = viaClick || !self.isPersistent(n)
            let willEmptyEverything = willRemove
                && (self.stacks.count == 1)
                && (self.stacks[n.stackID]?.notifications.count ?? 0) <= 1
                && self.arrivals.isEmpty

            if willEmptyEverything {
                // Hold pill visible for the slot retract (e), then
                // schedule the slide-up (f) afterward.
                self.model.forcedVisible = true
            }

            if willRemove {
                self.removeNotification(n)
                self.publishStacks()
            }

            if !self.arrivals.isEmpty {
                if self.model.isUserEngaged {
                    // Postpone, don't drain — arrivals resume on
                    // disengage. handleEngagementChange picks up.
                } else {
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled else { return }
                    let nextIsNewStack = self.arrivals.first.map {
                        self.stacks[$0.stackID]?.notifications.count == 1
                    } ?? false
                    self.startNext(newStack: nextIsNewStack)
                    return
                }
            }

            if self.stacks.isEmpty {
                self.scheduleEndOfPillRetract()
            } else {
                // Partial retraction: a notification removed but the
                // stack continues. Pill has settled at chip-row
                // state, no slide-up coming. Clear hover-suppression
                // so the user can interact with the remaining slots.
                self.model.inRetraction = false
            }
        }
    }

    /// After the last slot retract (e), hold for the retract animation
    /// to play, then clear `forcedVisible` to let the pill slide up
    /// (f). After that animation, finally `orderOut` the panel.
    private func scheduleEndOfPillRetract() {
        teardownTask?.cancel()
        teardownTask = Task { @MainActor [weak self] in
            // (e): slot retracts back behind the notch.
            try? await Task.sleep(for: .milliseconds(NotchController.slotRetractDuration))
            guard let self, !Task.isCancelled else { return }
            // (f): pill slides up off-screen.
            self.model.forcedVisible = false
            try? await Task.sleep(for: .milliseconds(NotchController.slideOutDuration))
            guard !Task.isCancelled else { return }
            if self.stacks.isEmpty && self.model.inflight == nil {
                self.panel.orderOut(nil)
            }
            self.model.inRetraction = false
            self.teardownTask = nil
        }
    }
    private var teardownTask: Task<Void, Never>?

    private func isPersistent(_ n: StoredNotification) -> Bool {
        if let t = n.message.timeout, t == 0 { return true }
        return false
    }

    private func removeNotification(_ n: StoredNotification) {
        guard var stack = stacks[n.stackID] else { return }
        stack.notifications.removeAll { $0.id == n.id }
        if stack.notifications.isEmpty {
            stacks.removeValue(forKey: n.stackID)
            stackOrder.removeAll { $0 == n.stackID }
        } else {
            stacks[n.stackID] = stack
        }
    }

    func screenConfigurationDidChange() {
        guard let current = model.inflight else { return }
        cleanupTask?.cancel()
        dwellTask?.cancel()
        model.inflight = nil
        // Replay the in-flight one on the new geometry.
        arrivals.insert(current, at: 0)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.ensurePanelOnScreen()
            let isNew = self.stacks[current.stackID]?.notifications.count == 1
            self.startNext(newStack: isNew)
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

    private static let maxNotchWidth: CGFloat = 320
    private static let maxNotchHeight: CGFloat = 40
    /// Reserved horizontal room for the shelf. Sized for ~6 slots.
    private static let shelfBudget: CGFloat = 240
    /// Reserved vertical room below the notch for hover-expanded
    /// row lists. Sized for ~5 rows at ~50pt each.
    private static let expansionShelf: CGFloat = 280
    /// Phase a → b gap: matches the 0.22s pill slide-in animation.
    private static let slideInDuration: Int = 150
    /// Phase b → c gap: drop-down for text starts after shelf+icon
    /// have settled. ~300ms feels right per origin/main.
    private static let phaseBToCDelay: Int = 300
    /// Phase b animation duration (shelf widen + icon appear).
    private static let shelfGrowDuration: Int = 200
    /// Phase e: slot retracts (matches slot transition's 0.13s
    /// opacity curve, plus a small buffer).
    private static let slotRetractDuration: Int = 140
    /// Phase f: pill slides up off-screen (matches 0.22s pillVisible
    /// curve, plus buffer for orderOut).
    private static let slideOutDuration: Int = 250
}

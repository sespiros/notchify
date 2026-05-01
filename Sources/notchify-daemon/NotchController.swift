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
    private let panel: NSPanel
    private let hosting: FirstMouseHosting<NotchPillView>
    private let model = NotchModel()

    /// Authoritative chipstack store keyed by chipstackID. The
    /// model's `chipstacks` array is a projection of this through
    /// `chipstackOrder`, rebuilt on every mutation so SwiftUI sees
    /// a clean snapshot.
    private var chipstacks: [String: ChipStack] = [:]
    /// Display order, left-to-right. New chipstacks append (sit
    /// closest to the notch); existing ones shift further left.
    private var chipstackOrder: [String] = []

    /// Sequenced slide-in queue. At most one notification animates
    /// at a time, the rest wait here.
    private var arrivals: [StoredNotification] = []

    /// Per-row dwell timers, keyed by notification id. Each live-stack
    /// row gets its own; expiration removes that one row (and starts
    /// the pill retract only when the live stack drains). Cancelled
    /// on click, on engagement (paused), and on screen-config change.
    private var dwellTasks: [UUID: Task<Void, Never>] = [:]
    /// Cleanup task scheduled after a retraction starts. Re-scheduled
    /// per retraction; tracked here only so `screenConfigurationDidChange`
    /// can cancel an in-flight teardown.
    private var cleanupTask: Task<Void, Never>?
    /// Slide-in task scheduled when the pill is going from hidden to
    /// visible. Used to distinguish "genuine mid-slide-in" (where
    /// `midSlide` should silently queue) from "mid-teardown that was
    /// cancelled" (where the new arrival should publish + start now).
    private var slideInTask: Task<Void, Never>?
    /// Teardown task scheduled after the last slot retracts so the pill
    /// can finish its slide-up before `orderOut` fires. Tracked so a
    /// fresh arrival can cancel it mid-teardown.
    private var teardownTask: Task<Void, Never>?
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

        // Build a placeholder typed view first; we rebind with closures
        // that capture self once init completes (closures can't reference
        // self before all stored properties are initialized).
        hosting = FirstMouseHosting(
            rootView: NotchPillView(
                model: model,
                onClick: { _ in },
                onRowClick: { _ in },
                onChipClick: { _ in }
            )
        )
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // Bind the unified pill view to the model exactly once.
        // Subsequent updates flow via @Published mutations on `model`.
        hosting.rootView = NotchPillView(
            model: model,
            onClick: { [weak self] n in self?.handleClick(n) },
            onRowClick: { [weak self] n in self?.handleRowClick(n) },
            onChipClick: { [weak self] chipstackID in self?.handleChipClick(chipstackID) },
            onInflightHover: { [weak self] hovering in self?.handleInflightHover(hovering) },
            onEngagementChange: { [weak self] engaged in self?.handleEngagementChange(engaged) }
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
            let chipstackID = chipstackIDFor(message)
            let notification = StoredNotification(message: message, chipstackID: chipstackID)
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

        let chipstackID = chipstackIDFor(message)
        let isNewStack = (chipstacks[chipstackID] == nil)
        let notification = StoredNotification(message: message, chipstackID: chipstackID)
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
            model.chipstacks.isEmpty && model.liveStack.isEmpty && !model.forcedVisible
        // Genuine mid-slide-in: forcedVisible set + stacks empty AND
        // there's an actual slide-in task pending. If slideInTask is
        // nil and we're in this state, we're mid-teardown (or
        // post-cancel teardown) and should fall through to publish
        // + start, NOT silently queue.
        let midSlide = model.forcedVisible && model.chipstacks.isEmpty && slideInTask != nil

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
        // Always queue. If the livestack is empty, drain immediately;
        // otherwise the current livestack row will pick this up when
        // it retracts (same-group → swap in place without tearing
        // the pill down; different-group → existing drain path).
        if model.liveStack.isEmpty {
            startNext(newStack: isNewStack)
        }
    }

    /// Fires once the slide-in animation has played. Publishes every
    /// stack ingested during the slide so the slot transitions begin
    /// (b), then kicks off the first in-flight (c).
    private func completeSlideIn() {
        publishStacks()
        if model.liveStack.isEmpty && !arrivals.isEmpty {
            startNext(newStack: true)
        }
    }

    private func chipstackIDFor(_ message: Message) -> String {
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
        let id = notification.chipstackID
        let isAnon = id.hasPrefix("a:")
        if chipstacks[id] == nil {
            chipstacks[id] = ChipStack(id: id, isAnonymous: isAnon)
            chipstackOrder.append(id)
        }
        let m = notification.message
        var stack = chipstacks[id]!
        if stack.resolvedIcon == nil {
            stack.resolvedIcon = m.icon
        }
        if stack.resolvedColor == nil {
            stack.resolvedColor = m.color
        }
        stack.notifications.insert(notification, at: 0)
        chipstacks[id] = stack
        // Track the latest-ingested stack so the view can expand it
        // when the user hovers a generic (non-chip) part of the pill.
        model.mostRecentChipstackID = id
    }

    private func publishStacks() {
        model.chipstacks = chipstackOrder.compactMap { chipstacks[$0] }
        // Once stacks are non-empty, pillVisible is satisfied by them.
        // Clear forcedVisible so the slide-up logic works naturally
        // when the last stack is later removed.
        if !model.chipstacks.isEmpty {
            model.forcedVisible = false
        }
        updateFocusTimer()
    }

    /// Start/stop the focus poll based on whether any notification in
    /// the current stacks carries a dismissKey. Idempotent.
    private func updateFocusTimer() {
        let needsPoll = chipstacks.values.contains { stack in
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
        for chipstackID in chipstackOrder {
            guard let stack = chipstacks[chipstackID] else { continue }
            for n in stack.notifications {
                if let key = n.message.dismissKey,
                   FocusDetector.matches(key, bundle: bundle, activePanesProvider: provider) {
                    toDismiss.append(n)
                }
            }
        }
        guard !toDismiss.isEmpty else { return }

        for n in toDismiss {
            if model.liveStack.contains(where: { $0.id == n.id }) {
                // Remove from stack first so cleanup's removeNotification
                // is a no-op; then play the live-row retract.
                removeNotification(n)
                beginRetraction(of: n, viaClick: true)
            } else {
                removeNotification(n)
            }
        }
        publishStacks()
        if chipstacks.isEmpty && model.liveStack.isEmpty {
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
        guard model.liveStack.isEmpty else { return }
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
            self.model.liveStack = [next]
            self.scheduleDwell(for: next)
        }
    }

    private func scheduleDwell(for n: StoredNotification) {
        dwellTasks[n.id]?.cancel()
        // Persistent rows still get a brief visible-body window, then
        // collapse out of the live stack while remaining in the chip
        // stack until the user clicks them.
        let dwell: TimeInterval = isPersistent(n) ? 4.0 : (n.message.timeout ?? 5.0)
        dwellTasks[n.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            self?.beginRetraction(of: n, viaClick: false)
        }
    }

    private func cancelAllDwells() {
        for (_, t) in dwellTasks { t.cancel() }
        dwellTasks.removeAll()
    }

    private func handleClick(_ n: StoredNotification) {
        runAction(n.message.action)
        beginRetraction(of: n, viaClick: true)
    }

    /// Engagement transitions. Hover on the pill pauses every live
    /// row's dwell so the user can read; un-hover restarts each
    /// remaining row's dwell from full duration. While engaged, new
    /// arrivals are queued silently; on disengage, queued arrivals
    /// resume their normal lifecycle.
    private func handleEngagementChange(_ engaged: Bool) {
        if engaged {
            // Pause every visible row's dwell. They restart from full
            // duration on disengage.
            cancelAllDwells()
            return
        }
        // Disengaged: restart dwells for every live row, then drain
        // any pending arrivals if the live stack is empty.
        for n in model.liveStack {
            scheduleDwell(for: n)
        }
        guard !arrivals.isEmpty, model.liveStack.isEmpty else { return }
        let nextIsNewStack = arrivals.first.map {
            chipstacks[$0.chipstackID]?.notifications.count == 1
        } ?? false
        startNext(newStack: nextIsNewStack)
    }

    /// Legacy callback retained for the view's onInflightHover plumbing;
    /// now a no-op because pause-on-hover is driven by the engagement
    /// gate (handlePillHover → handleEngagementChange).
    private func handleInflightHover(_ hovering: Bool) {}

    /// Click on a chip slot. Dismisses the topmost (newest)
    /// notification in that stack — repeated clicks dismiss
    /// successively older ones, top-to-bottom. Runs the row's
    /// action if any. If the top is also live, retract that row
    /// out of the live stack (which itself triggers pill teardown
    /// only when the live stack is now empty).
    private func handleChipClick(_ chipstackID: String) {
        guard let top = chipstacks[chipstackID]?.notifications.first else { return }
        runAction(top.message.action)
        if model.liveStack.contains(where: { $0.id == top.id }) {
            beginRetraction(of: top, viaClick: true)
            return
        }
        // Hold the pill visible across the slot retract (e) so it
        // doesn't immediately slide up when stacks empties under us.
        // Without this, pillVisible flips false at publishStacks
        // time and the pill races up while the slot is still
        // animating out.
        let willEmptyEverything = (chipstacks.count == 1)
            && (chipstacks[chipstackID]?.notifications.count ?? 0) <= 1
            && model.liveStack.isEmpty
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
        let willEmptyEverything = (chipstacks.count == 1)
            && (chipstacks[n.chipstackID]?.notifications.count ?? 0) <= 1
            && model.liveStack.isEmpty
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

    /// Retract a single live row. If other rows remain in the live
    /// stack, the pill simply shrinks to fit them and we're done. If
    /// this was the last live row, fall into the full pill teardown
    /// path (drain queue or schedule slide-up).
    private func beginRetraction(of n: StoredNotification, viaClick: Bool) {
        guard model.liveStack.contains(where: { $0.id == n.id }) else { return }
        dwellTasks[n.id]?.cancel()
        dwellTasks.removeValue(forKey: n.id)

        let willRemoveFromChipStack = viaClick || !isPersistent(n)
        // Pop the row from the live stack immediately so the view
        // animates its disappearance; the chip-stack mutation (if
        // any) waits until after the body fade so it doesn't race.
        model.liveStack.removeAll { $0.id == n.id }

        // Other rows still in the live stack: pill stays open. No
        // teardown, no inRetraction (the rest are still "in flight").
        if !model.liveStack.isEmpty {
            if willRemoveFromChipStack {
                removeNotification(n)
                publishStacks()
            }
            return
        }

        // Same-chipstack fast-path: if the next queued arrival
        // belongs to the same chipstack as the one just retracted,
        // swap it directly into the livestack. The pill keeps its
        // drop height and chip slot; the body cross-fades. Skipped
        // while the user is engaged (drain happens on disengage).
        if let next = arrivals.first,
           next.chipstackID == n.chipstackID,
           !model.isUserEngaged {
            if willRemoveFromChipStack {
                removeNotification(n)
                publishStacks()
            }
            arrivals.removeFirst()
            Sound.play(next.message.sound)
            model.liveStack = [next]
            scheduleDwell(for: next)
            return
        }

        // Live stack just emptied — full retraction path.
        model.inRetraction = true
        cleanupTask?.cancel()
        cleanupTask = Task { @MainActor [weak self] in
            // Wait for body fade-out + pillHeight retract to play
            // before the next phase (slot retract / startNext).
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }

            let willEmptyEverything = willRemoveFromChipStack
                && (self.chipstacks.count == 1)
                && (self.chipstacks[n.chipstackID]?.notifications.count ?? 0) <= 1
                && self.arrivals.isEmpty

            if willEmptyEverything {
                // Hold pill visible for the slot retract (e), then
                // schedule the slide-up (f) afterward.
                self.model.forcedVisible = true
            }

            if willRemoveFromChipStack {
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
                        self.chipstacks[$0.chipstackID]?.notifications.count == 1
                    } ?? false
                    self.startNext(newStack: nextIsNewStack)
                    return
                }
            }

            if self.chipstacks.isEmpty {
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
            if self.chipstacks.isEmpty && self.model.liveStack.isEmpty {
                self.panel.orderOut(nil)
            }
            self.model.inRetraction = false
            self.teardownTask = nil
        }
    }

    private func isPersistent(_ n: StoredNotification) -> Bool {
        if let t = n.message.timeout, t == 0 { return true }
        return false
    }

    private func removeNotification(_ n: StoredNotification) {
        guard var stack = chipstacks[n.chipstackID] else { return }
        stack.notifications.removeAll { $0.id == n.id }
        if stack.notifications.isEmpty {
            chipstacks.removeValue(forKey: n.chipstackID)
            chipstackOrder.removeAll { $0 == n.chipstackID }
        } else {
            chipstacks[n.chipstackID] = stack
        }
    }

    func screenConfigurationDidChange() {
        guard !model.liveStack.isEmpty else { return }
        cleanupTask?.cancel()
        cancelAllDwells()
        // Re-queue every live row in arrival order (oldest first) so
        // they replay on the new geometry. liveStack is newest-first
        // so we reverse before prepending.
        let toReplay = Array(model.liveStack.reversed())
        model.liveStack.removeAll()
        arrivals.insert(contentsOf: toReplay, at: 0)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.ensurePanelOnScreen()
            let isNew = self.arrivals.first.map {
                self.chipstacks[$0.chipstackID]?.notifications.count == 1
            } ?? false
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
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", action]
        do {
            try task.run()
        } catch {
            NSLog("%@", "notchify: action failed: \(error.localizedDescription)")
        }
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

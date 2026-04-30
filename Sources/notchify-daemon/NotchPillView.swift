import SwiftUI

/// One unified black pill that contains the notch on the right and a
/// shelf of group slots on the left. The pill morphs in size:
///
/// - Hidden:           pill is off-screen (no active groups, no in-flight).
/// - Chip row:         pill at notch height, one slot per active group.
/// - Expanded:         same shelf, but height drops down to show either
///                     the in-flight notification's title/body, or
///                     (when the user hovers a slot) the hovered
///                     stack's full row list.
///
/// Width grows by one slot when a new group's first notification
/// arrives; shrinks when a group's last row is dismissed. Height
/// drops while a notification is in flight, or while the user hovers
/// a slot, and retracts back when both conditions clear. The
/// retraction *stops* at chip-row height as long as any slots remain;
/// only when the last slot is gone does the pill slide back up
/// off-screen.
@MainActor
struct NotchPillView: View {
    @ObservedObject var model: NotchModel
    var onClick: (StoredNotification) -> Void
    var onRowClick: (StoredNotification) -> Void
    var onChipClick: (String) -> Void
    var onInflightHover: (Bool) -> Void = { _ in }
    var onEngagementChange: (Bool) -> Void = { _ in }

    /// Drop-down height for in-flight bodies that fit on one body
    /// line. Two-line bodies get `extraHeightTwoLine` instead so the
    /// pill grows just enough to fit; bodies past two lines
    /// ellipsize via `.lineLimit(2)`.
    static let extraHeight: CGFloat = 40
    static let extraHeightTwoLine: CGFloat = 54
    static let slotWidth: CGFloat = 28
    static let slotSpacing: CGFloat = 4
    /// Shelf paddings tuned so the total shelf width = 31pt (matches
    /// origin/main's leftExtra). The icon inside a centered 28pt
    /// slot lands at slot.leading + 7, so shelfPaddingLeft = 2
    /// places the icon's leftmost pixel at pill.leading + 9 —
    /// matching the body text's padding (also 9 below).
    static let shelfPaddingLeft: CGFloat = 2
    static let shelfPaddingRight: CGFloat = 1
    static let rowHeight: CGFloat = 40
    static let listVerticalPadding: CGFloat = 8
    /// Maximum number of chip slots rendered fully. Beyond this, the
    /// next-oldest stack is rendered as a "partial" slot at the
    /// leftmost edge with a fade gradient; older ones aren't shown
    /// (their notifications still exist in the stack).
    static let maxVisibleSlots: Int = 2
    /// Hover lists cap at ~3.5 rows tall: 3 fully visible + half a
    /// row peeking below the bottom fade so it's clear there's more
    /// to scroll. Past that, content scrolls inside.
    static let maxListHeight: CGFloat = 3.5 * rowHeight + listVerticalPadding * 2
    /// How far the slot icon is offset to the right during its
    /// transition active state. Big enough that the icon sits past
    /// the shelf's trailing edge (i.e. inside the notch area), where
    /// it gets clipped and reads as "hidden behind the notch".
    static let slotSlideDistance: CGFloat = slotWidth + slotSpacing + shelfPaddingRight + 8

    @State private var hoveredStackID: String? = nil
    @State private var textVisible: Bool = false
    /// View-side mirror of model.inflight that LINGERS during fade-out.
    /// model.inflight is the truth for the controller's lifecycle
    /// (dwell, click, etc.); displayedInflight is what the view
    /// renders, kept around long enough for the text fade-out to
    /// complete before the button unmounts.
    @State private var displayedInflight: StoredNotification? = nil
    /// True while the cursor is anywhere over the pill (used to
    /// expand the most-recent stack when the cursor is on a generic
    /// part of the pill rather than a specific slot).
    @State private var pillHovered: Bool = false
    /// Debounces hover-clear so the cursor can travel between a slot
    /// and the list area below it without flickering the pill closed.
    @State private var hoverClearTask: Task<Void, Never>? = nil
    /// Scroll offset of the hover list, used to hide the top fade
    /// when the user is at the top of the list.
    @State private var listScrollOffset: CGFloat = 0

    var body: some View {
        let stacks = model.stacks
        let notchSize = model.notchSize

        // Cap visible slots at maxVisibleSlots; if there are more
        // groups than that, render one extra "partial" slot on the
        // leftmost edge with a fade-out gradient. Older stacks
        // beyond that aren't rendered (their data is still in
        // model.stacks; only the chip is hidden).
        let total = stacks.count
        let hasPartialSlot = total > Self.maxVisibleSlots
        let visibleStacks = Array(
            stacks.suffix(Self.maxVisibleSlots + (hasPartialSlot ? 1 : 0))
        )
        let partialSlotID: String? = hasPartialSlot ? visibleStacks.first?.id : nil
        let shelfWidth = NotchPillView.shelfWidthFor(slotCount: visibleStacks.count)
        let pillWidth = notchSize.width + shelfWidth
        let isInflight = (model.inflight != nil)

        // Explicit slot hover always wins (even during in-flight,
        // so the user can switch to viewing another stack while a
        // notification is showing). The most-recent fallback only
        // fires when no in-flight is taking the drop area, so we
        // don't auto-overlay a list on top of the in-flight body.
        let effectiveHoveredID: String? = {
            // Suppress hover-driven rendering for the entire
            // retraction window (controller-managed). Without this,
            // between body fade-out and pill teardown the
            // pillHovered → mostRecentStackID fallback would render
            // the just-dismissed notification as a hover-list row.
            guard !model.inRetraction else { return nil }

            if let id = hoveredStackID {
                // Don't expand the in-flight's own slot when its
                // stack has nothing extra to show. Hovering the
                // chip in that case would just re-render the same
                // notification as a list row, which is redundant.
                // We still expand for: same stack with multiple
                // rows, or a different group's slot.
                if let inflight = model.inflight, inflight.stackID == id,
                   let stack = stacks.first(where: { $0.id == id }),
                   stack.notifications.count <= 1 {
                    return nil
                }
                return id
            }
            guard !isInflight else { return nil }
            guard !stacks.isEmpty else { return nil }
            if pillHovered, let recent = model.mostRecentStackID,
               stacks.contains(where: { $0.id == recent }) {
                return recent
            }
            return nil
        }()
        let hoveredStack: NotificationStack? = effectiveHoveredID.flatMap { id in
            stacks.first { $0.id == id }
        }
        let hoverDropHeight: CGFloat = {
            guard let hs = hoveredStack else { return 0 }
            let raw = CGFloat(hs.notifications.count) * Self.rowHeight + Self.listVerticalPadding * 2
            return min(raw, Self.maxListHeight)
        }()
        let inflightDropHeight: CGFloat = {
            guard let inflight = model.inflight else { return 0 }
            // Measure the body to decide between one-line and
            // two-line drop heights. Use NSAttributedString rather
            // than SwiftUI measurements so the height is known up
            // front (animation needs the target value at the start).
            let body = inflight.message.text ?? ""
            if body.isEmpty { return Self.extraHeight }
            let font = NSFont.systemFont(ofSize: 11)
            let availableWidth = max(notchSize.width - 20, 100)
            let attr = NSAttributedString(string: body, attributes: [.font: font])
            let rect = attr.boundingRect(
                with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let oneLineHeight = font.boundingRectForFont.height
            let needsTwoLines = rect.height > oneLineHeight + 1
            return needsTwoLines ? Self.extraHeightTwoLine : Self.extraHeight
        }()
        // Drop area is the larger of (in-flight body height, hover
        // list height). When the user hovers a chip during in-flight,
        // the body is hidden but the pill grows to fit the list.
        let dropHeight = max(inflightDropHeight, hoverDropHeight)
        let pillHeight = notchSize.height + dropHeight
        let pillVisible = !stacks.isEmpty || isInflight || model.forcedVisible
        // Generous off-screen runway so the slide feels substantial,
        // independent of how tall the pill happens to be at slide
        // time. Without this, a hidden→chip-row slide travels only
        // ~48pt and reads as abrupt.
        let slideOffset: CGFloat = pillVisible
            ? 0
            : -(notchSize.height + Self.extraHeight + 4)

        ZStack(alignment: .topTrailing) {
            // Pill background. The notch's top corners stay square
            // (they hug the screen edge); only the bottom corners
            // are rounded, so the shelf inherits the same shape.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 9,
                topTrailingRadius: 0
            )
            .fill(Color.black)
            .frame(width: pillWidth, height: pillHeight)

            // Slot row pinned to the top-left of the pill.
            HStack(spacing: Self.slotSpacing) {
                ForEach(visibleStacks, id: \.id) { stack in
                    let isPartial = (stack.id == partialSlotID)
                    let isExpandedStack = (stack.id == effectiveHoveredID)
                    SlotIconView(
                        stack: stack,
                        notchHeight: notchSize.height,
                        isExpanded: isExpandedStack
                    )
                        .frame(width: Self.slotWidth, height: notchSize.height)
                        // Partial slot: just dim it. Using a gradient
                        // mask used to make the chip switch into a
                        // different mask shape when overflow appears,
                        // which SwiftUI animated as a layout flash.
                        // Simple opacity transitions cleanly.
                        .opacity(isPartial ? 0.4 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { onChipClick(stack.id) }
                        .onHover { hovering in handleHover(stackID: stack.id, hovering: hovering) }
                        // The slot starts and ends offset to the right
                        // (inside the notch's bounds, where it's
                        // clipped by the shelf frame below). On
                        // insertion it slides leftward into its slot;
                        // on removal it slides rightward back behind
                        // the notch.
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeIn(duration: 0.12)),
                                // Removal: plain opacity fade. The
                                // icon stays put and just fades, then
                                // the shelf width animates back to 0
                                // (clipping whatever's left). Matches
                                // origin/main's "icon out, then
                                // shelf retract" feel.
                                removal: .opacity.animation(.easeOut(duration: 0.13))
                            )
                        )
                }
            }
            .padding(.trailing, Self.shelfPaddingRight)
            // Clip to the shelf bounds. Anything in the notch area
            // (where the slot starts during the slide-in) is hidden,
            // matching "icon hidden behind the notch" → "icon slides
            // out as the shelf opens".
            .frame(width: shelfWidth, height: notchSize.height, alignment: .trailing)
            .clipped()
            .frame(width: pillWidth, height: pillHeight, alignment: .topLeading)

            // In-flight title/body in the dropped-down area.
            // Suppressed when a chip is explicitly hovered: the hover
            // list takes over the drop area instead. Without this
            // they'd render simultaneously and overlap.
            if let n = displayedInflight, hoveredStack == nil {
                Button(action: { onClick(n) }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.message.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let body = n.message.text, !body.isEmpty {
                            Text(body)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.top, 1)
                    .padding(.bottom, 4)
                    .frame(width: pillWidth, height: inflightDropHeight, alignment: .topLeading)
                    .opacity(textVisible ? 1 : 0)
                    // Inside the Button label so the whole body
                    // rectangle is tappable, not just the text glyphs.
                    .contentShape(Rectangle())
                }
                .buttonStyle(NoFeedbackButtonStyle())
                .onHover { hovering in onInflightHover(hovering) }
                .accessibilityLabel(n.message.action == nil ? "Dismiss notification" : "Open notification")
                .frame(width: pillWidth, height: pillHeight, alignment: .bottomLeading)
            }

            // Hover-expanded list rendered inside the pill below the
            // slot row. Pill grows to fit up to maxListHeight; past
            // that, the rows scroll inside.
            if let hs = hoveredStack {
                let totalContent = CGFloat(hs.notifications.count) * Self.rowHeight
                    + Self.listVerticalPadding * 2
                let needsScroll = totalContent > Self.maxListHeight
                let maxScroll = max(totalContent - Self.maxListHeight, 0)
                // Top/bottom fades only apply when there's actually
                // content past the corresponding edge of the visible
                // window. At the very top there's nothing above; at
                // the very bottom there's nothing below.
                let topFadeActive = needsScroll && listScrollOffset > 1
                let bottomFadeActive = needsScroll && listScrollOffset < maxScroll - 1

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(hs.notifications) { n in
                            RowView(
                                notification: n,
                                fallbackIcon: hs.resolvedIcon,
                                fallbackColor: hs.resolvedColor,
                                onClick: { onRowClick(n) }
                            )
                            .frame(height: Self.rowHeight)
                        }
                    }
                    .padding(.vertical, Self.listVerticalPadding)
                    // Pin content width to the pill so it doesn't
                    // shift when the ScrollView is widened below to
                    // hide the scrollbar.
                    .frame(width: pillWidth)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ListScrollOffsetKey.self,
                                value: -geo.frame(in: .named("hoverList")).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "hoverList")
                .onPreferenceChange(ListScrollOffsetKey.self) { newOffset in
                    listScrollOffset = newOffset
                }
                .scrollIndicators(.hidden)
                // Render the ScrollView wider than the visible area
                // so the AppKit-backed scrollbar lives past
                // pillWidth, then clip back to pillWidth so it
                // disappears off the right edge. Pure SwiftUI
                // .scrollIndicators(.hidden) is unreliable on
                // macOS 13's ScrollView.
                .frame(width: pillWidth + 16, height: hoverDropHeight, alignment: .leading)
                .frame(width: pillWidth, height: hoverDropHeight, alignment: .leading)
                .clipped()
                // Top + bottom fade so rows visibly soften as they
                // approach the edge of the visible window. Top fade
                // only applies when actually scrolled past the top.
                .mask(
                    needsScroll
                        ? AnyView(LinearGradient(
                            stops: [
                                .init(color: topFadeActive ? .clear : .black, location: 0),
                                .init(color: .black, location: 0.2),
                                .init(color: .black, location: 0.8),
                                .init(color: bottomFadeActive ? .clear : .black, location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        : AnyView(Rectangle())
                )
                .frame(width: pillWidth, height: hoverDropHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .onHover { hovering in handleHover(stackID: hs.id, hovering: hovering) }
                // Position the list at the bottom of the pill via an
                // outer frame *after* contentShape, so hit-testing
                // only covers the list's own height, not the chip
                // row above it. Without this, the hover-list overlay
                // ate clicks meant for the chip slots.
                .frame(width: pillWidth, height: pillHeight, alignment: .bottomLeading)
                // Force a remount when the hovered stack changes so
                // moving between chips actually animates A out and B
                // in, instead of silently swapping content in place.
                .id(hs.id)
                // Plain opacity transition so hover-show feels
                // consistent with the in-flight body fade-in/out
                // (which is also opacity-driven). Scale-from-top
                // gave it a different "personality" from the
                // standard notification animation.
                .transition(.opacity)
            }
        }
        .frame(width: pillWidth, height: pillHeight)
        // Clip the entire pill to its current bounds so body text or
        // hover-list content can't paint outside the pill rectangle
        // during retraction (e.g., as pillHeight shrinks 88→40, the
        // body content that was at the bottom must not bleed past
        // the new height).
        .clipped()
        .offset(y: slideOffset)
        .animation(.easeOut(duration: 0.22), value: pillVisible)
        .animation(.easeOut(duration: 0.2), value: stacks.count)
        .animation(.easeOut(duration: 0.15), value: pillHeight)
        .animation(.easeOut(duration: 0.18), value: hoveredStackID)
        .onHover { hovering in
            pillHovered = hovering
            // Drive the model's engagement flag directly from the
            // outer hover. pillHovered subsumes any specific
            // hover (slot or in-flight body), so this is enough.
            let wasEngaged = model.isUserEngaged
            model.isUserEngaged = hovering
            if hovering && !wasEngaged {
                onEngagementChange(true)
            } else if !hovering && wasEngaged {
                onEngagementChange(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // If the stack we're hovering disappears (user dismissed
        // all its rows), clear the hover so a later re-creation of
        // a stack with the same id doesn't auto-expand and bypass
        // the normal arrival animation.
        .onChange(of: model.stacks.map(\.id)) { newIDs in
            if let id = hoveredStackID, !newIDs.contains(id) {
                hoveredStackID = nil
            }
        }
        // When the pill is no longer visible (panel sliding up /
        // hidden), clear all hover state. SwiftUI doesn't always
        // synthesize a hover-out event when a window is hidden, so
        // pillHovered/hoveredStackID can linger true across hide/
        // show cycles — which makes the expanded list pop up
        // immediately when a new arrival re-shows the pill.
        .onChange(of: pillVisible) { newVisible in
            if !newVisible {
                hoveredStackID = nil
                pillHovered = false
                model.isUserEngaged = false
            }
        }
        .onChange(of: model.inflight?.id) { newID in
            if let next = model.inflight {
                // Appearance: sync displayedInflight to model and
                // schedule the staggered fade-in.
                displayedInflight = next
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    withAnimation(.easeIn(duration: 0.18)) { textVisible = true }
                }
            } else {
                // Retraction: keep displayedInflight rendered while
                // the text fades out, then unmount. Text fade is
                // shorter than the pillHeight retract (0.15s) so
                // body is gone before the pill has visibly shrunk.
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.1)) { textVisible = false }
                    try? await Task.sleep(for: .milliseconds(120))
                    displayedInflight = nil
                }
            }
        }
    }

    /// Hover handling shared by the slot icon and the list area:
    /// entering either keeps the same stack expanded; leaving either
    /// schedules a brief debounced clear so the cursor can travel
    /// between them without flicker.
    private func handleHover(stackID: String, hovering: Bool) {
        hoverClearTask?.cancel()
        if hovering {
            hoveredStackID = stackID
        } else {
            hoverClearTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                if hoveredStackID == stackID {
                    hoveredStackID = nil
                }
            }
        }
    }

    /// Total horizontal room reserved for the shelf (excluding the
    /// notch itself). Public so the controller can ask the same
    /// question when sizing the panel.
    static func shelfWidthFor(slotCount: Int) -> CGFloat {
        guard slotCount > 0 else { return 0 }
        let icons = CGFloat(slotCount) * slotWidth
        let gaps = CGFloat(max(slotCount - 1, 0)) * slotSpacing
        return icons + gaps + shelfPaddingLeft + shelfPaddingRight
    }

    /// Map a string name to a SwiftUI Color. Shared by the slot
    /// renderer and the row renderer so the chip color and the
    /// row-icon color come from the same vocabulary.
    static func color(named name: String?) -> Color? {
        switch name?.lowercased() {
        case "orange": return .orange
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "white": return .white
        case "gray", "grey": return .gray
        default: return nil
        }
    }
}

/// Preference key carrying the hover list's scroll offset (in
/// points, top-of-content relative to the ScrollView's top). Read
/// via a GeometryReader inside the ScrollView's content.
struct ListScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Transition modifier used for slot insertion/removal. The "active"
/// state offsets the icon to the right, putting it inside the notch
/// area where the parent's `.clipped()` shelf frame hides it. The
/// "identity" state has zero offset, leaving the icon at its slot
/// position. Insertion animates active → identity (slide leftward
/// from behind the notch); removal animates identity → active (slide
/// rightward back behind the notch).
struct SlotSlideModifier: ViewModifier {
    let offsetX: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: offsetX)
    }
}

/// One slot icon inside the shelf. No background of its own — it
/// paints over the unified pill's black fill. When `isExpanded` is
/// true (the stack's list is currently dropped down), a small
/// chevron-down sits beneath the icon as a visual cue.
struct SlotIconView: View {
    let stack: NotificationStack
    let notchHeight: CGFloat
    var isExpanded: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Icon centered in the slot; chevron is positioned via
            // offset so adding/removing it doesn't shift the icon
            // off-center.
            Image(systemName: stack.resolvedIcon ?? "bell.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(NotchPillView.color(named: stack.resolvedColor) ?? .white)
                .frame(width: 14, height: 14)
                .frame(width: NotchPillView.slotWidth, height: notchHeight)

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
                .opacity(isExpanded ? 1 : 0)
                .frame(width: NotchPillView.slotWidth, height: notchHeight, alignment: .bottom)
                .padding(.bottom, 2)

            if stack.notifications.count > 1 {
                Text("\(stack.notifications.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .offset(x: -3, y: 4)
            }
        }
        .frame(width: NotchPillView.slotWidth, height: notchHeight)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }
}

/// One row inside the hover-expanded list: icon + title + (optional)
/// body. The row's icon falls back to the stack's resolved icon when
/// the notification didn't supply its own.
struct RowView: View {
    let notification: StoredNotification
    /// Kept for API compatibility but no longer rendered: rows used
    /// to show their own icon, but we now identify rows by their
    /// stack's slot icon (with a chevron when the stack is expanded).
    let fallbackIcon: String?
    let fallbackColor: String?
    var onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 1) {
                Text(notification.message.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let body = notification.message.text, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoFeedbackButtonStyle())
        .accessibilityLabel(notification.message.action == nil ? "Dismiss \(notification.message.title)" : "Open \(notification.message.title)")
    }
}

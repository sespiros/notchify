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
    /// ellipsize via `.lineLimit(2)`. Title-only notifications drop
    /// by exactly the notch height (computed at measure time), so
    /// the pill becomes a 2x-notch box with the title centered in
    /// the lower half.
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

    @State private var hoveredChipstackID: String? = nil
    @State private var textVisible: Bool = false
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
    /// Cached drop height keyed by inflight id. Avoids running the
    /// NSAttributedString boundingRect call on every body re-render.
    @State private var inflightDropCache: (id: UUID, height: CGFloat)? = nil
    /// Live mirror of the chip shelf's clip-view bounds.origin.x.
    /// Drives the leading-edge fade.
    @State private var shelfScrollOffset: CGFloat = 0
    /// Live mirror of the chip shelf's document width. Combined
    /// with the viewport width and offset, drives the trailing-edge
    /// fade.
    @State private var shelfContentWidth: CGFloat = 0

    var body: some View {
        let stacks = model.chipstacks
        let notchSize = model.notchSize

        let total = stacks.count
        // Shelf viewport: grows linearly up to maxVisibleSlots, then
        // caps at "2 chips fully + a half-slot peek" past that. The
        // trailing fade gradient then covers the peeking chip so it
        // looks semi-faded, indicating "more chips beyond." This way
        // a new chip arriving while a body is active doesn't trigger
        // a fresh layout slide as the pill keeps growing.
        let shelfWidth: CGFloat = {
            if total <= Self.maxVisibleSlots {
                return Self.shelfWidthFor(slotCount: total)
            }
            return Self.shelfWidthFor(slotCount: Self.maxVisibleSlots)
                + Self.slotSpacing + Self.slotWidth / 2
        }()
        let pillWidth = notchSize.width + shelfWidth
        let hasOverflow = total > Self.maxVisibleSlots
        let liveStack = model.liveStack
        let isInflight = !liveStack.isEmpty

        let effectiveHoveredID = computeEffectiveHoveredID(stacks: stacks, isInflight: isInflight)
        let hoveredStack: ChipStack? = effectiveHoveredID.flatMap { id in
            stacks.first { $0.id == id }
        }
        let hoverDropHeight: CGFloat = {
            guard let hs = hoveredStack else { return 0 }
            let raw = CGFloat(hs.notifications.count) * Self.rowHeight + Self.listVerticalPadding * 2
            return min(raw, Self.maxListHeight)
        }()
        let inflightDropHeight = currentInflightDropHeight(notchSize: notchSize)
        let dropHeight = max(inflightDropHeight, hoverDropHeight)
        let pillHeight = notchSize.height + dropHeight
        let pillVisible = !stacks.isEmpty || isInflight || model.forcedVisible
        let slideOffset: CGFloat = pillVisible
            ? 0
            : -(notchSize.height + Self.extraHeight + 4)

        ZStack(alignment: .topTrailing) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 9,
                topTrailingRadius: 0
            )
            .fill(Color.black)
            .frame(width: pillWidth, height: pillHeight)

            slotShelf(
                chipstacks: stacks,
                effectiveHoveredID: effectiveHoveredID,
                liveActiveID: stacks.count >= 2 ? liveStack.first?.chipstackID : nil,
                hasOverflow: hasOverflow,
                notchSize: notchSize,
                shelfWidth: shelfWidth,
                pillWidth: pillWidth,
                pillHeight: pillHeight
            )

            if hoveredStack == nil {
                liveStackView(
                    liveStack: liveStack,
                    pillWidth: pillWidth,
                    pillHeight: pillHeight,
                    inflightDropHeight: inflightDropHeight,
                    notchHeight: notchSize.height
                )
            }


            if let hs = hoveredStack {
                HoverListView(
                    stack: hs,
                    pillWidth: pillWidth,
                    pillHeight: pillHeight,
                    hoverDropHeight: hoverDropHeight,
                    listScrollOffset: $listScrollOffset,
                    onRowClick: onRowClick,
                    onHover: handleHover
                )
                .id(hs.id)
                .transition(.opacity)
            }
        }
        .frame(width: pillWidth, height: pillHeight)
        .clipped()
        .offset(y: slideOffset)
        .animation(.easeOut(duration: 0.22), value: pillVisible)
        .animation(.easeOut(duration: 0.2), value: stacks.count)
        .animation(.easeOut(duration: 0.15), value: pillHeight)
        .animation(.easeOut(duration: 0.18), value: hoveredChipstackID)
        .animation(.easeOut(duration: 0.2), value: liveStack.first?.chipstackID)
        .animation(.easeInOut(duration: 0.28), value: liveStack.first?.id)
        .onHover { hovering in handlePillHover(hovering) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onChange(of: model.chipstacks.map(\.id)) { newIDs in
            if let id = hoveredChipstackID, !newIDs.contains(id) {
                hoveredChipstackID = nil
            }
        }
        .onChange(of: pillVisible) { newVisible in
            if !newVisible {
                hoveredChipstackID = nil
                pillHovered = false
                model.isUserEngaged = false
            }
        }
        .onChange(of: model.liveStack.first?.id) { _ in handleInflightChange() }
    }

    /// Render the topmost livestack row in the pill drop area.
    /// Successive arrivals from the same chipstack are swapped in
    /// place by the controller (no notch retract); the `.id` swap
    /// lets SwiftUI cross-fade the body content.
    @ViewBuilder
    private func liveStackView(
        liveStack: [StoredNotification],
        pillWidth: CGFloat,
        pillHeight: CGFloat,
        inflightDropHeight: CGFloat,
        notchHeight: CGFloat
    ) -> some View {
        if let top = liveStack.first {
            InflightBodyView(
                notification: top,
                pillWidth: pillWidth,
                pillHeight: pillHeight,
                inflightDropHeight: inflightDropHeight,
                textVisible: textVisible,
                onClick: onClick,
                onHover: onInflightHover
            )
            .id(top.id)
            // Outgoing body fades + slides up; incoming body fades
            // in + slides down (enters from above its final spot).
            .transition(.opacity.combined(with: .offset(y: -10)))
        }
    }

    @ViewBuilder
    private func slotShelf(
        chipstacks: [ChipStack],
        effectiveHoveredID: String?,
        liveActiveID: String?,
        hasOverflow: Bool,
        notchSize: CGSize,
        shelfWidth: CGFloat,
        pillWidth: CGFloat,
        pillHeight: CGFloat
    ) -> some View {
        let leadingFadeActive = shelfScrollOffset > 1
        let maxScrollX = max(0, shelfContentWidth - shelfWidth)
        let trailingFadeActive = shelfScrollOffset < maxScrollX - 1
        let scrollTargetX: CGFloat? = {
            // Only auto-scroll when there's a currently-active body.
            // If the livestack is empty (e.g., between same-group
            // body swaps, or between queued different-group
            // drains), leaving the shelf where it is avoids a
            // jarring zig back to a fallback target like "newest"
            // and then forward again to the next active.
            guard let id = liveActiveID,
                  let idx = chipstacks.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            // Center the active chip in the viewport so it lands
            // outside both fade gradients. Clamping in the
            // representable handles the corner cases (first chip
            // pinned at leading, last chip pinned at trailing),
            // where the "in-the-corner" fade going clear is
            // expected.
            let chipCenter = Self.shelfPaddingLeft
                + CGFloat(idx) * (Self.slotWidth + Self.slotSpacing)
                + Self.slotWidth / 2
            return chipCenter - shelfWidth / 2
        }()
        HorizontalChipScroll(
            viewportWidth: shelfWidth,
            viewportHeight: notchSize.height,
            scrollTargetX: scrollTargetX,
            scrollOffset: $shelfScrollOffset,
            contentWidth: $shelfContentWidth
        ) {
            HStack(spacing: Self.slotSpacing) {
                ForEach(chipstacks) { stack in
                    let isExpandedStack = (stack.id == effectiveHoveredID)
                    let isLiveActive = (stack.id == liveActiveID)
                    SlotIconView(
                        stack: stack,
                        notchHeight: notchSize.height,
                        isExpanded: isExpandedStack,
                        isLiveActive: isLiveActive
                    )
                        .frame(width: Self.slotWidth, height: notchSize.height)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Show \(stack.id) notifications")
                        .onTapGesture { onChipClick(stack.id) }
                        .onHover { hovering in handleHover(stack.id, hovering) }
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeIn(duration: 0.12)),
                                removal: .opacity.animation(.easeOut(duration: 0.13))
                            )
                        )
                }
            }
            .padding(.leading, Self.shelfPaddingLeft)
            .padding(.trailing, Self.shelfPaddingRight)
        }
        .frame(width: shelfWidth, height: notchSize.height)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: leadingFadeActive ? .clear : .black, location: 0),
                    .init(color: .black, location: 0.2),
                    .init(color: .black, location: 0.8),
                    .init(color: trailingFadeActive ? .clear : .black, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .frame(width: pillWidth, height: pillHeight, alignment: .topLeading)
    }

    private func computeEffectiveHoveredID(
        stacks: [ChipStack],
        isInflight: Bool
    ) -> String? {
        guard !model.inRetraction else { return nil }

        if let id = hoveredChipstackID {
            // Suppress hover-list expansion when it would duplicate
            // what's already in the live stack: same group AND every
            // chip-stack row is already visible up there.
            let liveCountForStack = model.liveStack.filter { $0.chipstackID == id }.count
            if let stack = stacks.first(where: { $0.id == id }),
               liveCountForStack > 0,
               stack.notifications.count <= liveCountForStack {
                return nil
            }
            return id
        }
        guard !isInflight else { return nil }
        guard !stacks.isEmpty else { return nil }
        if pillHovered, let recent = model.mostRecentChipstackID,
           stacks.contains(where: { $0.id == recent }) {
            return recent
        }
        return nil
    }

    private func currentInflightDropHeight(notchSize: CGSize) -> CGFloat {
        guard let top = model.liveStack.first else { return 0 }
        if let cached = inflightDropCache, cached.id == top.id {
            return cached.height
        }
        return Self.measureDropHeight(text: top.message.text, notchSize: notchSize)
    }

    private static func measureDropHeight(text: String?, notchSize: CGSize) -> CGFloat {
        let body = text ?? ""
        if body.isEmpty { return notchSize.height }
        let font = NSFont.systemFont(ofSize: 11)
        let availableWidth = max(notchSize.width - 20, 100)
        let attr = NSAttributedString(string: body, attributes: [.font: font])
        let rect = attr.boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let oneLineHeight = font.boundingRectForFont.height
        let needsTwoLines = rect.height > oneLineHeight + 1
        return needsTwoLines ? extraHeightTwoLine : extraHeight
    }

    private func handlePillHover(_ hovering: Bool) {
        pillHovered = hovering
        let wasEngaged = model.isUserEngaged
        model.isUserEngaged = hovering
        if hovering && !wasEngaged {
            onEngagementChange(true)
        } else if !hovering && wasEngaged {
            onEngagementChange(false)
        }
    }

    private func handleInflightChange() {
        if let next = model.liveStack.first {
            let height = Self.measureDropHeight(text: next.message.text, notchSize: model.notchSize)
            inflightDropCache = (next.id, height)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(.easeIn(duration: 0.18)) { textVisible = true }
            }
        } else {
            inflightDropCache = nil
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.1)) { textVisible = false }
            }
        }
    }

    /// Hover handling shared by the slot icon and the list area:
    /// entering either keeps the same stack expanded; leaving either
    /// schedules a brief debounced clear so the cursor can travel
    /// between them without flicker.
    private func handleHover(_ stackID: String, _ hovering: Bool) {
        hoverClearTask?.cancel()
        if hovering {
            hoveredChipstackID = stackID
        } else {
            hoverClearTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                if hoveredChipstackID == stackID {
                    hoveredChipstackID = nil
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

    /// Render an icon spec as an Image. The spec is either an SF
    /// Symbol name (e.g. "bell.fill") or a file path (starts with "/"
    /// or "~"). For SF Symbols, the tint comes from `colorName`; for
    /// image files, color is ignored (the file paints itself).
    @ViewBuilder
    static func iconImage(
        _ spec: String?,
        colorName: String?,
        size: CGFloat
    ) -> some View {
        let resolved = spec ?? "bell.fill"
        if isFilePath(resolved),
           let img = NSImage(contentsOfFile: expandTilde(resolved)) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            let symbol = isFilePath(resolved) ? "bell.fill" : resolved
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color(named: colorName) ?? .white)
                .frame(width: size, height: size)
        }
    }

    private static func isFilePath(_ s: String) -> Bool {
        return s.hasPrefix("/") || s.hasPrefix("~")
    }

    private static func expandTilde(_ s: String) -> String {
        return (s as NSString).expandingTildeInPath
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

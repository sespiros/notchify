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
    /// Cached drop height keyed by inflight id. Avoids running the
    /// NSAttributedString boundingRect call on every body re-render.
    @State private var inflightDropCache: (id: UUID, height: CGFloat)? = nil

    var body: some View {
        let stacks = model.stacks
        let notchSize = model.notchSize

        let total = stacks.count
        let hasPartialSlot = total > Self.maxVisibleSlots
        let visibleStacks = Array(
            stacks.suffix(Self.maxVisibleSlots + (hasPartialSlot ? 1 : 0))
        )
        let partialSlotID: String? = hasPartialSlot ? visibleStacks.first?.id : nil
        let shelfWidth = NotchPillView.shelfWidthFor(slotCount: visibleStacks.count)
        let pillWidth = notchSize.width + shelfWidth
        let isInflight = (model.inflight != nil)

        let effectiveHoveredID = computeEffectiveHoveredID(stacks: stacks, isInflight: isInflight)
        let hoveredStack: NotificationStack? = effectiveHoveredID.flatMap { id in
            stacks.first { $0.id == id }
        }
        let hoverDropHeight: CGFloat = {
            guard let hs = hoveredStack else { return 0 }
            let raw = CGFloat(hs.notifications.count) * Self.rowHeight + Self.listVerticalPadding * 2
            return min(raw, Self.maxListHeight)
        }()
        let inflightDropHeight = currentInflightDropHeight(notchWidth: notchSize.width)
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
                visibleStacks: visibleStacks,
                partialSlotID: partialSlotID,
                effectiveHoveredID: effectiveHoveredID,
                notchSize: notchSize,
                shelfWidth: shelfWidth,
                pillWidth: pillWidth,
                pillHeight: pillHeight
            )

            if let n = displayedInflight, hoveredStack == nil {
                InflightBodyView(
                    notification: n,
                    pillWidth: pillWidth,
                    pillHeight: pillHeight,
                    inflightDropHeight: inflightDropHeight,
                    textVisible: textVisible,
                    onClick: onClick,
                    onHover: onInflightHover
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
        .animation(.easeOut(duration: 0.18), value: hoveredStackID)
        .onHover { hovering in handlePillHover(hovering) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onChange(of: model.stacks.map(\.id)) { newIDs in
            if let id = hoveredStackID, !newIDs.contains(id) {
                hoveredStackID = nil
            }
        }
        .onChange(of: pillVisible) { newVisible in
            if !newVisible {
                hoveredStackID = nil
                pillHovered = false
                model.isUserEngaged = false
            }
        }
        .onChange(of: model.inflight?.id) { _ in handleInflightChange() }
    }

    @ViewBuilder
    private func slotShelf(
        visibleStacks: [NotificationStack],
        partialSlotID: String?,
        effectiveHoveredID: String?,
        notchSize: CGSize,
        shelfWidth: CGFloat,
        pillWidth: CGFloat,
        pillHeight: CGFloat
    ) -> some View {
        HStack(spacing: Self.slotSpacing) {
            ForEach(visibleStacks) { stack in
                let isPartial = (stack.id == partialSlotID)
                let isExpandedStack = (stack.id == effectiveHoveredID)
                SlotIconView(
                    stack: stack,
                    notchHeight: notchSize.height,
                    isExpanded: isExpandedStack
                )
                    .frame(width: Self.slotWidth, height: notchSize.height)
                    .opacity(isPartial ? 0.4 : 1)
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
        .padding(.trailing, Self.shelfPaddingRight)
        .frame(width: shelfWidth, height: notchSize.height, alignment: .trailing)
        .clipped()
        .frame(width: pillWidth, height: pillHeight, alignment: .topLeading)
    }

    private func computeEffectiveHoveredID(
        stacks: [NotificationStack],
        isInflight: Bool
    ) -> String? {
        guard !model.inRetraction else { return nil }

        if let id = hoveredStackID {
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
    }

    private func currentInflightDropHeight(notchWidth: CGFloat) -> CGFloat {
        guard let inflight = model.inflight else { return 0 }
        if let cached = inflightDropCache, cached.id == inflight.id {
            return cached.height
        }
        return Self.measureDropHeight(text: inflight.message.text, notchWidth: notchWidth)
    }

    private static func measureDropHeight(text: String?, notchWidth: CGFloat) -> CGFloat {
        let body = text ?? ""
        if body.isEmpty { return extraHeight }
        let font = NSFont.systemFont(ofSize: 11)
        let availableWidth = max(notchWidth - 20, 100)
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
        if let next = model.inflight {
            displayedInflight = next
            let height = Self.measureDropHeight(text: next.message.text, notchWidth: model.notchSize.width)
            inflightDropCache = (next.id, height)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(.easeIn(duration: 0.18)) { textVisible = true }
            }
        } else {
            inflightDropCache = nil
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.1)) { textVisible = false }
                try? await Task.sleep(for: .milliseconds(120))
                displayedInflight = nil
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

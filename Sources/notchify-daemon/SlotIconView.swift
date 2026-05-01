import SwiftUI

/// One slot icon inside the shelf. No background of its own — it
/// paints over the unified pill's black fill. A small chevron-down
/// sits beneath the icon as a visual cue whenever the stack's list
/// is currently dropped down (`isExpanded`) OR the stack owns the
/// active livestack body (`isLiveActive`); the latter makes it
/// obvious which chip the dropped-down body belongs to when there
/// are multiple chips.
struct SlotIconView: View {
    let stack: ChipStack
    let notchHeight: CGFloat
    var isExpanded: Bool = false
    var isLiveActive: Bool = false
    /// Total number of chips currently on the shelf. Used to gate
    /// chevron visibility: with multiple chips, even a single-row
    /// hover-expansion benefits from the chevron to associate the
    /// hovered chip with the dropped-down list.
    var totalChipCount: Int = 1

    var body: some View {
        // Chevron is meaningful when there's disambiguation to do.
        // - isLiveActive (already gated upstream to count >= 2): the
        //   body belongs to this chip among several.
        // - isExpanded with multiple chips: list of one row but
        //   useful to show "this chip is the one being expanded".
        // - isExpanded with multiple rows: list reveals more than
        //   the body would, regardless of chip count.
        // The single-chip + single-row + isExpanded case stays
        // suppressed because the hover-list would just repeat what
        // the body already shows.
        let hasExtraRows = stack.notifications.count > 1
        let multiChip = totalChipCount >= 2
        let chevronVisible = isLiveActive || (isExpanded && (hasExtraRows || multiChip))
        ZStack(alignment: .topTrailing) {
            // Icon centered in the slot; chevron is positioned via
            // offset so adding/removing it doesn't shift the icon
            // off-center.
            NotchPillView.iconImage(
                stack.resolvedIcon,
                colorName: stack.resolvedColor,
                size: 14
            )
            .frame(width: NotchPillView.slotWidth, height: notchHeight)

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .opacity(chevronVisible ? 1 : 0)
                .frame(width: NotchPillView.slotWidth, height: notchHeight, alignment: .bottom)
                .padding(.bottom, 2)

            if stack.notifications.count > 1 {
                Text("\(stack.notifications.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: -3, y: 4)
            }
        }
        .frame(width: NotchPillView.slotWidth, height: notchHeight)
        .animation(.easeInOut(duration: 0.18), value: chevronVisible)
    }
}

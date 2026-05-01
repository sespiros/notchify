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

    var body: some View {
        // Chevron shows only when there's something extra to reveal
        // by expanding: more than one notification under this chip
        // OR a livestack body whose chip needs disambiguating among
        // multiple chips. A single chip with a single row would
        // expand to identical content — no chevron needed.
        let hasExtraRows = stack.notifications.count > 1
        let chevronVisible = (isExpanded && hasExtraRows) || isLiveActive
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

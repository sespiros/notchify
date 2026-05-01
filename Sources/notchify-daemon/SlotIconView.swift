import SwiftUI

/// One slot icon inside the shelf. No background of its own — it
/// paints over the unified pill's black fill. When `isExpanded` is
/// true (the stack's list is currently dropped down), a small
/// chevron-down sits beneath the icon as a visual cue.
struct SlotIconView: View {
    let stack: ChipStack
    let notchHeight: CGFloat
    var isExpanded: Bool = false

    var body: some View {
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
                .opacity(isExpanded ? 1 : 0)
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
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }
}

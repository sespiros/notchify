import SwiftUI

/// Hover-expanded list of rows for a single stack, rendered inside
/// the pill below the slot row. Caps at `maxListHeight` and scrolls
/// internally; top/bottom fades only appear when content exists past
/// the corresponding edge.
struct HoverListView: View {
    let stack: ChipStack
    let pillWidth: CGFloat
    let pillHeight: CGFloat
    let hoverDropHeight: CGFloat
    @Binding var listScrollOffset: CGFloat
    var onRowClick: (StoredNotification) -> Void
    var onHover: (String, Bool) -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let maxScroll = max(contentHeight - hoverDropHeight, 0)
        let needsScroll = maxScroll > 0
        let topFadeActive = needsScroll && listScrollOffset > 1
        let bottomFadeActive = needsScroll && listScrollOffset < maxScroll - 1

        VerticalListScroll(
            viewportWidth: pillWidth,
            viewportHeight: hoverDropHeight,
            scrollOffset: $listScrollOffset,
            contentHeight: $contentHeight
        ) {
            VStack(spacing: 0) {
                ForEach(stack.notifications) { n in
                    RowView(
                        notification: n,
                        onClick: { onRowClick(n) }
                    )
                    .frame(height: NotchPillView.rowHeight)
                }
            }
            .padding(.vertical, NotchPillView.listVerticalPadding)
            .frame(width: pillWidth)
        }
        .frame(width: pillWidth, height: hoverDropHeight, alignment: .topLeading)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: topFadeActive ? .clear : .black, location: 0),
                    .init(color: .black, location: 0.2),
                    .init(color: .black, location: 0.8),
                    .init(color: bottomFadeActive ? .clear : .black, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: pillWidth, height: hoverDropHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { hovering in onHover(stack.id, hovering) }
        // Position via outer frame *after* contentShape so hit-testing
        // only covers the list's own height, not the chip row above.
        .frame(width: pillWidth, height: pillHeight, alignment: .bottomLeading)
    }
}

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

    var body: some View {
        let totalContent = CGFloat(stack.notifications.count) * NotchPillView.rowHeight
            + NotchPillView.listVerticalPadding * 2
        let needsScroll = totalContent > NotchPillView.maxListHeight
        let maxScroll = max(totalContent - NotchPillView.maxListHeight, 0)
        let topFadeActive = needsScroll && listScrollOffset > 1
        let bottomFadeActive = needsScroll && listScrollOffset < maxScroll - 1

        ScrollView {
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
            // Pin content width to the pill so it doesn't shift when
            // the ScrollView is widened below to hide the scrollbar.
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
        // Render the ScrollView wider than the visible area so the
        // AppKit-backed scrollbar lives past pillWidth, then clip back
        // to pillWidth so it disappears off the right edge. Pure
        // SwiftUI .scrollIndicators(.hidden) is unreliable on macOS
        // 13's ScrollView.
        .frame(width: pillWidth + 16, height: hoverDropHeight, alignment: .leading)
        .frame(width: pillWidth, height: hoverDropHeight, alignment: .leading)
        .clipped()
        // Single LinearGradient with adaptive stops; collapses to fully
        // opaque when no scrolling is needed (no AnyView branching).
        .mask {
            LinearGradient(
                stops: [
                    .init(color: (needsScroll && topFadeActive) ? .clear : .black, location: 0),
                    .init(color: .black, location: 0.2),
                    .init(color: .black, location: 0.8),
                    .init(color: (needsScroll && bottomFadeActive) ? .clear : .black, location: 1.0),
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

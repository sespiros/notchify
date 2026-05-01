import SwiftUI

/// In-flight title/body rendered in the dropped-down area of the pill.
/// Tap dismisses (or runs the action). Hover pauses the dwell timer.
struct InflightBodyView: View {
    let notification: StoredNotification
    let pillWidth: CGFloat
    let pillHeight: CGFloat
    let inflightDropHeight: CGFloat
    let textVisible: Bool
    var onClick: (StoredNotification) -> Void
    var onHover: (Bool) -> Void

    var body: some View {
        // Reuse RowView so the in-flight pill body is visually
        // identical to a hover-list row of the same notification.
        // The drop-area frame around it sizes the click region and
        // gates visibility via textVisible; the outer pill-sized
        // frame anchors the row to the bottom-leading of the pill
        // so the chip slot can sit above it.
        RowView(notification: notification, onClick: { onClick(notification) })
            .frame(width: pillWidth, height: inflightDropHeight, alignment: .leading)
            .opacity(textVisible ? 1 : 0)
            .onHover { hovering in onHover(hovering) }
            .frame(width: pillWidth, height: pillHeight, alignment: .bottomLeading)
    }
}

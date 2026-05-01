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
        Button(action: { onClick(notification) }) {
            VStack(alignment: .leading, spacing: 1) {
                Text(notification.message.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let body = notification.message.text, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
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
            .contentShape(Rectangle())
        }
        .buttonStyle(NoFeedbackButtonStyle())
        .onHover { hovering in onHover(hovering) }
        .accessibilityLabel(notification.message.action == nil ? "Dismiss notification" : "Open notification")
        .frame(width: pillWidth, height: pillHeight, alignment: .bottomLeading)
    }
}

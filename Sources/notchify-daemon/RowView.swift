import SwiftUI

/// One row inside the hover-expanded list: icon + title + (optional)
/// body. The row's icon falls back to the stack's resolved icon when
/// the notification didn't supply its own.
struct RowView: View {
    let notification: StoredNotification
    var onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
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
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoFeedbackButtonStyle())
        .accessibilityLabel(notification.message.action == nil ? "Dismiss \(notification.message.title)" : "Open \(notification.message.title)")
    }
}

import Foundation

/// One queued/in-flight notification with an identity stable across
/// the data model. The id lets the SwiftUI side address a specific
/// row when rendering the expanded list and lets focus-detection
/// dismiss a single row out of a stack.
struct StoredNotification: Identifiable {
    let id = UUID()
    let message: Message
    let chipstackID: String
    let arrivedAt = Date()
}

/// All notifications sharing a chip slot. `id` is "g:<group>" for
/// named groups or "a:_anon" for the shared anonymous chip.
/// `notifications` is newest-first to match the standard
/// notification-center sort.
struct ChipStack: Identifiable {
    let id: String
    let isAnonymous: Bool
    var notifications: [StoredNotification] = []

    /// Resolved chip icon and color, locked from the *first*
    /// notification that supplied them. Subsequent notifications
    /// can't repaint the slot.
    var resolvedIcon: String?
    var resolvedColor: String?
}

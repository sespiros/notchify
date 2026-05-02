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

import Foundation

struct Message: Codable {
    let title: String
    let text: String
    let icon: String?
    let symbol: String?    // SF Symbol name; preferred over icon when set
    let color: String?     // SF Symbol tint: orange, red, blue, etc.
    let sound: String?     // Sound preset name: ready, warning, info, success, error, or system sound name
    let action: String?    // URL or shell command run when the notification is clicked
    let timeout: Double?
}

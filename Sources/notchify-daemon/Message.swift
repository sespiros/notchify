import Foundation

struct DismissKey: Codable, Equatable {
    let bundle: String
    // tmux pane id (e.g. "%23") if the notification was fired from
    // inside tmux, nil otherwise. When set, focus-dismissal also
    // requires this pane to be the active pane of an attached session.
    let tmuxPane: String?
}

struct Message: Codable {
    let title: String
    let text: String?
    let icon: String?
    let symbol: String?    // SF Symbol name; preferred over icon when set
    let color: String?     // SF Symbol tint: orange, red, blue, etc.
    let sound: String?     // Sound preset name: ready, warning, info, success, error, or system sound name
    let action: String?    // URL or shell command run when the notification is clicked
    let timeout: Double?   // 0 means persist (click and/or focus-dismiss only)
    let group: String?     // logical chip name; nil = anonymous chip when persistent
    let groupIcon: String? // SF Symbol for the chip; falls back to `symbol`
    let groupColor: String?// chip tint; falls back to `color`
    let dismissKey: DismissKey?
}

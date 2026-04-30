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
    /// Either an SF Symbol name (e.g. "bell.fill") or an absolute /
    /// tilde-prefixed image file path. The daemon detects which by
    /// looking at the leading character.
    let icon: String?
    let color: String?     // tint for SF Symbol icons (ignored for image files)
    let sound: String?     // sound preset or system sound name
    let action: String?    // URL or shell command run on click
    let timeout: Double?   // 0 means persist (click / focus-dismiss only)
    let group: String?     // logical chip name; nil = anonymous chip
    let dismissKey: DismissKey?
}

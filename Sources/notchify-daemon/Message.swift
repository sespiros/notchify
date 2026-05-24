import Foundation

/// Wire format for one notification arriving over the daemon socket.
/// Encoded as a one-line JSON object by the `notchify` CLI.
struct Message: Codable {
    let title: String
    let text: String?
    /// Either an SF Symbol name (e.g. "bell.fill") or an absolute /
    /// tilde-prefixed image file path. The daemon detects which by
    /// looking at the leading character.
    let icon: String?
    let color: String?     // tint for SF Symbol icons (ignored for image files)
    let sound: String?     // sound preset or system sound name
    let action: String?    // URL or shell command run on click (explicit --action)
    let timeout: Double?   // 0 means persist (click / focus-dismiss only)
    let group: String?     // logical chip name; nil = anonymous chip
    /// Structured source identity used for two things:
    ///   1. Auto-dismiss matching: poll current focus, dismiss this
    ///      notification when the user is back on the source.
    ///   2. Click-action resolution: when no explicit `action` is set,
    ///      the daemon builds the click shell command from this
    ///      structured data at click time (see FocusActionBuilder).
    /// Decoded from either `focus` (new) or `dismissKey` (legacy) on
    /// the wire so old CLIs and new daemons interoperate cleanly.
    let focus: DismissKey?

    private enum CodingKeys: String, CodingKey {
        case title, text, icon, color, sound, action, timeout, group
        case focus, dismissKey
    }

    init(
        title: String,
        text: String? = nil,
        icon: String? = nil,
        color: String? = nil,
        sound: String? = nil,
        action: String? = nil,
        timeout: Double? = nil,
        group: String? = nil,
        focus: DismissKey? = nil
    ) {
        self.title = title
        self.text = text
        self.icon = icon
        self.color = color
        self.sound = sound
        self.action = action
        self.timeout = timeout
        self.group = group
        self.focus = focus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        sound = try c.decodeIfPresent(String.self, forKey: .sound)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        // Prefer `focus` (new), fall back to `dismissKey` (legacy).
        if let f = try c.decodeIfPresent(DismissKey.self, forKey: .focus) {
            focus = f
        } else {
            focus = try c.decodeIfPresent(DismissKey.self, forKey: .dismissKey)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(sound, forKey: .sound)
        try c.encodeIfPresent(action, forKey: .action)
        try c.encodeIfPresent(timeout, forKey: .timeout)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(focus, forKey: .focus)
    }
}

import Foundation

/// When the source is a Ghostty window, the focused Ghostty window's
/// title must contain the source tty's short form. With tmux this
/// pairs with the user's tmux config embedding
/// `#{s|/dev/||:client_tty}` in the window title (see
/// `examples/claude-code-tmux/README.md`). Without tmux, a shell or
/// Ghostty title that includes the tty gives the same disambiguation.
///
/// Abstains outside Ghostty, or when the dismiss key has no tty. If
/// the title probe works but does not contain the source tty, this
/// detector vetoes dismissal. That prevents any unrelated frontmost
/// Ghostty window from satisfying the baseline bundle match for
/// non-tmux notifications.
struct GhosttyWindowDetector: FocusDetectorProvider {
    let category: FocusDetectorCategory = .terminal

    func matches(key: DismissKey, snapshot: FocusSnapshot) -> Bool? {
        guard key.bundle == "com.mitchellh.ghostty",
              let tty = key.tty else { return nil }
        guard let title = snapshot.ghosttyFocusedTitle() else { return false }
        return title.contains(shortTTY(tty))
    }
}

/// `/dev/ttys003` → `ttys003`. Match the CLI's
/// `#{s|/dev/||:client_tty}` convention.
func shortTTY(_ tty: String) -> String {
    return tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
}

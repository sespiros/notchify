import Foundation

/// When the source is a Ghostty window hosting a tmux client, the
/// focused Ghostty window's title must contain the source tty's
/// short form. Pairs with the user's tmux config embedding
/// `#{s|/dev/||:client_tty}` in the window title (see
/// `examples/claude-code-tmux/README.md`).
///
/// Abstains outside Ghostty, and outside tmux. The "outside tmux"
/// abstention preserves the v0.3.1 fix: when there is no
/// multi-window-same-server ambiguity to resolve, we have no
/// reliable signal that a user-set window title contains the source
/// tty, so requiring it would just suppress every dismissal.
struct GhosttyWindowDetector: FocusDetectorProvider {
    let category: FocusDetectorCategory = .terminal

    func matches(key: DismissKey, snapshot: FocusSnapshot) -> Bool? {
        guard key.bundle == "com.mitchellh.ghostty",
              key.tmuxPane != nil,
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

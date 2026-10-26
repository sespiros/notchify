import Foundation

/// When the source is a Ghostty window, the focused Ghostty window's
/// title must contain the source tty's short form. With tmux this
/// pairs with the user's tmux config embedding
/// `#{s|/dev/||:client_tty}` in the window title (see
/// `examples/claude-code-tmux/README.md`). Without tmux, a shell or
/// Ghostty title that includes the tty gives the same disambiguation.
///
/// For a tmux source, the tty is that of the client showing the pane
/// at poll time, falling back to the key's tty when tmux names none.
///
/// Abstains outside Ghostty, or when no tty is known. If
/// the title probe works but does not contain the source tty, this
/// detector vetoes dismissal. That prevents any unrelated frontmost
/// Ghostty window from satisfying the baseline bundle match for
/// non-tmux notifications.
struct GhosttyWindowDetector: FocusDetectorProvider {
    let category: FocusDetectorCategory = .terminal

    func matches(key: DismissKey, snapshot: FocusSnapshot) -> Bool? {
        guard key.bundle == "com.mitchellh.ghostty" else { return nil }
        // A tmux pane is wherever a client shows it now. The tty sent
        // with the key is the client tmux picked at send time, which
        // for a session no window showed is just the latest client.
        var ttys: Set<String> = []
        if let pane = key.tmuxPane {
            ttys = snapshot.clientTTYs(showing: pane, socket: key.tmuxSocket)
        }
        if ttys.isEmpty, let tty = key.tty { ttys = [tty] }
        guard !ttys.isEmpty else { return nil }
        guard let title = snapshot.ghosttyFocusedTitle() else { return false }
        return ttys.contains { title.contains(shortTTY($0)) }
    }
}

/// `/dev/ttys003` → `ttys003`. Match the CLI's
/// `#{s|/dev/||:client_tty}` convention.
func shortTTY(_ tty: String) -> String {
    return tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
}

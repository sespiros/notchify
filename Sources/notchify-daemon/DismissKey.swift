import Foundation

/// Fingerprint of the source the notification came from. The daemon
/// auto-dismisses a notification once the user's current focus matches
/// the key (see `FocusDetector` and the per-feature detectors under
/// `Focus/`).
struct DismissKey: Codable, Equatable {
    let bundle: String
    /// tmux pane id (e.g. "%23") if the notification was fired from
    /// inside tmux, nil otherwise. When set, focus-dismissal also
    /// requires this pane to be the active pane of an attached session.
    let tmuxPane: String?
    /// tmux server socket path (extracted from the caller's $TMUX env
    /// var). The daemon passes this as `tmux -S <path>` so it queries
    /// the user's actual server, not whatever default-socket server
    /// the daemon's environment happens to find.
    let tmuxSocket: String?
    /// Caller's controlling tty (e.g. "/dev/ttys003"). For Ghostty
    /// (which doesn't expose a per-window tty property in 1.3.x),
    /// the daemon disambiguates terminal windows by asking
    /// AppleScript for the front Ghostty window's title and
    /// checking that it contains this tty's short form. Requires
    /// the user's tmux config to embed the client tty in the
    /// window title.
    let tty: String?
}

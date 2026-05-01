import Foundation

/// At least one attached tmux session on the source server must be
/// on the source pane. Lenient because the terminal-window layer
/// (e.g. `GhosttyWindowDetector`) already rules out the
/// multi-window-same-server false positive.
///
/// Abstains when the dismiss key has no tmux pane.
struct TmuxPaneDetector: FocusDetectorProvider {
    let category: FocusDetectorCategory = .multiplexer

    func matches(key: DismissKey, snapshot: FocusSnapshot) -> Bool? {
        guard let pane = key.tmuxPane else { return nil }
        let panes = snapshot.activePanes(socket: key.tmuxSocket)
        guard !panes.isEmpty else { return false }
        return panes.contains(pane)
    }
}

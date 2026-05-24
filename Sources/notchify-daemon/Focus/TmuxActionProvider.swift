import Foundation

/// When the source was inside tmux, switch tmux to the originating
/// pane (and the window containing it). Independent of the terminal
/// provider — composes with whichever one matched.
///
/// The absolute path to the tmux binary is resolved at click time:
/// notchify-daemon runs from launchd with a minimal PATH and would
/// otherwise fail to find tmux. We reuse the same probe order the
/// matcher side uses (`FocusDetector.resolveTmuxBinary`).
@MainActor
struct TmuxActionProvider: FocusActionProvider {
    let category: FocusActionCategory = .multiplexer

    func action(for focus: DismissKey) -> String? {
        guard let pane = focus.tmuxPane, !pane.isEmpty,
              let tmux = FocusDetector.resolveTmuxBinary() else { return nil }
        return "\(tmux) select-window -t \(pane) && \(tmux) select-pane -t \(pane)"
    }
}

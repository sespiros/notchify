import Foundation

/// When invoked from inside tmux, switch tmux to the originating pane
/// (and the window containing it). Independent of the terminal
/// provider — composes with whichever one matched.
///
/// We bake the absolute path to the tmux binary into the action
/// string at -focus time, because notchify-daemon runs from launchd
/// with a minimal PATH and would otherwise fail to find tmux at
/// click time.
struct TmuxFocusProvider: FocusProvider {
    let category: FocusCategory = .multiplexer

    func action(in context: FocusContext) -> String? {
        guard let pane = context.env["TMUX_PANE"], !pane.isEmpty,
              let tmux = context.tmuxBinary else { return nil }
        return "\(tmux) select-window -t \(pane) && \(tmux) select-pane -t \(pane)"
    }
}

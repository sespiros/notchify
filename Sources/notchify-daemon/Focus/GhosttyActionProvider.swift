import Foundation

/// Ghostty exposes an AppleScript dictionary, so we ask it to focus a
/// specific terminal by matching the tty embedded in the window title
/// (`whose name contains <short tty>`). Requires the user's tmux/shell
/// to put `#{s|/dev/||:client_tty}` in the title (see
/// `examples/claude-code-tmux/README.md`). Without that, Ghostty falls
/// through to `OpenBundleActionProvider` which raises the app but
/// can't pick a specific window.
///
/// Ghostty 1.4 (commit 9a9002202) adds `tty` and `pid` as queryable
/// AppleScript properties on `terminal`. Once that is the baseline we
/// can switch to `whose tty is <tty>` and stop requiring the title hack.
@MainActor
struct GhosttyActionProvider: FocusActionProvider {
    let category: FocusActionCategory = .terminal

    func action(for focus: DismissKey) -> String? {
        guard focus.bundle == "com.mitchellh.ghostty" else { return nil }
        guard let tty = focus.tty else { return nil }
        let short = shortTTY(tty)
        // Combine activate + focus in one osascript invocation. Each
        // osascript spawn costs ~100-200ms of fork/exec plus
        // AppleScript bridge startup; doing both in one process
        // roughly halves the click-to-focus latency.
        let activate = "tell application \"Ghostty\" to activate"
        let focusCmd = "tell application \"Ghostty\" to focus (first terminal whose name contains \"\(short)\")"
        return "osascript -e '\(activate)' -e '\(focusCmd)' 2>/dev/null"
    }
}

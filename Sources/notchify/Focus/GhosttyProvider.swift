import Foundation

/// Ghostty exposes an AppleScript dictionary, so we can ask it to
/// focus a specific terminal — raising the right window *and*
/// selecting the right tab. We match by tty embedded in the window
/// title via `whose name contains <short tty>`, which requires the
/// user's tmux/shell to put `#{s|/dev/||:client_tty}` in the title
/// (see examples/claude-code-tmux/README.md). Without that, Ghostty
/// falls through to OpenBundleFocusProvider, which still activates
/// the app but can't pick a specific window.
///
/// This title-match dance is a workaround for Ghostty 1.3.x. Ghostty
/// 1.4 (commit 9a9002202) adds `tty` and `pid` as queryable AppleScript
/// properties on the `terminal` class, at which point we can switch
/// the matcher to `whose tty is <tty>` and the user's tmux config no
/// longer has to embed the tty in the title. Until 1.4 is the
/// baseline, we stay on the title-match path.
///
/// Approval is a one-time macOS Automation prompt — not Accessibility,
/// not Screen Recording.
struct GhosttyFocusProvider: FocusProvider {
    let category: FocusCategory = .terminal

    func action(in context: FocusContext) -> String? {
        guard context.detectedBundle == "com.mitchellh.ghostty" else { return nil }
        guard let tty = context.callerTTY else { return nil }
        let short = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        let activate = "osascript -e 'tell application \"Ghostty\" to activate'"
        let focus = "tell application \"Ghostty\" to focus (first terminal whose name contains \"\(short)\")"
        return "\(activate); osascript -e '\(focus)' 2>/dev/null"
    }
}

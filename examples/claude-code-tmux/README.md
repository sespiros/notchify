# Claude Code + tmux integration

Drop-in hook that fires `notchify` when a Claude Code session goes idle
or asks for permission, with per-window tmux state.

## Install

1. Copy [`notchify-state.sh`](./notchify-state.sh) to
   `~/.claude/hooks/notchify-state.sh` and `chmod +x` it.
2. Register it in `~/.claude/settings.json` for the events you care
   about:

   ```json
   {
     "hooks": {
       "Stop": [
         { "matcher": "*", "hooks": [
           { "type": "command",
             "command": "/Users/<you>/.claude/hooks/notchify-state.sh idle" }
         ]}
       ],
       "Notification": [
         { "matcher": "*", "hooks": [
           { "type": "command",
             "command": "/Users/<you>/.claude/hooks/notchify-state.sh blocked" }
         ]}
       ],
       "PreToolUse": [
         { "matcher": "*", "hooks": [
           { "type": "command",
             "command": "/Users/<you>/.claude/hooks/notchify-state.sh working" }
         ]}
       ],
       "SessionEnd": [
         { "matcher": "*", "hooks": [
           { "type": "command",
             "command": "/Users/<you>/.claude/hooks/notchify-state.sh release" }
         ]}
       ]
     }
   }
   ```

## Click to jump back

`-focus` (set by the wrapper) makes clicking the banner bring the
terminal app forward and switch tmux to the originating pane.

For Ghostty, notchify will land you on the *exact tab* hosting your
tmux client if it can match the tab's window title against the tmux
client tty.
That requires tmux's `set-titles` to be on and to embed the client tty
in the title:

```tmux
set -g set-titles on
set -g set-titles-string '#S (#{s|/dev/||:client_tty})'
```

`#{s|/dev/||:client_tty}` strips the `/dev/` prefix so titles read
`Session A (ttys006)` rather than the verbose `/dev/ttys006 Session A`.
notchify's `-focus` matches the short form against the title.

If you're on byobu (or another tmux wrapper) the wrapper may disable
`set-titles` after your own `~/.tmux.conf` runs — check with
`tmux show-options -g set-titles` and, if needed, put the two lines
above in `~/.config/byobu/.tmux.conf` (sourced after byobu's defaults)
or the equivalent post-load hook for your wrapper.

Without the title embed, `-focus` still activates Ghostty and switches
tmux, you just may land on whichever Ghostty window was last frontmost
rather than the originating tab.

If you launch Ghostty windows from window-manager shortcuts, make sure
they all live in the same Ghostty process — `open -na "Ghostty"`
forces a separate process and that hides windows from the AppleScript
matching used by `-focus`. Drive new windows through Ghostty's own
AppleScript instead, e.g. for AeroSpace:

```toml
alt-enter = '''exec-and-forget osascript -e 'tell application "Ghostty" to make new window' 2>/dev/null'''
```

## tmux companion

The hook sets `@agent_state` on the tmux window. To render a per-tab
dot for `working` (yellow) / `idle` (green) / `blocked` (red) /
`background` (purple, when a `run_in_background:true` Agent is in
flight), add to your tmux config:

```tmux
set -g window-status-format         '#I: #{?#{==:#{@agent_state},working},#[fg=colour136]●#[default] ,#{?#{==:#{@agent_state},idle},#[fg=colour64]●#[default] ,#{?#{==:#{@agent_state},blocked},#[fg=colour160]●#[default] ,#{?#{==:#{@agent_state},background},#[fg=colour93]●#[default] ,}}}}#W#{?window_flags,#{window_flags}, }'
set -g window-status-current-format '#I: #{?#{==:#{@agent_state},working},#[fg=colour136]●#[default] ,#{?#{==:#{@agent_state},idle},#[fg=colour64]●#[default] ,#{?#{==:#{@agent_state},blocked},#[fg=colour160]●#[default] ,#{?#{==:#{@agent_state},background},#[fg=colour93]●#[default] ,}}}}#W#{?window_flags,#{window_flags}, }'
```

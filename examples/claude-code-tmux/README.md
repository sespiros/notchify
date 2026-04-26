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

## tmux companion

The hook sets `@agent_state` on the tmux window. To render a per-tab
dot for `working` (yellow) / `idle` (green) / `blocked` (red), add to
your tmux config:

```tmux
set -g window-status-format         '#I: #{?#{==:#{@agent_state},working},#[fg=colour136]●#[default] ,#{?#{==:#{@agent_state},idle},#[fg=colour64]●#[default] ,#{?#{==:#{@agent_state},blocked},#[fg=colour160]●#[default] ,}}}#W#{?window_flags,#{window_flags}, }'
set -g window-status-current-format '#I: #{?#{==:#{@agent_state},working},#[fg=colour136]●#[default] ,#{?#{==:#{@agent_state},idle},#[fg=colour64]●#[default] ,#{?#{==:#{@agent_state},blocked},#[fg=colour160]●#[default] ,}}}#W#{?window_flags,#{window_flags}, }'
```

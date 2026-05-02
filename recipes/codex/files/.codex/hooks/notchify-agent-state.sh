#!/bin/sh
# notchify-agent-state: fire a notchify popup when Codex goes idle
# or blocked. Registered for the Stop and Notification hook events
# in ~/.codex/hooks.json.
#
# This hook is intentionally narrow: its only job is to notify. Any
# tmux statusline integration (e.g. coloring per-pane dots based on
# agent state) belongs in a separate hook script.
#
# Universal assumption: the user runs codex inside tmux, so the
# pane's TMUX_PANE env var is set; if not, the hook exits silently.

set -eu

state="${1:-}"
[ -n "${TMUX_PANE:-}" ] || exit 0
command -v notchify >/dev/null 2>&1 || exit 0

case "$state" in
    idle|blocked) ;;
    *) exit 0 ;;
esac

loc=$(tmux display-message -pt "$TMUX_PANE" '#{session_name}:#{window_name}' 2>/dev/null || echo "")
title="codex ${loc:-session}"

case "$state" in
    blocked)
        notchify "$title" "waiting for input" -sound info \
                 -icon "$HOME/.config/codex/icons/blocked.png" \
                 -group "$title blocked" -focus &
        ;;
    idle)
        notchify "$title" "done" -sound ready \
                 -icon "$HOME/.config/codex/icons/done.png" \
                 -group "$title done" -focus &
        ;;
esac

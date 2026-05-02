#!/bin/sh
# notchify-agent-state: fire a notchify popup when Codex goes idle
# or blocked. Registered for the Stop and Notification hook events
# in ~/.codex/hooks.json.
#
# This hook is intentionally narrow: its only job is to notify. Any
# tmux statusline integration (e.g. coloring per-pane dots based on
# agent state) belongs in a separate hook script.
#
# Works whether or not the user runs codex inside tmux. With tmux,
# the title carries session:window for disambiguation; without tmux,
# the title is just "codex".

set -eu

state="${1:-}"
command -v notchify >/dev/null 2>&1 || exit 0

case "$state" in
    idle|blocked) ;;
    *) exit 0 ;;
esac

# Debounce: skip if we already fired for this state in the last
# DEBOUNCE_SECS seconds. Symmetric with the claude recipe — same
# tool-phase Stop spam can occur on codex.
DEBOUNCE_SECS=5
stamp_dir="${TMPDIR:-/tmp}"
stamp="$stamp_dir/notchify-codex-${state}.stamp"
now=$(date +%s)
if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt "$DEBOUNCE_SECS" ]; then
        exit 0
    fi
fi
echo "$now" > "$stamp"

title="codex"
if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    loc=$(tmux display-message -pt "$TMUX_PANE" '#{session_name}:#{window_name}' 2>/dev/null || echo "")
    [ -n "$loc" ] && title="codex $loc"
fi

# Group key is constant per agent + state, so every codex pane's
# notifications coalesce into one chip stack regardless of tmux pane,
# session, or window. The display title still carries the per-session
# detail; only grouping is global.
case "$state" in
    blocked)
        # Synchronous (no &): backgrounding reparents notchify to
        # launchd when the hook exits, breaking the CLI's bundle
        # detection (getppid()=1) and so the -focus click-action
        # and dismiss-key. notchify is sub-second; we wait.
        notchify "$title" "waiting for input" -sound info \
                 -icon "$HOME/.config/codex/icons/blocked.png" \
                 -group "codex:blocked" -focus
        ;;
    idle)
        notchify "$title" "done" -sound ready \
                 -icon "$HOME/.config/codex/icons/done.png" \
                 -group "codex:done" -focus
        ;;
esac

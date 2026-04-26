#!/bin/sh
# Claude Code + tmux integration for notchify.
#
# Compared to the minimal README example, this script also:
#   - sets @agent_state on the Claude pane's tmux window (drives a
#     status-line dot for working / idle / blocked),
#   - skips the notification when the affected pane is the focused one,
#   - reads Claude Code's event payload from stdin to pull the
#     /rename-given session name out of the transcript,
#   - shows the hosting tmux session and window in the body so you know
#     where in your layout the agent lives.
#
# Wire it up in ~/.claude/settings.json against matching events. Pass
# the state as the first argument (working / idle / blocked / release).
set -eu

state="${1:-}"
[ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null || exit 0

case "$state" in
  release|"")
    tmux set-option -w -t "$TMUX_PANE" -u @agent_state >/dev/null 2>&1 || true
    exit 0 ;;
  working)
    tmux set-option -w -t "$TMUX_PANE" @agent_state working >/dev/null 2>&1 || true
    exit 0 ;;
  idle|blocked)
    tmux set-option -w -t "$TMUX_PANE" @agent_state "$state" >/dev/null 2>&1 || true ;;
  *) exit 0 ;;
esac

# Skip the notification when the affected pane is the focused one.
[ "$(tmux display-message -p '#{pane_id}')" != "$TMUX_PANE" ] || exit 0
command -v notchify >/dev/null || exit 0

# Pull /rename session name out of Claude's transcript via grep+sed.
payload=$(cat 2>/dev/null || true)
transcript=$(printf %s "$payload" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p')
session=""
[ -f "$transcript" ] && session=$(grep '"type":"custom-title"' "$transcript" | tail -1 |
    sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p')

[ "$state" = blocked ] && title="Claude blocked" || title="Claude done"
if [ -n "$session" ]; then
  body="Session $session"
else
  body=$(tmux display-message -pt "$TMUX_PANE" '#{session_name}:#{window_name}')
fi

if [ "$state" = blocked ]; then
  notchify -title "$title" -text "$body" -sound warning \
           -symbol exclamationmark.triangle.fill -color orange &
else
  notchify -title "$title" -text "$body" -sound ready \
           -symbol checkmark.circle.fill -color green &
fi

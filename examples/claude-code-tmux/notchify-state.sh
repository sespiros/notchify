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

current=$(tmux show-options -wv -t "$TMUX_PANE" @agent_state 2>/dev/null || true)

case "$state" in
  release|"")
    tmux set-option -w -t "$TMUX_PANE" -u @agent_state >/dev/null 2>&1 || true
    exit 0 ;;
  working)
    # PreToolUse on the Agent tool with run_in_background:true marks the
    # pane as "background" (a separate dot color). It stays that way
    # through subsequent working ticks (so you can tell at a glance
    # Claude is idle but a subagent is still in flight) until the next
    # UserPromptSubmit clears it back to plain working.
    payload=$(cat 2>/dev/null || true)
    if printf %s "$payload" | grep -q '"hook_event_name":"UserPromptSubmit"'; then
      tmux set-option -w -t "$TMUX_PANE" @agent_state working >/dev/null 2>&1 || true
      exit 0
    fi
    if printf %s "$payload" | grep -q '"run_in_background":[[:space:]]*true'; then
      tmux set-option -w -t "$TMUX_PANE" @agent_state background >/dev/null 2>&1 || true
      exit 0
    fi
    [ "$current" = background ] || \
      tmux set-option -w -t "$TMUX_PANE" @agent_state working >/dev/null 2>&1 || true
    exit 0 ;;
  idle|blocked)
    # Don't downgrade purple→green on Stop; a background agent is still live.
    if [ "$state" = idle ] && [ "$current" = background ]; then
      exit 0
    fi
    tmux set-option -w -t "$TMUX_PANE" @agent_state "$state" >/dev/null 2>&1 || true ;;
  *) exit 0 ;;
esac

# Skip the notification when the user is actually looking at this pane.
# The check has two layers:
#   1. tmux says this pane is the active pane in the active window
#      (and, if zoomed, that the zoomed pane is ours too).
#   2. On macOS under AeroSpace, the focused window's title also
#      matches this pane's session name. The set-titles-string in
#      examples/claude-code-tmux/README.md is '#S (#{s|/dev/||:client_tty})',
#      so we strip the trailing ' (...)' annotation before comparing.
# If aerospace isn't installed we fall back to the tmux-only check.
visible=$(tmux display-message -pt "$TMUX_PANE" '#{&&:#{window_active},#{?window_zoomed_flag,#{pane_active},1}}' 2>/dev/null || echo 0)
[ "$visible" = "1" ] || visible=0
if [ "$visible" = "1" ]; then
  if command -v aerospace >/dev/null 2>&1; then
    session=$(tmux display-message -pt "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
    front=$(aerospace list-windows --focused --format '%{window-title}' 2>/dev/null | head -1 || true)
    front_session="${front%% (*}"
    [ -n "$session" ] && [ "$front_session" = "$session" ] && exit 0
  else
    exit 0
  fi
fi
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
           -symbol exclamationmark.triangle.fill -color orange \
           -focus &
else
  notchify -title "$title" -text "$body" -sound ready \
           -symbol checkmark.circle.fill -color green \
           -focus &
fi

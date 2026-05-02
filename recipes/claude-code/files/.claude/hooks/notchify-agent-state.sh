#!/bin/sh
# notchify-agent-state: fire a notchify popup when Claude Code goes
# idle or blocked. Registered for the Stop and Notification hook
# events in ~/.claude/settings.json.
#
# This hook is intentionally narrow: its only job is to notify. Any
# tmux statusline integration (e.g. coloring per-pane dots based on
# agent state) belongs in a separate hook script. See the recipe
# README for context.
#
# Works whether or not the user runs claude inside tmux. With tmux,
# the title carries session:window for disambiguation; without tmux,
# the title is just "claude" (or the /rename custom title if set).

set -eu

state="${1:-}"
command -v notchify >/dev/null 2>&1 || exit 0

case "$state" in
    idle|blocked) ;;
    *) exit 0 ;;
esac

# Debounce: Claude Code's Stop hook fires multiple times per turn
# when the assistant alternates between text and tool calls, which
# otherwise spams a "done" popup per phase. Skip the notify if we
# already fired for this state within DEBOUNCE_SECS.
DEBOUNCE_SECS=5
stamp_dir="${TMPDIR:-/tmp}"
stamp="$stamp_dir/notchify-claude-${state}.stamp"
now=$(date +%s)
if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt "$DEBOUNCE_SECS" ]; then
        exit 0
    fi
fi
echo "$now" > "$stamp"

payload=$(cat 2>/dev/null || true)

# extract_session_title <transcript_path>
# ---------------------------------------
# Print the most recent /rename custom title from claude's
# transcript JSONL, or empty if none. Depends on claude-code's
# transcript schema (subject to change in future releases). Empty
# result falls back cleanly to a tmux-derived default below.
extract_session_title() {
    transcript=$1
    [ -f "$transcript" ] || return 0
    grep '"type":"custom-title"' "$transcript" | tail -1 |
        sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p'
}

# extract_blocked_hint <transcript_path>
# --------------------------------------
# Walk claude's transcript JSONL, find the last assistant message,
# and print a short hint about what claude was doing when it
# blocked: e.g. "Bash: pytest", "Edit: foo.py", "Grep: TODO".
# Empty when python3 is unavailable, the transcript is missing, or
# no tool_use is present. Used to enrich the blocked-state popup
# body.
#
# Requires python3 (preinstalled on macOS).
extract_blocked_hint() {
    transcript=$1
    [ -f "$transcript" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$transcript" 2>/dev/null <<'PY'
import json, os, sys
last = None
with open(sys.argv[1]) as f:
    for line in f:
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "assistant":
            last = d
if not last:
    sys.exit()
content = last.get("message", {}).get("content", [])
tool = next((c for c in reversed(content) if c.get("type") == "tool_use"), None)
if tool:
    inp = tool.get("input", {})
    name = tool["name"]
    if "command" in inp:
        cmd = inp["command"].strip()
        hint = cmd.split()[0] if cmd else ""
    elif "file_path" in inp:
        hint = os.path.basename(inp["file_path"])
    elif "pattern" in inp:
        hint = inp["pattern"]
    else:
        hint = inp.get("description", "") or inp.get("prompt", "")
    out = f"{name}: {hint}" if hint else name
else:
    text = next((c["text"] for c in content if c.get("type") == "text"), "")
    out = " ".join(text.split())
print(out[:60])
PY
}

# Build the default title. With tmux, qualify "claude" with
# session:window so the user can tell concurrent sessions apart;
# without tmux, fall back to a bare "claude". Either way, a
# /rename custom title from the transcript wins if present.
title="claude"
if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    loc=$(tmux display-message -pt "$TMUX_PANE" '#{session_name}:#{window_name}' 2>/dev/null || echo "")
    [ -n "$loc" ] && title="claude $loc"
fi
transcript=$(printf %s "$payload" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p')
custom=$(extract_session_title "$transcript")
[ -n "$custom" ] && title="$custom"

# Group key is constant per agent + state, so every claude pane's
# notifications coalesce into one chip stack regardless of tmux pane,
# session, window, or transcript /rename. The display title still
# carries the per-session detail; only grouping is global.
case "$state" in
    blocked)
        # The hook payload's `message` field is set for some kinds of
        # Notification events but not all; fall back to mining the
        # transcript for a tool-use hint.
        message=$(printf %s "$payload" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
        [ -z "$message" ] && message=$(extract_blocked_hint "$transcript")
        body="${message:-waiting for input}"
        notchify "$title" "$body" -sound info \
                 -icon "$HOME/.config/claude/icons/blocked.png" \
                 -group "claude:blocked" -focus &
        ;;
    idle)
        notchify "$title" "done" -sound ready \
                 -icon "$HOME/.config/claude/icons/done.png" \
                 -group "claude:done" -focus &
        ;;
esac

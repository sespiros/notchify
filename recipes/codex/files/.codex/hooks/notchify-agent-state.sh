#!/bin/sh
# notchify-agent-state: fire a notchify popup when Codex stops or asks
# for permission. Registered for Stop and PermissionRequest hook events
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

read_payload() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -c '
import select, sys

ready, _, _ = select.select([sys.stdin], [], [], 0)
if ready:
    print(sys.stdin.read(), end="")
' 2>/dev/null || true
}

payload=$(read_payload)
blocked_body=""

extract_stop_input_body() {
    [ -n "$payload" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    printf %s "$payload" | python3 -c '
import json, re, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit()

if data.get("hook_event_name") != "Stop":
    sys.exit()

message = data.get("last_assistant_message") or ""
text = " ".join(message.split())
if not text:
    sys.exit()

patterns = [
    r"\bwaiting for (your )?(input|reply|confirmation|approval)\b",
    r"\bneeds? your (input|reply|confirmation|approval)\b",
    r"\bmanual steps?:\b",
    r"\b(once you|when you have).*\b(confirm|paste|send|reply|choose|select|approve)\b",
    r"\bplease (confirm|paste|send|reply|choose|select|approve)\b",
    r"\b(do you want|should i).*\?",
    r"\b(which|what).*\?\s*$",
]
if any(re.search(p, text, re.I) for p in patterns):
    print("waiting for input")
' 2>/dev/null || true
}

extract_notification_body() {
    [ -n "$payload" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    printf %s "$payload" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit()

for key in ("message", "title"):
    value = data.get(key)
    if isinstance(value, str):
        text = " ".join(value.split())
        if text:
            print(text[:90])
            break
' 2>/dev/null || true
}

extract_permission_body() {
    [ -n "$payload" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    printf %s "$payload" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit()

if data.get("hook_event_name") != "PermissionRequest":
    sys.exit()

tool = data.get("tool_name")
tool_input = data.get("tool_input")
command = ""
if isinstance(tool_input, dict):
    for key in ("command", "cmd", "description"):
        value = tool_input.get(key)
        if isinstance(value, str):
            command = " ".join(value.split())
            if command:
                break

if command:
    print(command[:90])
elif isinstance(tool, str) and tool.strip():
    print(("permission requested: " + tool.strip())[:90])
else:
    print("waiting for permission")
' 2>/dev/null || true
}

if [ "$state" = "idle" ]; then
    body=$(extract_stop_input_body)
    if [ -n "$body" ]; then
        state=blocked
        blocked_body="$body"
    fi
fi
if [ "$state" = "blocked" ] && [ -z "$blocked_body" ]; then
    blocked_body=$(extract_permission_body)
fi
if [ "$state" = "blocked" ] && [ -z "$blocked_body" ]; then
    blocked_body=$(extract_notification_body)
fi
[ -n "$blocked_body" ] || blocked_body="waiting for input"

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
        if ! notchify "$title" "$blocked_body" -sound info \
                      -icon "$HOME/.config/codex/icons/blocked.png" \
                      -group "codex:blocked" -focus; then
            exit 0
        fi
        ;;
    idle)
        if ! notchify "$title" "done" -sound ready \
                      -icon "$HOME/.config/codex/icons/done.png" \
                      -group "codex:done" -focus; then
            exit 0
        fi
        ;;
esac

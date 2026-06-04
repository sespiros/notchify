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

# Transport: how the notification reaches the notch.
#   direct (default) the notchify CLI talks to the local daemon
#                    (Unix socket, or its loopback-TCP fallback).
#   bell             for an agent on a remote host reached over
#                    ssh+tmux with no daemon/tunnel: emit a terminal
#                    bell carrying the label in the pane title, which a
#                    local tmux alert-bell hook turns into a notch. See
#                    recipes/local/notchify-tmux-bell.sh.
#   auto             try the CLI, fall back to bell.
NOTCHIFY_TRANSPORT="${NOTCHIFY_TRANSPORT:-direct}"

# Only direct mode needs the CLI on PATH; bell mode just emits escapes.
if [ "$NOTCHIFY_TRANSPORT" = direct ]; then
    command -v notchify >/dev/null 2>&1 || exit 0
fi

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

# The Notification event fires for both permission_prompt (claude
# needs the user to approve a tool call, actionable) and
# idle_prompt (claude has been waiting ~60s for input, just a nag).
# The nag pops up after the user has already engaged with a previous
# notification but hasn't typed yet, which reads as a spurious
# duplicate. Drop it; only the permission case warrants a popup.
if [ "$state" = "blocked" ]; then
    notification_type=$(printf %s "$payload" | sed -n 's/.*"notification_type":"\([^"]*\)".*/\1/p')
    if [ "$notification_type" = "idle_prompt" ]; then
        exit 0
    fi
fi

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

# Build the default title. Claude's transcript title wins when present;
# otherwise sandbox launchers may supply a compact display name. Outside
# sandboxes, tmux still qualifies "claude" with session:window.
transcript=$(printf %s "$payload" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p')
custom=$(extract_session_title "$transcript")
title="claude"
if [ -n "$custom" ]; then
    title="$custom"
elif [ -n "${NOTCHIFY_CONTEXT_NAME:-}" ]; then
    title="claude $NOTCHIFY_CONTEXT_NAME"
elif [ -n "${NOTCHIFY_CONTEXT_REPO:-}" ]; then
    title="claude $NOTCHIFY_CONTEXT_REPO"
elif [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    loc=$(tmux display-message -pt "$TMUX_PANE" '#{session_name}:#{window_name}' 2>/dev/null || echo "")
    [ -n "$loc" ] && title="claude $loc"
fi

# --- bell transport --------------------------------------------------
# nh_tty: terminal device to ring, or empty. Inside tmux it's the
# pane's pts; otherwise walk up to the nearest ancestor with a real
# controlling tty (the ssh session pts). NOTCHIFY_BELL_TTY overrides.
nh_tty() {
    if [ -n "${NOTCHIFY_BELL_TTY:-}" ]; then printf '%s\n' "$NOTCHIFY_BELL_TTY"; return 0; fi
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        _p=$(tmux display -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null) || _p=""
        [ -n "$_p" ] && { printf '%s\n' "$_p"; return 0; }
    fi
    _pid=${PPID:-0}
    while [ -n "$_pid" ] && [ "$_pid" -gt 1 ]; do
        _t=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
        case "$_t" in pts/*|tty*) printf '/dev/%s\n' "$_t"; return 0 ;; esac
        _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

# nh_bell <icon> <sound> <group> <title> <body>: set the pane title to
# the marker "notchify|<icon>|<sound>|<group>|<title>|<body>"
# (passthrough-wrapped inside tmux so it escapes even a background pane)
# and ring the bell. A local tmux alert-bell hook reads the marker and
# replays it as a local notchify, so icon/sound/group survive intact.
# Returns nonzero if no tty was found.
nh_bell() {
    _bi=$(printf %s "${1:-}" | tr -d '\000-\037|')
    _bs=$(printf %s "${2:-}" | tr -d '\000-\037|')
    _bg=$(printf %s "${3:-}" | tr -d '\000-\037|')
    _bt=$(printf %s "${4:-}" | tr -d '\000-\037|')
    _bb=$(printf %s "${5:-}" | tr -d '\000-\037|')
    _tty=$(nh_tty) || return 1
    _m="notchify|$_bi|$_bs|$_bg|$_bt|$_bb"
    # One write: set the pane title, then ring. A second redirect would
    # truncate the tty and clobber the title before the terminal saw it,
    # so the OSC and the BEL must land together, in order.
    if [ -n "${TMUX:-}" ]; then
        printf '\033Ptmux;\033\033]2;%s\007\033\134\a' "$_m" > "$_tty" 2>/dev/null
    else
        printf '\033]2;%s\007\a' "$_m" > "$_tty" 2>/dev/null
    fi
}

# nh_deliver <title> <body> -- <notchify-args...>: send per
# NOTCHIFY_TRANSPORT. Returns nonzero only when nothing could be sent
# (caller treats that as non-fatal).
nh_deliver() {
    _title=$1; _body=$2; shift 2
    [ "${1:-}" = -- ] && shift
    # Pull --icon/--sound/--group for the bell marker without consuming
    # "$@" (direct mode still needs the full arg vector); a for-loop
    # state machine grabs the value following each flag.
    _icon="" _sound="" _group="" _want=""
    for _a in "$@"; do
        case $_want in
            icon)  _icon=$_a;  _want=""; continue ;;
            sound) _sound=$_a; _want=""; continue ;;
            group) _group=$_a; _want=""; continue ;;
        esac
        case $_a in
            --icon)  _want=icon ;;
            --sound) _want=sound ;;
            --group) _want=group ;;
        esac
    done
    case "$NOTCHIFY_TRANSPORT" in
        bell) nh_bell "$_icon" "$_sound" "$_group" "$_title" "$_body" ;;
        auto)
            if command -v notchify >/dev/null 2>&1 && notchify "$_title" "$_body" "$@"; then
                return 0
            fi
            nh_bell "$_icon" "$_sound" "$_group" "$_title" "$_body" ;;
        *) notchify "$_title" "$_body" "$@" ;;
    esac
}

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
        # Run synchronously: backgrounding (with &) reparents notchify
        # to launchd as soon as the hook script exits, which makes
        # getppid()-based ancestor walking fail to find the calling
        # terminal app, breaking --focus's click-action and dismiss-key
        # detection. notchify is sub-second; the hook can wait.
        if ! nh_deliver "$title" "$body" -- --sound info \
                      --icon "integration:claude-code/blocked" \
                      --group "claude:blocked" --focus; then
            exit 0
        fi
        ;;
    idle)
        if ! nh_deliver "$title" "done" -- --sound ready \
                      --icon "integration:claude-code/done" \
                      --group "claude:done" --focus; then
            exit 0
        fi
        ;;
esac

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

# nh_tty: terminal device to ring, or empty. Inside tmux it's the
# pane's pts; otherwise walk up to the nearest ancestor with a real
# controlling tty (the ssh session pts). NOTCHIFY_BELL_TTY overrides.
# Defined ahead of the transports because it doubles as the headless
# gate right below.
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

# Headless gate: hooks.json is global, so codex runs spawned by a GUI
# (the ChatGPT app's codex-security scan workers, computer use) or by
# cron/CI fire this hook too, and a fleet of headless exec workers
# means a "done" popup per worker turn, all noise. No tmux pane and no
# controlling tty anywhere in the ancestry means nobody is watching
# this session from a terminal and there is no pane for --focus to
# jump back to: stay silent.
nh_tty >/dev/null 2>&1 || exit 0

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

# Since codex added an automatic approvals reviewer (config.toml
# approvals_reviewer = "auto_review", alias "guardian_subagent"),
# PermissionRequest hooks fire for every action the reviewer decides,
# but the user is never prompted: hooks run first, then the reviewer
# approves or denies on its own (codex-rs/core/src/tools/approvals.rs).
# Notifying on those is a popup per tool call, all false alarms, so
# skip the blocked notification when the event is a PermissionRequest
# and the config routes approvals to the auto reviewer. The payload
# cannot tell an auto-reviewed approval from a user-facing one (its
# permission_mode collapses to "default" for both), so this squelches
# PermissionRequest entirely while auto_review is configured; a session
# whose policy still prompts the user (e.g. untrusted) shows the prompt
# in the TUI but loses the notch ping, the acceptable tradeoff.
permission_request_event() {
    [ -n "$payload" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    printf %s "$payload" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

sys.exit(0 if data.get("hook_event_name") == "PermissionRequest" else 1)
' 2>/dev/null
}

approvals_auto_reviewed() {
    _cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
    [ -f "$_cfg" ] || return 1
    # Root-level key only: stop at the first TOML table header so a
    # same-named key inside a [section] cannot match.
    awk '
        BEGIN { rc = 1 }
        /^[[:space:]]*\[/ { exit }
        /^[[:space:]]*approvals_reviewer[[:space:]]*=[[:space:]]*"(auto_review|guardian_subagent)"/ { rc = 0; exit }
        END { exit rc }
    ' "$_cfg" 2>/dev/null
}

if [ "$state" = "blocked" ] && permission_request_event && approvals_auto_reviewed; then
    exit 0
fi

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
if [ -n "${NOTCHIFY_CONTEXT_NAME:-}" ]; then
    title="codex $NOTCHIFY_CONTEXT_NAME"
elif [ -n "${NOTCHIFY_CONTEXT_REPO:-}" ]; then
    title="codex $NOTCHIFY_CONTEXT_REPO"
elif [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    loc=$(tmux display-message -pt "$TMUX_PANE" '#{session_name}:#{window_name}' 2>/dev/null || echo "")
    [ -n "$loc" ] && title="codex $loc"
fi

# --- bell transport --------------------------------------------------
# (nh_tty is defined next to the headless gate above.)

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

# Group key is constant per agent + state, so every codex pane's
# notifications coalesce into one chip stack regardless of tmux pane,
# session, or window. The display title still carries the per-session
# detail; only grouping is global.
case "$state" in
    blocked)
        # Synchronous (no &): backgrounding reparents notchify to
        # launchd when the hook exits, breaking the CLI's bundle
        # detection (getppid()=1) and so the --focus click-action
        # and dismiss-key. notchify is sub-second; we wait.
        if ! nh_deliver "$title" "$blocked_body" -- --sound info \
                      --icon "integration:codex/blocked" \
                      --group "codex:blocked" --focus; then
            exit 0
        fi
        ;;
    idle)
        if ! nh_deliver "$title" "done" -- --sound ready \
                      --icon "integration:codex/done" \
                      --group "codex:done" --focus; then
            exit 0
        fi
        ;;
esac

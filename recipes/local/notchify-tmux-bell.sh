#!/bin/sh
# notchify-tmux-bell: LOCAL tmux/byobu alert-bell listener for the
# recipes' bell transport. Runs on the Mac (where notchify lives), not
# on the remote.
#
# A remote agent's hook (a recipe running with NOTCHIFY_TRANSPORT=bell)
# sets its pane title to a "notchify|<icon>|<sound>|<group>|<title>|
# <body>" marker via a passthrough escape and rings the terminal bell.
# That bell rides ssh + tmux to your local terminal. This script, wired
# to the local tmux alert-bell hook, reads the marker out of the pane
# title and replays it as a local notchify. Bells that aren't ours are
# ignored.
#
# Wire it into your LOCAL tmux (~/.tmux.conf) or byobu
# (~/.byobu/.tmux.conf), pointing at wherever you put this file:
#
#   set  -gw monitor-bell on
#   set  -g  @notchify-bell "$HOME/.config/notchify/notchify-tmux-bell.sh"
#   set-hook -g alert-bell 'run-shell -b "#{@notchify-bell} #{pane_id} #{q:pane_title}"'
#
# Use #{pane_id} (the belling pane), not #{hook_pane} -- the latter is empty
# for alert-bell on some tmux builds, which drops the pane and misaligns the
# args. #{q:pane_title} captures the marker at bell-fire time (while the title
# is still ours); the script falls back to reading the live title only if $2
# isn't supplied, which races a remote shell prompt redraw.
#
# Requires the notchify CLI on PATH locally (the same one the recipes
# use). See recipes/README.md, "Remote agents over SSH".
set -eu

# Pane that belled (passed as #{pane_id}); fall back to the active
# pane if tmux didn't supply one.
pane="${1:-}"
[ -n "$pane" ] || pane=$(tmux display -p '#{pane_id}' 2>/dev/null || true)

# Title: prefer the marker the tmux hook captured at bell-fire time and
# passed as $2 (#{q:pane_title}); at that instant the title is still our
# marker, before the remote shell prompt or the agent overwrites it. Only
# re-read the live pane title (racy) when $2 wasn't supplied or isn't ours.
title="${2:-}"
case "$title" in
    notchify\|*) ;;
    *)
        title=""
        [ -n "$pane" ] && title=$(tmux display -p -t "$pane" '#{pane_title}' 2>/dev/null || true)
        [ -n "$title" ] || title=$(tmux display -p '#{pane_title}' 2>/dev/null || true)
        ;;
esac

# Only react to our marker; leave every other bell alone.
case "$title" in
    notchify\|*) ;;
    *) exit 0 ;;
esac

# Dedupe: an unrelated bell arriving while our (sticky) marker is still
# the pane title would otherwise re-fire the last notification. Suppress
# an identical marker seen within a short window. The remote already
# debounces, so this only guards the stale-reread case.
stamp="${TMPDIR:-/tmp}/notchify-bell-last"
now=$(date +%s)
if [ -f "$stamp" ]; then
    IFS='	' read -r last_t last_m < "$stamp" 2>/dev/null || { last_t=0; last_m=""; }
    if [ "$last_m" = "$title" ] && [ $((now - last_t)) -lt 3 ]; then
        exit 0
    fi
fi
printf '%s\t%s' "$now" "$title" > "$stamp" 2>/dev/null || true

# notchify|<icon>|<sound>|<group>|<title>|<body> — split on | with pure
# parameter expansion (no eval/heredoc, so field contents like $ or `
# are never expanded). Fields never contain | (the hook strips it).
rest=${title#notchify|}
icon=${rest%%|*};  rest=${rest#*|}
sound=${rest%%|*}; rest=${rest#*|}
group=${rest%%|*}; rest=${rest#*|}
ttl=${rest%%|*};   rest=${rest#*|}
bdy=$rest
[ -n "$ttl" ]   || ttl="remote agent"
[ -n "$group" ] || group="remote"
[ -n "$icon" ]  || icon="bell.fill"

command -v notchify >/dev/null 2>&1 || exit 0

# Replay the remote's icon/sound/group, then add local click-to-focus:
# when we know the local pane that belled, hand its context to notchify
# via the NOTCHIFY_FOCUS_* injection path (the same one an outer
# launcher like the agentbox sandbox uses). A click then raises this
# terminal and jumps to that pane, and the chip auto-dismisses when you
# return. The daemon resolves the terminal bundle from the client tty;
# if it can't, notchify drops focus and still pops.
set -- "$ttl" "$bdy" --group "$group" --icon "$icon"
[ -n "$sound" ] && set -- "$@" --sound "$sound"
if [ -n "$pane" ]; then
    # #{client_tty} is blank inside the alert-bell hook (no "current"
    # client there), so resolve the terminal tty from the clients
    # attached to the belling pane's session instead.
    f_tty=$(tmux list-clients -t "$pane" -F '#{client_tty}' 2>/dev/null | head -n1)
    if [ -n "$f_tty" ]; then
        NOTCHIFY_FOCUS_TMUX_PANE="$pane"
        NOTCHIFY_FOCUS_TMUX_SOCKET=$(tmux display -p -t "$pane" '#{socket_path}' 2>/dev/null || true)
        NOTCHIFY_FOCUS_TTY="$f_tty"
        export NOTCHIFY_FOCUS_TMUX_PANE NOTCHIFY_FOCUS_TMUX_SOCKET NOTCHIFY_FOCUS_TTY
        # --jump, not --focus: a remote agent's real pane lives in the
        # remote tmux (invisible here), so every sibling agent shares
        # this one local ssh pane. --jump keeps click-to-jump and
        # dismiss-on-return but skips the at-ingress suppression that
        # would otherwise eat each sibling's arrival cue.
        set -- "$@" --jump
    fi
fi
notchify "$@" || exit 0

#!/bin/sh
# Pre-push regression script. Fires a comprehensive sequence of
# notifications to exercise every feature of the daemon. Requires
# notchify-daemon to be running. Walk through it before merging; the
# cases that require human eyes (animation smoothness, accessibility
# tooling, multi-display) are listed in the manual checklist at the
# end of this file. For the user-facing showcase, see demo.sh.
#
# Override the CLI binary via NOTCHIFY env var, useful when iterating
# in-tree without installing:
#   NOTCHIFY=./.build/debug/notchify ./scripts/test.sh
#
# Run a single section by passing its name as the first positional
# argument. Run with no argument to see the list. Most sections need
# the user to hover, click, or switch focus, so "all" exists for
# completeness but isn't fully unattended.
set -eu

# Prefer the in-tree debug build over a system-installed `notchify`
# so `./scripts/test.sh` exercises the current branch's CLI without
# requiring `NOTCHIFY=...` to be set every time.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_CLI="$SCRIPT_DIR/../.build/debug/notchify"
if [ -n "${NOTCHIFY-}" ]; then
    N="$NOTCHIFY"
elif [ -x "$LOCAL_CLI" ]; then
    N="$LOCAL_CLI"
else
    N="notchify"
fi
usage() {
    cat <<'EOF'
usage: test.sh <section>

Sections (run one at a time):
  basic       3 colored singletons with sounds and icons
  actions     URL action and shell action (click the body)
  variants    title-only, short timeout, plain ungrouped coalescing
  persistent  -timeout 0 holds the chip after retract
  stacks      named-group coalescing (claude, make)
  overflow    4 groups, leftmost renders as 40% partial chip
  hover       >3.5 rows, scroll + fade gradients (hover the chip)
  queue       hover-while-arriving engagement gate
  bodies      one-line, two-line wrap, ellipsis tail
  edge        race conditions: mid-slide, mid-retract, click-dismiss
  focus       -focus drop-if-focused and focus-on-return dismiss
  image       custom file-path icon (needs ~/Pictures/claude-icon.png)
  all         run every section sequentially (mostly not unattended)
EOF
}

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

echo "using CLI: $N"
SECTION="$1"

run_section() {
    case "$SECTION" in
        all|"$1") return 0 ;;
        *) return 1 ;;
    esac
}

# Give the user a moment after launching the script to start a
# screen recording (or to position the cursor for hover tests).
sleep 3

# --- Basic singletons: lifecycle, sounds, colors, icons ----------

if run_section basic; then
    echo "[basic] colored singletons with sounds and icons"

    "$N" "Build complete" "your project has been built" \
         -sound success -icon checkmark.circle.fill -color green
    sleep 6

    "$N" "Heads up" "deploy needs your input" \
         -sound warning -icon exclamationmark.triangle.fill -color orange
    sleep 6

    "$N" "Ready" "all systems go" \
         -sound ready -icon asterisk.circle.fill -color white
    sleep 6
fi

# --- Click actions: URL and shell --------------------------------

if run_section actions; then
    echo "[actions] click the body to trigger the action"

    "$N" "Open the link" "tap to launch in browser" \
         -sound info -icon link.circle.fill -color blue \
         -action https://example.com
    sleep 6

    "$N" "Run shell" "click to write /tmp/notchify-demo" \
         -icon terminal.fill -color purple \
         -action 'echo "clicked at $(date)" >> /tmp/notchify-demo'
    sleep 6
fi

# --- Variants: title-only, short timeout, ungrouped coalesce -----

if run_section variants; then
    echo "[variants] empty body, short timeout, default-chip coalescing"

    # Short timeout — quick dismiss.
    "$N" "Quick" "0.8s timeout" -timeout 0.8
    sleep 4

    # Two ungrouped (no icon/color) sent in quick succession: the
    # first is title-only (exercises the empty-body height path),
    # the second arrives during the first's lifecycle so they
    # coalesce into the a:_default chip and join the same livestack.
    "$N" "Plain one"
    sleep 1
    "$N" "Plain two" "shares default chip with above"
    sleep 6

    # Same shape but the second arrival belongs to a different
    # group: it should queue behind the first's livestack, only
    # sliding in after the first retracts. Two chip slots end up
    # side by side on the shelf.
    "$N" "Group A first" "this one shows first" \
         -group var-a -icon a.circle.fill -color blue
    sleep 1
    "$N" "Group B first" "queues until A is done" \
         -group var-b -icon b.circle.fill -color orange
    sleep 10
fi

# --- Persistent (stays as chip until dismissed) ------------------

if run_section persistent; then
    echo "[persistent] -timeout 0 holds the chip after retract"

    "$N" "Migration paused" "click chip to dismiss" \
         -icon pause.circle.fill -color yellow -timeout 0
    sleep 6
fi

# --- Named-group stacking ----------------------------------------

if run_section stacks; then
    echo "[stacks] grouped notifications coalesce under one chip"

    "$N" "Lint clean" "no warnings" \
         -group claude -icon sparkles -color blue -timeout 0
    sleep 2
    "$N" "Tests green" "47 passing" -group claude -timeout 0
    sleep 2
    "$N" "Build done" "ready to commit" -group claude -timeout 0
    sleep 6

    "$N" "Compiling" "make clean && make" \
         -group make -icon hammer.fill -color orange -timeout 0
    sleep 2
    "$N" "Linker error" "undefined symbol _foo" -group make -timeout 0
    sleep 6
fi

# --- Overflow: 3+ groups → partial chip on left ------------------

if run_section overflow; then
    echo "[overflow] 8 groups, then second arrivals zig-zag through them"
    echo "           to exercise the chip-shelf auto-scroll across the"
    echo "           full range (oldest leftmost ↔ newest rightmost)."

    "$N" "G1 first" -group g1 -icon 1.circle.fill -color red     -timeout 0
    sleep 1
    "$N" "G2 first" -group g2 -icon 2.circle.fill -color orange  -timeout 0
    sleep 1
    "$N" "G3 first" -group g3 -icon 3.circle.fill -color yellow  -timeout 0
    sleep 1
    "$N" "G4 first" -group g4 -icon 4.circle.fill -color green   -timeout 0
    sleep 1
    "$N" "G5 first" -group g5 -icon 5.circle.fill -color blue    -timeout 0
    sleep 1
    "$N" "G6 first" -group g6 -icon 6.circle.fill -color purple  -timeout 0
    sleep 1
    "$N" "G7 first" -group g7 -icon 7.circle.fill -color pink    -timeout 0
    sleep 1
    "$N" "G8 first" -group g8 -icon 8.circle.fill -color white   -timeout 0
    sleep 6

    # Zig-zag second arrivals: oldest, newest, near-oldest, near-newest.
    # Each should auto-scroll the chip shelf so the active chip lands
    # in view, then settle back to whatever's active next.
    "$N" "G1 second" "scrolls all the way left" -group g1 -timeout 0
    sleep 6
    "$N" "G8 second" "scrolls all the way right" -group g8 -timeout 0
    sleep 6
    "$N" "G2 second" "scrolls one in from the left" -group g2 -timeout 0
    sleep 6
    "$N" "G7 second" "scrolls one in from the right" -group g7 -timeout 0
    sleep 6
fi

# --- Hover-list scrolling and fades ------------------------------

if run_section hover; then
    echo "[hover] >3.5 rows in one stack → scroll + fade gradients"
    echo "        MOVE THE CURSOR over the chip to see the list expand."

    for i in 1 2 3 4 5 6 7 8 9; do
        "$N" "Hover row $i" "scroll inside the list to see fades" \
             -group hover -icon list.bullet -color blue -timeout 0
        sleep 0.4
    done

    # Hold so the user can hover/scroll/release.
    sleep 12
fi

# --- Engagement: hover-while-arriving ----------------------------

if run_section queue; then
    echo "[queue] hover the pill while these arrive — they queue"
    echo "        silently; release the cursor and they play out."

    "$N" "Engagement test" "now hover the pill — keep cursor on it" \
         -icon hand.point.up.fill -color purple -timeout 0
    sleep 4

    # These four should queue while the cursor is hovering.
    for i in 1 2 3 4; do
        "$N" "Queued $i" "should not slide while you hover" \
             -icon $i.circle.fill -color blue
        sleep 0.5
    done

    sleep 12
fi

# --- Body sizing: short, two-line, very long ---------------------

if run_section bodies; then
    echo "[bodies] one-line vs two-line vs ellipsized body heights"

    "$N" "Short" "fits one line"
    sleep 5

    "$N" "Medium" "this is just long enough that it should wrap onto a second line cleanly"
    sleep 5

    "$N" "Long" \
         "this body is intentionally extremely long to force ellipsis at the end of the second line because line-limit is two and we should see the truncation tail dot dot dot dot dot dot"
    sleep 5
fi

# --- Mid-slide / mid-retract races -------------------------------

if run_section edge; then
    echo "[edge] back-to-back arrivals exercising race-condition paths"

    # Two notifications fired with no gap → second one queues during
    # the first's slide-in (midSlide path).
    "$N" "Race A" "first of a fast pair" -icon a.circle.fill -color red
    "$N" "Race B" "second arrives mid-slide-in"
    sleep 12

    # Send into the same group while the in-flight is mid-retract:
    # the retraction should cancel cleanly and the new one slide in.
    "$N" "Mid-retract A" "watch retract start, then a B arrives" \
         -group race -icon clock.fill -color yellow -timeout 2
    sleep 2.5
    "$N" "Mid-retract B" "should not collide with A's teardown" \
         -group race
    sleep 8

    # Click-to-dismiss the in-flight before its dwell finishes.
    # (Manual: actually click on the body when it appears.)
    echo "[edge] CLICK the next notification's body before the timer"
    "$N" "Click me" "click the body now to dismiss early" \
         -icon hand.tap.fill -color pink
    sleep 8
fi

# --- Focus auto-dismiss ------------------------------------------

if run_section focus; then
    echo "[focus] -focus drops if source already focused; otherwise"
    echo "        polls 1Hz and dismisses when source becomes focused."

    # Sent FROM the current terminal: if Terminal/iTerm/etc is focused
    # right now, the notification should be dropped immediately
    # (look for "source already focused, dropping" in daemon log).
    "$N" "Already focused" "should drop if you ran this from the terminal" \
         -focus -icon eye.fill -color gray
    sleep 4

    echo "[focus] now switch away from the terminal within 3 seconds:"
    sleep 3
    # The user is hopefully in another app now; this notification
    # should appear as a chip and auto-dismiss when they Cmd-Tab back.
    "$N" "Visit me" "switch back to the source terminal to dismiss me" \
         -focus -icon arrow.uturn.left.circle.fill -color blue
    sleep 15
fi

# --- Image-file icon ---------------------------------------------

if run_section image; then
    echo "[image] custom file-path icon (skipped if path missing)"
    if [ -f "$HOME/Pictures/claude-icon.png" ]; then
        "$N" "Claude finished" "ready for review" \
             -group claude-image -icon "$HOME/Pictures/claude-icon.png" -timeout 0
        sleep 6
    else
        echo "        (place a PNG at ~/Pictures/claude-icon.png to enable)"
    fi
fi

echo "test done."

# =================================================================
# MANUAL TESTS — things this script can't verify on its own.
# =================================================================
# These need human judgment, special hardware, or interactions the
# CLI can't drive. Walk through them before merging.
#
# Hardware / display
#   - External monitor connected, lid open: pill renders on built-in.
#   - Clamshell (lid closed, external only): notifications dropped.
#   - Connect / disconnect external display mid-notification: pill
#     replays cleanly on new geometry.
#
# Cursor-driven (script can fire, but you have to hover/click)
#   - Click chip to dismiss top row of a stack; repeat clicks remove
#     successively older rows.
#   - Hover one chip, then move to another: list A fades out, B fades
#     in (remount via .id).
#   - Move cursor between slot ↔ list area: no flicker (debounced
#     clear).
#   - Hover slot whose only row is the in-flight: list does NOT
#     expand (would just dup the body).
#   - Hover during in-flight on a different stack: body hides, list
#     of hovered stack shows; un-hover restores body.
#   - Hover a chip during a notification's retraction: the just-
#     dismissed row should NOT reappear in the list (inRetraction
#     guard).
#   - First click on a freshly slid-in pill registers (FirstMouseHosting
#     fix; clicks should not be swallowed).
#
# Accessibility (use VoiceOver / Accessibility Inspector)
#   - Chip slot announces as button with "Show <stackID> notifications"
#     label.
#   - In-flight body announces as "Dismiss notification" or "Open
#     notification" depending on -action.
#   - Row in hover list announces title appropriately.
#
# DND
#   - Enable Do Not Disturb, then run [singletons] section: no sound,
#     no slide-in animation, but the chip + row should still be there
#     and the user can hover to read.
#   - Disable DND while a chip is up: existing chip stays; new
#     arrivals resume normal lifecycle.
#
# Lifecycle
#   - Click menubar → Quit: daemon exits, launchd does NOT respawn
#     (KeepAlive SuccessfulExit=false).
#   - `kill -9` the daemon: launchd respawns it.
#
# Performance / soak
#   - Run [overflow], [hover], [queue], [edge] back-to-back: no
#     visible hitching during animations.
#   - Leave the daemon running for an hour with periodic sends: no
#     memory growth, no leaked tasks.

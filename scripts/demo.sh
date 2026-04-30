#!/bin/sh
# Fires a sequence of sample notifications with pauses between them so a
# screen recording can capture each animation cleanly. Requires
# notchify-daemon to be running.
#
# Override the CLI binary via NOTCHIFY env var, useful when iterating
# in-tree without installing:
#   NOTCHIFY=./.build/debug/notchify ./scripts/demo.sh
set -eu

N="${NOTCHIFY:-notchify}"

# Give the user a moment after launching the script to start their
# screen recording.
sleep 3

# --- Singletons ---------------------------------------------------

"$N" "Build complete" "your project has been built" \
     -sound success -icon checkmark.circle.fill -color green
sleep 6

"$N" "Heads up" "deploy needs your input" \
     -sound warning -icon exclamationmark.triangle.fill -color orange
sleep 6

"$N" "Open the link" "tap to launch in browser" \
     -sound info -icon link.circle.fill -color blue \
     -action https://example.com
sleep 6

"$N" "Ready" "all systems go" \
     -sound ready -icon asterisk.circle.fill -color white
sleep 6

# --- Persistent (stays in the chip until clicked) -----------------

"$N" "Migration paused" "click to dismiss" \
     -icon pause.circle.fill -color yellow -timeout 0
sleep 6

# --- Stacking under a named group ---------------------------------
# The first call sets the chip's icon and color; subsequent calls
# under the same -group just bump the count badge.

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

# --- Custom image-file icon (use any png/jpg on disk) -------------

# Uncomment with a real path:
# "$N" "Claude finished" "ready for review" \
#      -group claude -icon ~/Pictures/claude-icon.png -timeout 0

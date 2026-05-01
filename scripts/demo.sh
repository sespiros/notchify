#!/bin/sh
# User-facing showcase. A short, visually interesting tour of
# notchify's main features, suitable for screen recording or for
# someone trying the daemon for the first time. Requires
# notchify-daemon to be running.
#
# Override the CLI binary via NOTCHIFY env var, useful when iterating
# in-tree without installing:
#   NOTCHIFY=./.build/debug/notchify ./scripts/demo.sh
#
# For the comprehensive pre-push regression script, see test.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_CLI="$SCRIPT_DIR/../.build/debug/notchify"
if [ -n "${NOTCHIFY-}" ]; then
    N="$NOTCHIFY"
elif [ -x "$LOCAL_CLI" ]; then
    N="$LOCAL_CLI"
else
    N="notchify"
fi
echo "using CLI: $N"

# Give the user a moment to start a screen recording.
sleep 3

# --- Singletons: colors, icons, sounds, click-to-open ------------

echo "[demo] colorful one-shot notifications"

"$N" "Build complete" "your project has been built" \
     -sound success -icon checkmark.circle.fill -color green
sleep 6

"$N" "Heads up" "deploy needs your input" \
     -sound warning -icon exclamationmark.triangle.fill -color orange
sleep 6

"$N" "Open the link" "click the body to launch in browser" \
     -sound info -icon link.circle.fill -color blue \
     -action https://example.com
sleep 6

# --- Named-group stacking ----------------------------------------

echo "[demo] grouped notifications coalesce under one chip"

"$N" "Lint clean" "no warnings" \
     -group claude -icon sparkles -color blue -timeout 0
sleep 2
"$N" "Tests green" "47 passing" -group claude -timeout 0
sleep 2
"$N" "Build done" "ready to commit" -group claude -timeout 0
sleep 6

# --- Multi-stack: hover any chip to expand its list --------------

echo "[demo] multiple stacks coexist; hover a chip to expand it"

"$N" "Compiling" "make clean && make" \
     -group make -icon hammer.fill -color orange -timeout 0
sleep 2
"$N" "Linker error" "undefined symbol _foo" -group make -timeout 0
sleep 2
"$N" "Deploying" "rolling out v1.2.3" \
     -group deploy -icon paperplane.fill -color purple -timeout 0
sleep 8

echo "demo done."

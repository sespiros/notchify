#!/bin/sh
# Fires a sequence of sample notifications with pauses between them so a
# screen recording can capture each animation cleanly. Requires the
# notchify CLI on PATH and notchify-daemon running.
set -eu

# Give the user a moment after launching the script to start their
# screen recording.
sleep 3

notchify -title "Build complete"  -text "your project has been built" \
         -sound success -symbol checkmark.circle.fill -color green
sleep 6

notchify -title "Heads up"        -text "deploy needs your input" \
         -sound warning -symbol exclamationmark.triangle.fill -color orange
sleep 6

notchify -title "Open the link"   -text "tap to launch in browser" \
         -sound info -symbol link.circle.fill -color blue \
         -action https://example.com
sleep 6

notchify -title "Ready"           -text "all systems go" \
         -sound ready -symbol asterisk.circle.fill -color white

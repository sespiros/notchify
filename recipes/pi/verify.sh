#!/bin/sh
# Return 0 if the extension file and icons are still present, 1 otherwise.
set -eu
NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

ext="$NR_PREFIX/.pi/agent/extensions/notchify-agent-state.ts"
done_icon="$NR_PREFIX/.config/pi/icons/done.png"
blocked_icon="$NR_PREFIX/.config/pi/icons/blocked.png"

[ -f "$ext" ] || exit 1
[ -f "$done_icon" ] || exit 1
[ -f "$blocked_icon" ] || exit 1

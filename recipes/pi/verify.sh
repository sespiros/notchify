#!/bin/sh
# Return 0 if the extension file is still present, 1 otherwise.
# (Icons ship inside the notchify app and are referenced as
# integration:pi/<variant>, so there's nothing under .config to check.)
set -eu
NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

ext="$NR_PREFIX/.pi/agent/extensions/notchify-agent-state.ts"

[ -f "$ext" ] || exit 1

#!/bin/sh
# Install the pi recipe: the extension under $prefix. (Icons ship in
# the notchify app, referenced as integration:pi/<variant>.)
# Pi auto-discovers extensions from ~/.pi/agent/extensions/*.ts so no
# config-file merging is needed (unlike Claude Code / Codex hooks).
set -eu

NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

nr_log "pi recipe v$(nr_version)"
nr_install_files

nr_stamp pi
nr_log "done. New pi sessions will pick up the extension; running sessions need /reload."

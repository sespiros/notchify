#!/bin/sh
# Install the claude-code recipe: hook script under $prefix, and merge
# hook registrations into $prefix/.claude/settings.json. (Icons ship in
# the notchify app, referenced as integration:claude-code/<variant>.)
set -eu

NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

nr_log "claude-code recipe v$(nr_version)"
nr_install_files

hook_path="$NR_PREFIX/.claude/hooks/notchify-agent-state.sh"
nr_hooks_register "$NR_PREFIX/.claude/settings.json" "$hook_path" \
    "Stop:idle" \
    "Notification:blocked"

nr_stamp claude-code
nr_log "done. Claude Code's settings file watcher will pick up the new hooks."

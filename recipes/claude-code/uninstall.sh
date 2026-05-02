#!/bin/sh
set -eu
NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

hook_path="$NR_PREFIX/.claude/hooks/notchify-agent-state.sh"
nr_hooks_unregister "$NR_PREFIX/.claude/settings.json" "$hook_path"
nr_remove_files
nr_unstamp claude-code
nr_log "uninstalled."

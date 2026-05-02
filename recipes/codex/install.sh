#!/bin/sh
# Install the codex recipe: hook script + icons under $prefix, and
# merge notchify hook registrations into $prefix/.codex/hooks.json
# alongside whatever other entries already live there (e.g. a
# tmux-statusline hook installed via dotfiles).
set -eu

NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

nr_log "codex recipe v$(nr_version)"
nr_install_files

hook_path="$NR_PREFIX/.codex/hooks/notchify-agent-state.sh"
nr_hooks_register "$NR_PREFIX/.codex/hooks.json" "$hook_path" \
    "Stop:idle" \
    "Notification:blocked"

nr_stamp codex
nr_log "done. New codex sessions will pick up the hooks; running sessions may need a restart."

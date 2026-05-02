#!/bin/sh
# Detect drift in claude's settings.json: confirm that the recipe's
# Stop and Notification registrations for notchify-agent-state.sh
# are still present. Returns nonzero if any were dropped (e.g. by
# chezmoi rewriting the file).
set -eu
NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

hook_path="$NR_PREFIX/.claude/hooks/notchify-agent-state.sh"
nr_hooks_verify "$NR_PREFIX/.claude/settings.json" "$hook_path" Stop Notification

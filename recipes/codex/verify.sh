#!/bin/sh
# Detect drift in codex's hooks.json: confirm that the recipe's Stop
# and PermissionRequest registrations for notchify-agent-state.sh are
# still present. Returns nonzero if either was dropped (e.g. by
# chezmoi rewriting the file).
set -eu
NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

hook_path="$NR_PREFIX/.codex/hooks/notchify-agent-state.sh"
nr_hooks_verify "$NR_PREFIX/.codex/hooks.json" "$hook_path" Stop PermissionRequest

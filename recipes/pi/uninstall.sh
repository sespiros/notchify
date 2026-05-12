#!/bin/sh
set -eu
NR_RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$NR_RECIPE_DIR/../lib/install-common.sh"

nr_remove_files
nr_unstamp pi
nr_log "uninstalled."

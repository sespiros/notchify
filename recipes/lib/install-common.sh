#!/bin/sh
# Shared helpers sourced by every recipe's install.sh / uninstall.sh.
# Recipes set NR_RECIPE_DIR before sourcing.
#
# Inputs (env, set by notchify-recipes wrapper):
#   NOTCHIFY_PREFIX     destination root (default: $HOME)
#   NOTCHIFY_DRY_RUN    if non-empty, print actions without executing
#   NOTCHIFY_RECIPE_DIR path to the recipe directory
#
# Convention: files under $NR_RECIPE_DIR/files/ are mirrored into
# $prefix/. A trailing .tmpl on a filename means the file is a
# template: __HOME__ is substituted with $HOME and the .tmpl suffix
# stripped on install.

set -eu

NR_PREFIX="${NOTCHIFY_PREFIX:-$HOME}"
NR_DRY_RUN="${NOTCHIFY_DRY_RUN:-}"
NR_RECIPE_DIR="${NOTCHIFY_RECIPE_DIR:-${NR_RECIPE_DIR:-}}"
[ -n "$NR_RECIPE_DIR" ] || { echo "install-common: NR_RECIPE_DIR unset" >&2; exit 2; }

nr_log() { printf '  %s\n' "$*"; }

nr_run() {
    if [ -n "$NR_DRY_RUN" ]; then
        printf '  [dry-run] %s\n' "$*"
    else
        eval "$@"
    fi
}

nr_need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: %s not found on PATH. %s\n' "$1" "${2:-}" >&2
        exit 1
    }
}

# Copy every file under <recipe>/files/ to $prefix, preserving relative
# paths. .tmpl files are rendered (sed-substitute __HOME__) and the
# .tmpl suffix stripped. Hook scripts (*.sh) keep executable bit.
nr_install_files() {
    src="$NR_RECIPE_DIR/files"
    [ -d "$src" ] || return 0
    # find -print0 isn't portable; rely on no-newlines-in-paths.
    find "$src" -type f | while IFS= read -r srcfile; do
        rel="${srcfile#$src/}"
        case "$rel" in
            *.tmpl) dest_rel="${rel%.tmpl}"; tmpl=1 ;;
            *)      dest_rel="$rel";          tmpl=0 ;;
        esac
        dest="$NR_PREFIX/$dest_rel"
        nr_log "install $dest_rel"
        if [ -n "$NR_DRY_RUN" ]; then
            printf '  [dry-run] write %s\n' "$dest"
            continue
        fi
        mkdir -p "$(dirname "$dest")"
        if [ "$tmpl" = 1 ]; then
            sed "s|__HOME__|$HOME|g" "$srcfile" > "$dest.new"
            mv "$dest.new" "$dest"
        else
            cp "$srcfile" "$dest"
        fi
        case "$dest" in
            *.sh) chmod 755 "$dest" ;;
        esac
    done
}

# Reverse of nr_install_files: remove every file the recipe would have
# installed. Empty directories are left alone (they may belong to
# other tools).
nr_remove_files() {
    src="$NR_RECIPE_DIR/files"
    [ -d "$src" ] || return 0
    find "$src" -type f | while IFS= read -r srcfile; do
        rel="${srcfile#$src/}"
        case "$rel" in
            *.tmpl) dest_rel="${rel%.tmpl}" ;;
            *)      dest_rel="$rel" ;;
        esac
        dest="$NR_PREFIX/$dest_rel"
        if [ -e "$dest" ]; then
            nr_log "remove $dest_rel"
            nr_run "rm -f '$dest'"
        fi
    done
}

# Merge hook entries into a hooks-style JSON file (claude's
# settings.json or codex's hooks.json — both share the same
# top-level shape: { "hooks": { "<event>": [ { "hooks": [{ ... }] } ] } }).
# Any existing entry whose command references $hook_path is removed
# first so re-runs don't duplicate. Other tools' entries are
# preserved (chezmoi-managed statusline registrations, etc).
#
# Args: hooks_file hook_path event_name:state_arg [event_name:state_arg ...]
# Example:
#   nr_hooks_register "$HOME/.claude/settings.json" \
#       "$HOME/.claude/hooks/notchify-agent-state.sh" \
#       "Stop:idle" "Notification:blocked"
nr_hooks_register() {
    nr_need jq "Install with: brew install jq"
    settings="$1"; shift
    hook_path="$1"; shift

    mkdir -p "$(dirname "$settings")"
    [ -f "$settings" ] || echo '{}' > "$settings"

    # Validate parseable JSON before touching it.
    jq -e . "$settings" >/dev/null 2>&1 || {
        echo "error: $settings is not valid JSON; refusing to mutate" >&2
        return 1
    }

    if [ -n "$NR_DRY_RUN" ]; then
        printf '  [dry-run] register hooks in %s\n' "$settings"
        for spec; do printf '  [dry-run]   %s\n' "$spec"; done
        return 0
    fi

    backup="$settings.notchify-recipes.bak.$(date +%Y%m%d%H%M%S)"
    cp "$settings" "$backup"
    nr_log "backup $backup"

    # Build arg list of "event state" pairs for jq.
    tmp="$settings.new"
    {
        # First, drop any existing entries pointing at $hook_path.
        # Then add fresh entries.
        jq --arg hp "$hook_path" '
            (.hooks // {}) as $h
            | .hooks = (
                $h
                | with_entries(
                    .value |= map(
                        .hooks |= map(select((.command // "") | contains($hp) | not))
                    )
                    | .value |= map(select((.hooks | length) > 0))
                  )
                | with_entries(select((.value | length) > 0))
              )
        ' "$settings" > "$tmp"

        # Now append our entries one event at a time.
        for spec; do
            event="${spec%%:*}"
            state="${spec#*:}"
            mv "$tmp" "$tmp.in"
            jq --arg ev "$event" --arg cmd "sh '$hook_path' $state" '
                .hooks //= {}
                | .hooks[$ev] //= []
                | .hooks[$ev] += [{
                    "matcher": "*",
                    "hooks": [{ "type": "command", "command": $cmd }]
                  }]
            ' "$tmp.in" > "$tmp"
            rm -f "$tmp.in"
        done
    }
    mv "$tmp" "$settings"
    nr_log "merged hooks into $settings"
}

# Drop our entries from a hooks-style JSON file. Safe if the file
# or the entries don't exist.
#
# Args: hooks_file hook_path
nr_hooks_unregister() {
    settings="$1"
    hook_path="$2"
    [ -f "$settings" ] || return 0
    nr_need jq "Install with: brew install jq"
    if [ -n "$NR_DRY_RUN" ]; then
        printf '  [dry-run] unregister hooks from %s\n' "$settings"
        return 0
    fi
    tmp="$settings.new"
    jq --arg hp "$hook_path" '
        if .hooks then
            .hooks |= (
                with_entries(
                    .value |= map(
                        .hooks |= map(select((.command // "") | contains($hp) | not))
                    )
                    | .value |= map(select((.hooks | length) > 0))
                  )
                | with_entries(select((.value | length) > 0))
            )
        else .
        end
    ' "$settings" > "$tmp"
    mv "$tmp" "$settings"
    nr_log "removed hook entries from $settings"
}

# Verify that all expected (event, hook_path) registrations are
# still present in a hooks-style JSON file. Returns 0 if everything
# is present, 1 otherwise. Silent: callers (recipe verify.sh,
# notchify-recipes status) just want a binary "needs reinstall"
# signal, not per-event detail.
#
# Args: hooks_file hook_path event_name [event_name ...]
nr_hooks_verify() {
    nr_need jq "Install with: brew install jq"
    settings="$1"; shift
    hook_path="$1"; shift
    [ -f "$settings" ] || return 1
    for event; do
        present=$(jq --arg ev "$event" --arg hp "$hook_path" '
            (.hooks[$ev] // []) | map(.hooks[]?.command // "")
            | map(select(contains($hp))) | length
        ' "$settings" 2>/dev/null || echo 0)
        [ "$present" -ge 1 ] || return 1
    done
    return 0
}

# Read the recipe's VERSION file. Default "0".
nr_version() {
    if [ -f "$NR_RECIPE_DIR/VERSION" ]; then
        head -n 1 "$NR_RECIPE_DIR/VERSION"
    else
        echo 0
    fi
}

# Stamp / unstamp the installed-version marker.
nr_stamp() {
    name="$1"
    dir="$NR_PREFIX/.config/notchify/installed"
    nr_run "mkdir -p '$dir'"
    nr_run "echo '$(nr_version)' > '$dir/$name'"
}
nr_unstamp() {
    name="$1"
    f="$NR_PREFIX/.config/notchify/installed/$name"
    [ -e "$f" ] || return 0
    nr_run "rm -f '$f'"
}

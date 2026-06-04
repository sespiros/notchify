#!/bin/sh
# Install a notchify agent hook on a REMOTE host (Linux or macOS) that
# has no notchify app — for agents you reach over ssh+tmux and want to
# surface on your Mac's notch via the bell transport.
#
# Run this ON THE REMOTE, from a checkout of this repo:
#
#   git clone --depth 1 <notchify-repo> ~/notchify
#   sh ~/notchify/recipes/remote-install.sh claude-code
#
# It lays down the hook script and registers it in the agent's config
# (exactly what the macOS app's Integrations menu does locally), but
# does NOT require the notchify CLI: in bell mode the hook only emits
# terminal escapes, so there's nothing to talk to on this host.
set -eu

recipe="${1:-}"
case "$recipe" in
    claude-code|codex) ;;
    *) echo "usage: remote-install.sh <claude-code|codex>" >&2; exit 2 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
command -v jq >/dev/null 2>&1 || {
    echo "remote-install: needs jq (e.g. 'apt install jq' / 'dnf install jq')" >&2
    exit 1
}

sh "$here/$recipe/install.sh"

cat <<EOF

Hook for '$recipe' installed on this host. Two more steps here:

  1. Select the bell transport (so the hook emits a terminal bell
     instead of looking for a local daemon). Add to your shell rc
     (~/.bashrc / ~/.zshrc / ~/.profile), then re-login:

       export NOTCHIFY_TRANSPORT=bell

  2. Let tmux carry the marker out, including from background panes.
     Add to this host's ~/.tmux.conf:

       set -g allow-passthrough on
       set -g bell-action any
       set -g visual-bell off

Then, ONCE on your Mac, wire the local listener that turns the bell
into a notch. See recipes/README.md -> "Remote agents over SSH".
EOF

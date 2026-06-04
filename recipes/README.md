# Notchify integrations (recipes)

Drop-in hooks that wire popular AI agents to `notchify`. Each recipe
is a self-contained directory under this folder; installing one drops
its hook scripts and icons into the right places under `$HOME` and
registers the events with the agent.

Currently shipped:

- **claude-code** — Claude Code: popup on Stop / Notification, with
  optional `/rename` session title and tool-aware blocked-message
  hints.
- **codex** — OpenAI Codex CLI: popup on Stop, with assistant
  handoffs classified as waiting-for-input, plus PermissionRequest
  popups when Codex asks for approval.
- **pi** — Pi coding harness: popup on `agent_end` when the agent
  becomes idle. Uses a Pi extension (`~/.pi/agent/extensions/*.ts`)
  so no config-file registration is required; run `/reload` in a live
  session to pick up the extension.

Both work with or without tmux. iTerm, Terminal.app, Ghostty, WezTerm,
kitty all supported.
For agents on a remote host reached over ssh, see
[Remote agents over SSH](#remote-agents-over-ssh) below.

## Install

Recipes require the `notchify` CLI to be installed system-wide first.
Use the Notchify menubar item **Install CLI in /usr/local/bin**; hooks
call `notchify` by name so they keep working independently of where
the app bundle lives.

Easiest path is the **Integrations** submenu in the notchify menubar
icon. Click an integration to install or update; the menu also
surfaces drift (a red dot) when an external tool, e.g. chezmoi or
hand-edits, has dropped notchify's hook registrations from the live
file, or when an installed recipe can no longer find the CLI.

CLI alternative (mirrors what the menu does):

```sh
notchify-recipes list
notchify-recipes install claude-code
notchify-recipes install codex
notchify-recipes status
notchify-recipes uninstall claude-code
```

Requires `jq` (used to merge our hook entries into the agent's
existing `settings.json` / `hooks.json` without clobbering anything
else):

```sh
brew install jq
```

## What a recipe install does

For each recipe:

1. Lays down the hook script under `~/.<agent>/hooks/`.
2. Idempotently merges supported hook registrations into the agent's
   config file (`~/.claude/settings.json` for Claude Code,
   `~/.codex/hooks.json` for Codex). Claude Code registers `Stop` and
   `Notification`; Codex registers `Stop` and `PermissionRequest`.
   Other tools' entries in the same file are preserved.
3. Records the installed version under
   `~/.config/notchify/installed/<recipe>` so the menubar drift
   indicator can compare against the bundled version.

Icons are not installed; they ship inside the notchify app and hooks
reference them as `integration:<recipe>/<variant>`.

Re-running an install is a clean upsert — safe whenever you want to
re-sync after an agent or chezmoi update.

## Drift detection

External tools (chezmoi, hand-edits, agent updates) can rewrite the
agent's config file and drop our entries. The Integrations menu
shows a red bullet on any recipe whose registrations are missing
from the live file, or whose `notchify` CLI prerequisite is missing.
The same signal is available from the CLI:

```sh
notchify-recipes status
```

Exits non-zero if anything has drifted.

## Click-through behavior

Each recipe fires popups with `--focus` (persistent, click-to-jump,
auto-dismiss when you return to the source terminal). The recipe
runs `notchify` synchronously so the CLI can correctly resolve the
calling terminal's bundle id; backgrounding with `&` would orphan
the process to launchd before bundle detection completes, breaking
both the click action and the dismiss-on-return behavior.

## Remote agents over SSH

The recipes also work for agents running on a remote host you reach
over `ssh` + `tmux`, with the notch on your Mac.
There's no notchify daemon (or app) on the remote, so the hook can't
talk to a socket there.
Instead it falls back to a terminal bell that rides the existing
ssh + tmux stream back to your Mac, where a local tmux hook turns it
into a notch.

The hook picks its delivery via the `NOTCHIFY_TRANSPORT` env var:

- `direct` (default) the `notchify` CLI talks to the local daemon
  (Unix socket, or its loopback-TCP fallback). Use on your Mac.
- `bell` no CLI/daemon needed; set the pane title to a
  `notchify|<icon>|<sound>|<group>|<title>|<body>` marker
  (passthrough-wrapped inside tmux so it escapes even a background
  pane) and ring the bell. The local listener replays those fields.
- `auto` try the CLI, fall back to `bell`.

### On the remote host (Linux or macOS)

The macOS app's Integrations menu only installs locally, so install
the hook directly from a checkout, no app or `notchify` CLI required:

```sh
git clone --depth 1 <notchify-repo> ~/notchify
sh ~/notchify/recipes/remote-install.sh claude-code   # or: codex
```

Then, on the remote, select the bell transport and let tmux carry the
marker out of background panes:

```sh
# shell rc (~/.bashrc / ~/.zshrc / ~/.profile), then re-login:
export NOTCHIFY_TRANSPORT=bell

# remote ~/.tmux.conf:
set -g allow-passthrough on
set -g bell-action any
set -g visual-bell off
```

### On your Mac (one-time)

Wire the local listener into your local tmux (or byobu) so a remote
agent's bell becomes a notch.
You must launch `ssh` from inside this local tmux for the hook to be
in the path.

```sh
# ~/.tmux.conf (or ~/.byobu/.tmux.conf for byobu):
set  -gw monitor-bell on
set  -g  @notchify-bell "/path/to/notchify/recipes/local/notchify-tmux-bell.sh"
set-hook -g alert-bell 'run-shell -b "#{@notchify-bell} #{hook_pane}"'
```

### Caveats

The bell transport carries the title, body, icon, sound, and group in
the marker, so done-vs-blocked shows the right icon and sound just like
the daemon transport.
Click-to-focus works too: the listener hands notchify the local ssh
pane's context, so a click raises this terminal and jumps to that pane
(auto-dismissing when you return).
It lands on the ssh session, not the specific remote window, since all
agents on a host share one local pane.
It does require a local tmux wrapping the ssh session; a bare terminal
has nowhere to host the `alert-bell` hook.
Per-agent labels stay correct across concurrent agents (the passthrough
marker escapes background panes), with one narrow race: two agents that
bell within milliseconds can momentarily share the single pane-title
slot, so one's marker may be read for the other.
If you need zero races, or a setup with no local tmux, run the daemon
transport over an ssh reverse tunnel instead (`NOTCHIFY_TRANSPORT`
unset/`direct`, with the CLI's `NOTCHIFY_TCP_*` pointed through `ssh -R`
at your Mac's daemon).

## Authoring a recipe

A recipe is a directory with this layout:

```
recipes/<name>/
  install.sh        # idempotent install: copies files + jq-merges registrations
  uninstall.sh      # symmetric removal
  verify.sh         # exits 0 if registrations are still present, 1 otherwise
  VERSION           # plain integer; bump on any user-visible change
  files/            # files mirrored verbatim into $HOME (and templates)
    .<agent>/...
  icons/            # source icons bundled into the app, not installed
```

The shared install machinery lives in `recipes/lib/install-common.sh`;
existing recipes are short and read more clearly than a full
specification. Steal the patterns from `claude-code/` or `codex/`.
Bumping the recipe's `VERSION` after a change makes the menu surface
"update available" on existing installs.

## Tests

Smoke tests live at the repo root:

```sh
scripts/test-recipes.sh
```

Covers install / re-install (idempotency) / co-existence with another
tool's entries / uninstall / drift detection.

# Notchify integrations (recipes)

Drop-in hooks that wire popular AI agents to `notchify`. Each recipe
is a self-contained directory under this folder; installing one drops
its hook scripts and icons into the right places under `$HOME` and
registers the events with the agent.

Currently shipped:

- **claude-code** — Claude Code: popup on Stop / Notification, with
  optional `/rename` session title and tool-aware blocked-message
  hints.
- **codex** — OpenAI Codex CLI: popup on Stop / Notification.

Both work with or without tmux. iTerm, Terminal.app, Ghostty, WezTerm,
kitty all supported.

## Install

Easiest path is the **Integrations** submenu in the notchify menubar
icon. Click an integration to install or update; the menu also
surfaces drift (a red dot) when an external tool, e.g. chezmoi or
hand-edits, has dropped notchify's hook registrations from the live
file.

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
2. Lays down icons under `~/.config/<agent>/icons/`.
3. Idempotently merges hook registrations for `Stop` and
   `Notification` into the agent's config file (`~/.claude/settings.json`
   for Claude Code, `~/.codex/hooks.json` for Codex). Other tools'
   entries in the same file are preserved.
4. Records the installed version under
   `~/.config/notchify/installed/<recipe>` so the menubar drift
   indicator can compare against the bundled version.

Re-running an install is a clean upsert — safe whenever you want to
re-sync after an agent or chezmoi update.

## Drift detection

External tools (chezmoi, hand-edits, agent updates) can rewrite the
agent's config file and drop our entries. The Integrations menu
shows a red bullet on any recipe whose registrations are missing
from the live file; clicking re-installs. The same signal is
available from the CLI:

```sh
notchify-recipes status
```

Exits non-zero if anything has drifted.

## Click-through behavior

Each recipe fires popups with `-focus` (persistent, click-to-jump,
auto-dismiss when you return to the source terminal). The recipe
runs `notchify` synchronously so the CLI can correctly resolve the
calling terminal's bundle id; backgrounding with `&` would orphan
the process to launchd before bundle detection completes, breaking
both the click action and the dismiss-on-return behavior.

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
    .config/<agent>/icons/...
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

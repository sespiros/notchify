<h1 align="center">
  <br>
  <img src="Resources/AppIcon.png" alt="Notchify" width="128">
  <br>
  notchify
  <br>
</h1>

<h4 align="center">Ephemeral notifications that drop out of the MacBook camera notch.</h4>

<p align="center">
  <img src="Resources/demo.gif" alt="Notchify demo" width="720">
</p>

## Use

```sh
notchify -title "Done"     -text "build succeeded"      -sound ready
notchify -title "Heads up" -text "deploy needs input"   -sound warning -symbol exclamationmark.triangle.fill -color orange
notchify -title "Open"     -text "tap me"               -action https://example.com
```

## Flags

| flag | meaning |
|------|---------|
| `-title <s>` | title (required) |
| `-text <s>` | subtitle (required) |
| `-symbol <name>` | SF Symbol name |
| `-color <name>` | tint for `-symbol` (orange/red/blue/...) |
| `-icon <path>` | image file (used if no `-symbol`) |
| `-sound <name>` | `ready` / `warning` / `info` / `success` / `error`, or any name from `/System/Library/Sounds/` |
| `-action <url\|cmd>` | URL opened or shell command run on tap |
| `-timeout <secs>` | auto-dismiss seconds (default 5) |

## Motivation

Built for **ephemeral** notifications, the kind you might want from
multiple coding agents running in parallel, where dozens of entries
piling up in macOS Notification Center is the opposite of useful.
Notchify never touches Notification Center; once a notification
animates away it's gone, no history.

## Installation

Drag-install:

1. Grab the latest `Notchify.dmg` from Releases (or run `./scripts/package.sh`
   and use the produced `dist/Notchify.dmg`).
2. Open the DMG and drag `Notchify.app` to `/Applications`.
3. First launch may require right-click → Open (the bundle is ad-hoc-signed,
   not Developer-ID-signed).
4. Click the menubar icon → **Install CLI in /usr/local/bin** (creates the
   symlink with the standard macOS admin prompt). Skip if you only need
   the GUI.
5. Optional: same menu → **Launch at Login**.

Nix-darwin: see [Nix-darwin](#nix-darwin) below.

## Build

See [BUILDING.md](BUILDING.md).

## Behavior

- Click the rectangle: runs `-action` (if any) and retracts.
- Hover: pauses auto-dismiss until you mouse away.
- Multiple notifications queue and play in order.
- Focus / Do-Not-Disturb active: drops silently.
- Renders only when macOS reports an active built-in notched display.
- Uses macOS screen geometry APIs to anchor the overlay to the built-in notch area, even with an external monitor attached.

## Nix-darwin

A flake is provided. Add the input and import the module:

```nix
{
  inputs.notchify.url = "ssh://git@git.seimenis.cloud:2222/sespiros/notchify.git";

  outputs = { self, nix-darwin, notchify, ... }: {
    darwinConfigurations."mybox" = nix-darwin.lib.darwinSystem {
      modules = [
        notchify.darwinModules.default
        { programs.notchify.enable = true; }
      ];
    };
  };
}
```

The build uses host Xcode.app for the macOS 13+ Swift toolchain, so
`darwin-rebuild` needs `--impure`:

```sh
darwin-rebuild switch --flake . --impure
```

This installs both the `notchify` CLI on PATH and `Notchify.app` to
`/Applications`.

## Example agent integration

Coding agents like Claude Code, Codex CLI, opencode, and others expose
event hooks. Wiring a hook to `notchify` gives you a quick visual cue
when the agent finishes a turn or asks for permission, without
anything ending up in Notification Center.

The pattern is the same for any agent:

1. Install a small hook script that calls `notchify` with the right
   sound + symbol for that lifecycle event.
2. Register the script in the agent's hook config.

Example hook script (`~/.config/<agent>/hooks/notchify-state.sh`):

```sh
#!/bin/sh
state="${1:-}"
text="Agent in $(basename "$PWD")"

case "$state" in
  done)
    notchify -title "Agent done"        -text "$text" \
             -sound ready -symbol checkmark.circle.fill -color green
    ;;
  blocked)
    notchify -title "Agent needs input" -text "$text" \
             -sound warning -symbol exclamationmark.triangle.fill -color orange
    ;;
esac
```

Register `done` / `blocked` against the agent's equivalent of "Stop" /
"PermissionRequest" hooks (different agents call them different things;
see your agent's hook documentation).

A more complete real-world hook (per-tab tmux state, focus-aware,
extracts `/rename` session name) lives in
[`examples/claude-code-tmux/`](./examples/claude-code-tmux/).

## Inspiration

- [cmux](https://github.com/manaflow-ai/cmux), multi-agent terminal manager.
- [herdr](https://github.com/ogulcancelik/herdr), agent-aware terminal
  multiplexer.
- [notchi](https://github.com/sk-ruban/notchi), notch-area utility on
  macOS.

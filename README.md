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
notchify "Done" "build succeeded"    -sound ready
notchify "Heads up" "deploy needs input" -sound warning -symbol exclamationmark.triangle.fill -color orange
notchify "Open" "tap me"             -action https://example.com
notchify "Title only"                                  # body is optional
```

Positional args are `<title> [body]`, mirroring Linux's `notify-send`.
The legacy `-title` / `-text` flags are still accepted as aliases.

## Flags

| flag | meaning |
|------|---------|
| `-title <s>` | title (alias for first positional) |
| `-text <s>` | subtitle (alias for second positional, optional) |
| `-symbol <name>` | SF Symbol name |
| `-color <name>` | tint for `-symbol` (orange/red/blue/...) |
| `-icon <path>` | image file (used if no `-symbol`) |
| `-sound <name>` | `ready` / `warning` / `info` / `success` / `error`, or any name from `/System/Library/Sounds/` |
| `-action <url\|cmd>` | URL opened or shell command run on tap |
| `-focus` | shorthand for an `-action` that raises the source terminal app and (when run inside tmux) jumps to the originating pane; mutually exclusive with `-action`. Implies `-timeout 0` (persistent until clicked or focus-dismissed) |
| `-timeout <secs>` | auto-dismiss seconds (default 5). Use `0` for persistent (sits in the chip until explicitly dismissed) |
| `-group <name>` | stack notifications under a named chip on the notch shelf. Multiple notifications with the same `-group` collapse into one chip with a count badge |
| `-group-icon <symbol>` | SF Symbol for the chip; falls back to the notification's own `-symbol` |
| `-group-color <name>` | tint for the chip; falls back to the notification's own `-color` |

`-focus` auto-detects the terminal app
(Ghostty, iTerm, Terminal, WezTerm, kitty, ...).
Set `NOTCHIFY_TERMINAL_BUNDLE` to override the detection
(e.g. `NOTCHIFY_TERMINAL_BUNDLE=com.github.wez.wezterm`).

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
- Hover the body: pauses the auto-dismiss timer until the cursor moves away.
- Hover any chip on the shelf: drops down its full notification list.
  Click an individual row to dismiss it; click the chip itself to dismiss
  the topmost (newest) row.
- Multiple notifications queue and play in order. While the user is
  actively reading the pill (cursor anywhere on it), incoming arrivals
  are queued silently and resume playback once the cursor leaves.
- Up to 2 group chips render fully on the shelf; a 3rd group renders
  as a faded "+1" indicator on the leftmost edge until space frees up.
  Older groups beyond that are tracked in the data model but not shown.
- Inside a stack, up to ~3.5 rows are visible at once and the rest
  scroll, with a soft top/bottom fade indicating overflow.
- Do-Not-Disturb active: drops silently.
- Renders only when macOS reports an active built-in notched display.
- Uses macOS screen geometry APIs to anchor the overlay to the
  built-in notch area, even with an external monitor attached.

## Nix-darwin

A flake is provided. Add the input and import the module:

```nix
{
  inputs.notchify.url = "github:sespiros/notchify";

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

# Notchify repo guide

Notes for future Claude sessions on this repo. Things that aren't
obvious from reading the code.

## What this is

A menubar daemon (`notchify-daemon`, SwiftUI) that animates an overlay
out of the MacBook camera notch on the built-in display, plus a CLI
(`notchify`) that posts a one-line JSON payload over
`/tmp/notchify.sock`. macOS 13+. The daemon never touches
`UNUserNotificationCenter`, so nothing piles up in Notification Center.

## Build prerequisites

- macOS 13+ and full Xcode 15+. Command Line Tools alone aren't
  enough; the project needs Xcode's `MacOSX.sdk` and the Swift 5.9+
  toolchain that ships with `Xcode.app`.
- Always set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  and `unset SDKROOT` before `swift build`. nix-darwin and other
  environments inject an SDK that won't match Xcode's compiler;
  symptoms are `no such module 'SwiftShims'` or
  "SDK is not supported by the compiler".
- `scripts/package.sh` does the right thing automatically.

## Nix-darwin / flake notes

- The derivation uses host Xcode (impure). Always run
  `darwin-rebuild ... --impure`.
- Inside the nix sandbox, `swift build --disable-sandbox` is required;
  Swift PM tries to spawn its own `sandbox-exec` which collides with
  nix's. Override `HOME` to a writable temp dir for SwiftPM caches.
- The darwin module installs the CLI on PATH and runs the daemon via
  a launchd agent. It does *not* drop the .app into `/Applications`;
  nix-darwin's standard mechanism symlinks it under
  `/Applications/Nix Apps/` automatically.

## SwiftUI / AppKit gotchas

- Prefer `easeOut` / `easeInOut` over `.spring(...)`. Springs
  re-evaluate the SwiftUI body many times per frame and visibly hitch
  on slower hardware; ease curves are cheap and look nearly identical
  at our durations.
- `nonactivatingPanel` windows swallow the first mouse-down by
  default, so SwiftUI tap gestures only fire on the second click.
  `FirstMouseHosting<Content>` (in `NotchController.swift`) is an
  `NSHostingView` subclass that overrides `acceptsFirstMouse(for:)`
  to fix that. Don't override `canBecomeKey` / `canBecomeMain` on the
  panel itself — `acceptsFirstMouse` lives on `NSView`, not
  `NSWindow`.
- Pre-warm the `NSPanel` + `NSHostingView` once in
  `NotchController.init`. Allocating fresh per-notification adds
  noticeable first-frame layout cost.
- Cache `NSSound` instances; loading AIFFs off disk for every
  notification visibly hitches the animation.

## Notch geometry

- `screen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea` over-estimate
  the notch's *visible* width by ~20pt on each side. Don't size the
  panel from `screen.frame.width - leftAux.width - rightAux.width`.
- Hard-code a default (`178pt` fits a MacBook Air M4 at default
  resolution; 14"/16" Pros are similar) and allow override via
  `NOTCHIFY_NOTCH_WIDTH` env var.
- Always pick the screen with `safeAreaInsets.top > 0` so the overlay
  lands on the MacBook display when an external monitor is connected.

## README & docs

- Keep the README minimal. The full Claude Code + tmux hook lives in
  `examples/claude-code-tmux/`, not inline in the README.
- Forgejo and GitHub render animated GIFs in READMEs but not
  `<video autoplay>` MP4. Keep `Resources/demo.gif` under ~1 MB.
- `BUILDING.md` is for contributors; release/notarization steps don't
  belong there.

## Animation timeline

Default lifetime is 5s (matches macOS native banner dwell). Each
notification:

- Slide-in + width expand: ~0.5s
- Steady visible: ~5s (configurable via `-timeout`)
- Retract: ~0.9s

Queue keeps notifications sequential with a 0.25s gap.

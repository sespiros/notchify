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
- Plain `swift build` works as long as `xcode-select -p` points at a
  full Xcode install. If you have multiple Xcodes and need a specific
  one, set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  and `unset SDKROOT` before invoking. Symptoms of a wrong toolchain:
  `no such module 'SwiftShims'` or "SDK is not supported by the
  compiler".
- `scripts/package.sh` and the flake derivation pin
  `DEVELOPER_DIR=/Applications/Xcode.app/...` for reproducible release
  builds, regardless of the user's `xcode-select` default.

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

- Use only macOS public screen geometry APIs for placement:
  `safeAreaInsets.top` for height, and
  `screen.frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width`
  for the notch bounding width.
- Only render when an active built-in display with `safeAreaInsets.top > 0`
  exists. Desktop Macs and external-only/clamshell setups should drop
  notifications rather than inventing notch geometry.
- Always target the built-in notched display so the overlay lands on the
  MacBook screen when an external monitor is connected.

## README & docs

- Keep the README minimal. The full Claude Code + tmux hook lives in
  `examples/claude-code-tmux/`, not inline in the README.
- Forgejo and GitHub render animated GIFs in READMEs but not
  `<video autoplay>` MP4. Keep `Resources/demo.gif` under ~1 MB.
- `BUILDING.md` is for contributors; release/notarization steps don't
  belong there.

## Animation timeline

Default lifetime is 5s (matches macOS native banner dwell). Each
notification's lifecycle uses six labelled phases:

- a: pill slides down from above the screen edge.
- b: shelf widens to add a slot, slot icon fades in.
- c: pill height drops to expose body text; text fades in shortly after.
- d: text fades out and pill retracts back to chip-row height.
- e: slot fades out (when its stack empties).
- f: pill slides back up off-screen.

For a single non-grouped notification: a → b → c → dwell → d → e → f.
For a notification arriving in an existing group: only c → d (shelf
already widened, slot already visible). For a notification arriving in
a *new* group while the pill is already visible: b → c → d.

Phase timings are kept in sync via constants in `NotchController` (e.g.
`slideInDuration`, `phaseBToCDelay`, `slotRetractDuration`) and matching
`.animation(_, value:)` modifiers in `NotchPillView`.

## Stacking architecture

`NotchPillView` is the unified pill. Slots, in-flight body, and the
hover-expanded list all render inside the same black rounded shape:

- Each `NotificationStack` is keyed by `g:<group>` (named) or
  `a:_anon` (anonymous, all ungrouped notifications coalesce into one).
- Stacks render left-to-right newest-on-the-right (closest to notch).
  Up to 2 visible at full opacity; the 3rd renders at 40% opacity as a
  partial chip; older groups still hold their notifications but no chip.
- Hover any slot → drops the pill down to show that stack's full row
  list, capped at ~3.5 rows tall with the rest scrollable inside an
  AppKit-backed `ScrollView`. Top/bottom fade gradients only appear
  when there's actually content to scroll into.
- `model.inflight` is the *animation* source-of-truth (controller-owned).
  `displayedInflight` is a view-side mirror that lingers during fade-out
  so the body can animate out smoothly before unmount.
- `model.inRetraction` flag suppresses hover-driven expansions during
  the retraction window so a just-dismissed notification can't reappear
  as a hover-list row.

## Engagement behavior

While the cursor is anywhere on the pill (`pillHovered`), new arrivals
are queued in `arrivals` but do *not* trigger phase c. Once the user
disengages (cursor leaves pill), `handleEngagementChange` resumes
`startNext` and queued notifications play through their normal
lifecycle. This avoids interrupting the user mid-read while still
honoring `-timeout` semantics.

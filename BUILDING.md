# Building Notchify

## Requirements

- macOS 13+ (Sonoma 14+ recommended).
- Xcode 15+ (Command Line Tools alone are not enough — the project
  needs the full Xcode `MacOSX.sdk` and Swift 5.9+ toolchain that ship
  with Xcode.app).

## Quick build

```sh
swift build -c release
```

Output binaries land in `.build/release/`:

- `notchify-daemon` — the menubar daemon.
- `notchify` — the CLI sender.

## Build the .app and .dmg

```sh
./scripts/package.sh
```

Produces `dist/Notchify.app` (drag-to-Applications) and `dist/Notchify.dmg`
(disk image for distribution).

The script ad-hoc-signs the bundle with `codesign --sign -`, which lets
Gatekeeper run it on the same machine without warnings. Distribution to
other Macs requires a real Developer ID signature and notarization
(see "Distribution" below).

## SDK / toolchain mismatch

If `swift build` errors with `no such module 'SwiftShims'` or
`SDK is not supported by the compiler`, your environment has
`SDKROOT` and/or `DEVELOPER_DIR` pointed at a Swift SDK that doesn't
match the installed Xcode toolchain. Force them to match Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT
swift build -c release
```

`scripts/package.sh` does this automatically.

## Project layout

```
Package.swift              SwiftPM manifest, two executables.
Sources/
  notchify/                CLI binary.
  notchify-daemon/         Menubar app + Unix socket server + SwiftUI overlay.
Resources/
  Info.plist               .app bundle metadata (LSUIElement = YES).
  AppIcon-master.png/.svg  App icon source; sliced by scripts/make-icon.swift.
scripts/
  package.sh               Builds the .app and .dmg.
  make-icon.swift          Slices AppIcon-master.png into the iconset and .icns.
  test.sh                  Pre-push regression walkthrough; fires every
                           feature combo against a running daemon. Run
                           `./scripts/test.sh` (no args) for the section list.
  demo.sh                  User-facing showcase used to record demo.gif.
```

## Pre-push checks

`scripts/test.sh` is a sectioned regression walkthrough that exercises
every notification feature (stacks, overflow, hover, focus, animated
icons, etc.) against a running `notchify-daemon`. Most sections need a
human to hover/click/switch focus, so run them individually
(`./scripts/test.sh hover`) rather than `all`. The script prefers the
in-tree `./.build/debug/notchify` binary so it tests the current
branch without re-installing.

# Contributing

Thanks for the interest. Notchify is small and opinionated; a few notes
to keep changes easy to review.

## Issues

Include reproduction steps and your macOS version. Screenshots help.

## Pull requests

- Keep changes focused; one feature or fix per PR.
- Match the existing style (Swift 5.9, no force unwraps in new code,
  prefer simple structs/enums over class hierarchies).
- Don't add dependencies for things that can be done with stdlib /
  AppKit / SwiftUI.
- New CLI flags must be documented in both `README.md` and the usage
  string in `Sources/notchify/main.swift`.
- New IPC fields go on `Message` (Codable), not via parallel mechanisms.

## Building

See [BUILDING.md](BUILDING.md).

## Scope

Notchify is a generic notification surface. It deliberately does not:

- Maintain its own notification center / history.
- Integrate with any specific tool out of the box.
- Render anything other than the notch overlay (no banner, no popover,
  no dock badge).

If you want a feature that doesn't fit the above, open an issue first
to discuss whether it belongs upstream or in a wrapper script that
calls `notchify`.

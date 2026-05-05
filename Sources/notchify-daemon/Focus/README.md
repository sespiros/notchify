### Focus detectors (daemon side)

Mirror of the CLI's `Sources/notchify/Focus/` provider layout, on the
daemon side.
The CLI builds a click-to-focus shell action by composing providers;
the daemon decides whether the user is currently *on* the source by
composing **detectors** here.
Same shape, opposite direction.

### How composition works

Each detector declares a `FocusDetectorCategory`:

- `.terminal` — checks the terminal app/window the user is looking at.
- `.multiplexer` — checks the multiplexer pane the user is on.

`category` is purely declarative (mirrors the CLI), so readers can see
at a glance which layer a detector covers.
The orchestrator does not currently dispatch on it.

A detector returns one of:

- `nil` — abstain.
  This dismiss key has nothing for me to check (e.g. the tmux
  detector abstains when the key has no `tmuxPane`).
- `true` — confirms the user is on the source for my layer.
- `false` — vetoes: I'm applicable, but the user is not on the source.

Composition is **AND** across non-abstaining detectors:
a key matches when every detector that has an opinion votes `true`,
and at least one detector voted at all.
Adding a detector tightens the match.

### Adding a detector

1. Create a new file in this directory, e.g. `KittyWindowDetector.swift`.
2. Define a struct conforming to `FocusDetectorProvider`.
3. Read the dismiss key and the relevant fields from `FocusSnapshot`;
   abstain (`return nil`) for keys that don't apply to your layer.
4. Slot the detector into `registeredFocusDetectors` in
   `FocusDetectorProvider.swift`.
5. If you need a new OS probe (a different AppleScript dictionary, a
   different multiplexer's CLI), add it to `FocusDetector` (the
   orchestrator file at `../FocusDetector.swift`) and expose it as a
   lazy method on `FocusSnapshot` so it runs at most once per poll.

Skeleton:

```swift
import Foundation

struct KittyWindowDetector: FocusDetectorProvider {
    let category: FocusDetectorCategory = .terminal

    func matches(key: DismissKey, snapshot: FocusSnapshot) -> Bool? {
        guard key.bundle == "net.kovidgoyal.kitty" else { return nil }
        // ... return true/false based on snapshot.kittyFocusedWindow()
        return nil
    }
}
```

### Why detectors abstain

The Ghostty window detector abstains outside Ghostty, or when the
dismiss key has no tty. For Ghostty keys with a tty, it requires the
focused Ghostty window title to contain that tty's short form. This
prevents a different frontmost Ghostty window from satisfying the
bundle-only baseline for non-tmux notifications.

The tmux pane detector abstains when the dismiss key has no
`tmuxPane`.
A non-tmux notification should not be vetoed by the multiplexer
layer.

The bundle detector never abstains: bundle equality is the baseline
every match builds on.

### Snapshot caching

`FocusSnapshot` is constructed once per poll tick.
It captures the frontmost bundle eagerly (one CGWindowList lookup),
and exposes `activePanes(socket:)` and `ghosttyFocusedTitle()` as
lazy, per-tick caches.
A detector that is the only one that needs the Ghostty title pays
one AppleScript invocation per tick, regardless of how many rows
reference it.

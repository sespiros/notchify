# Focus providers

`-focus` builds its click-to-focus shell action by composing small
"providers".
Each provider answers one question:
"given the current context (env, tty, detected terminal app), what's
my piece of the action, or do I not apply?"

This file is the contract for adding new providers.
A user with a setup we don't cover (different terminal, different
multiplexer) should be able to add support in one new file.

## How composition works

Every provider declares a `FocusCategory`:

- `.terminal` — brings the right terminal app/window/tab to the front.
- `.multiplexer` — switches a running multiplexer to the originating pane.

Within a single category the *first* provider whose `action()` returns
non-nil wins; later providers in the same category are skipped.
Across categories the actions concatenate, so a `.terminal` provider
and a `.multiplexer` provider both fire on the same click.

The order in `registeredFocusProviders` (in `Focus.swift`) is the
priority order.
Specific providers go before generic fallbacks of the same category.

## Adding a provider

1. Create a new file in this directory, e.g. `ScreenProvider.swift`.
2. Define a struct conforming to `FocusProvider`.
3. Read what you need from `FocusContext`.
4. Return a shell command string, or nil to skip.
5. Slot the provider into `registeredFocusProviders` in `Focus.swift`,
   before any more-generic fallback in the same category.

Skeleton:

```swift
import Foundation

struct ScreenFocusProvider: FocusProvider {
    let category: FocusCategory = .multiplexer

    func action(in context: FocusContext) -> String? {
        guard let sty = context.env["STY"], !sty.isEmpty else { return nil }
        // ... return the shell snippet that switches GNU screen to the
        // right window/region, e.g.:
        return "screen -S \(sty) -X select \(/* number */)"
    }
}
```

Then in `Focus.swift`:

```swift
let registeredFocusProviders: [FocusProvider] = [
    GhosttyFocusProvider(),
    OpenBundleFocusProvider(),
    TmuxFocusProvider(),
    ScreenFocusProvider(),   // <-- new
]
```

## Context plumbing

`FocusContext` is resolved once at the top of `buildFocusAction()` and
passed read-only to every provider.
Fields:

- `env` — the calling environment.
- `tmuxBinary` — absolute path to tmux, resolved here so the action
  string runs cleanly under notchify-daemon's reduced launchd PATH.
  Nil if tmux isn't on PATH at -focus time.
- `callerTTY` — the caller's controlling tty.
  Inside tmux this is the *client* tty (the terminal-side pty), not
  the pane's tty.
- `detectedBundle` — bundle id of the GUI app that owns the caller,
  resolved by walking the process ancestry from the tty owner.

If your provider needs something else (a different env var, a
different process probe), add a helper to `Utilities.swift` and
either compute it lazily inside your `action()` or extend
`FocusContext` if more than one provider needs it.

## Action shape

The action string runs under `sh -c` from notchify-daemon, which
inherits launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`).
Always resolve binaries to absolute paths at -focus time, where the
caller still has a real PATH; don't rely on the daemon to find them.

Multiple providers' contributions are joined with `; `, so each piece
should be a self-contained shell statement.
Swallow stderr (`2>/dev/null`) on best-effort calls that may fail on
some setups.

## Testing

Build and run from within your tmux pane:

```sh
swift build
NOTCHIFY_DEBUG=1 .build/debug/notchify "t" "x" -focus
```

(Re-add a debug stderr write in `main.swift` when iterating; not
shipped by default.)
The printed JSON `action` field is the exact shell string the daemon
will run on click.
Verify each provider's piece is present, then click-test from a
non-focused window.

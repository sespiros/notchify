package main

import (
	"os"
	"strings"
)

// focusCapture is the working set assembled before serialization.
// Per-field precedence: NOTCHIFY_FOCUS_* env vars first (an outer
// launcher such as the agentbox sandbox may have populated them with
// host-side context), then portable env fallbacks (TMUX_PANE, TMUX),
// then platform-specific introspection (lsappinfo / ps / ttyname on
// darwin, no-op elsewhere). Each field resolves independently.
type focusCapture struct {
	bundle     string
	tmuxPane   string
	tmuxSocket string
	tty        string
}

// captureFocus returns a populated focus payload or nil when no source
// context could be assembled. On Linux without an outer launcher, this
// returns nil and the caller emits the same "no terminal or tmux
// context detected" warning as the macOS path used to.
func captureFocus() *focusPayload {
	f := focusCapture{
		bundle:     os.Getenv("NOTCHIFY_FOCUS_BUNDLE"),
		tmuxPane:   os.Getenv("NOTCHIFY_FOCUS_TMUX_PANE"),
		tmuxSocket: os.Getenv("NOTCHIFY_FOCUS_TMUX_SOCKET"),
		tty:        os.Getenv("NOTCHIFY_FOCUS_TTY"),
	}

	// Portable env fallbacks (no native API needed).
	if f.tmuxPane == "" {
		f.tmuxPane = os.Getenv("TMUX_PANE")
	}
	if f.tmuxSocket == "" {
		// $TMUX is "<socket-path>,<pid>,<id>". We want the socket
		// path so the daemon's tmux invocations can pass `-S <path>`
		// and target the user's actual server, not the daemon's
		// default-socket server (often different under nix-darwin).
		if tmuxEnv := os.Getenv("TMUX"); tmuxEnv != "" {
			if i := strings.Index(tmuxEnv, ","); i > 0 {
				f.tmuxSocket = tmuxEnv[:i]
			}
		}
	}

	introspectFocus(&f)

	// tmux_socket without a pane is meaningless; drop it.
	if f.tmuxPane == "" {
		f.tmuxSocket = ""
	}

	// The daemon's matching providers all key off bundle. Without one,
	// there is nothing actionable to send.
	if f.bundle == "" {
		return nil
	}
	return &focusPayload{
		Bundle:     f.bundle,
		TmuxPane:   optStr(f.tmuxPane),
		TmuxSocket: optStr(f.tmuxSocket),
		Tty:        optStr(f.tty),
	}
}

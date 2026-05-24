// Command notchify is the CLI client that posts a one-line JSON
// payload to the notchify-daemon's Unix socket (/tmp/notchify.sock),
// with a loopback-TCP fallback for callers that cannot mount the
// daemon's socket (sandboxes, VMs).
//
// Flag set mirrors the macOS-native predecessor exactly so existing
// agent recipes do not need to change.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
)

const helpText = `usage: notchify <title> [body] [options]
       notchify --daemon quit

  -i, --icon <spec>       icon spec (default: bell.fill); one of:
                          SF Symbol name (e.g. checkmark.circle.fill)
                          file path (e.g. ~/icons/claude.png)
                          integration:<recipe>/<variant> for bundled
                          icons (e.g. integration:claude-code/done)
  -c, --color <name>      tint for SF Symbol icons (default: white)
                          orange, red, yellow, green, blue, purple, pink, gray
  -s, --sound <name>      ready | warning | info | success | error
                          or any name from /System/Library/Sounds/ (default: silent)
  -a, --action <url|cmd>  URL opened or shell command run on click
  -f, --focus             raise source terminal / jump to tmux pane on click
                          (mutually exclusive with --action; implies --timeout 0)
  -t, --timeout <secs>    auto-dismiss after N seconds, 0 = persistent (default: 5)
  -g, --group <name>      stack notifications under a named chip;
                          icon/color come from the first arrival in the group
  --daemon quit           quit the running daemon

Examples:
  notchify "Done" "build succeeded"
  notchify "Heads up" "deploy needs input" --icon exclamationmark.triangle.fill --color orange
  notchify "Open" "tap me" --action https://example.com
  notchify "Build done" "ready to commit" -g claude -i ~/icons/claude.png
  notchify --daemon quit
`

const usageLine = "usage: notchify <title> [body] [options] | notchify --daemon quit (run 'notchify -h' for full help)"

func usage() {
	fmt.Fprintln(os.Stderr, usageLine)
	os.Exit(2)
}

func help() {
	fmt.Print(helpText)
	os.Exit(0)
}

type payload struct {
	Title   string        `json:"title"`
	Text    *string       `json:"text,omitempty"`
	Icon    *string       `json:"icon,omitempty"`
	Color   *string       `json:"color,omitempty"`
	Sound   *string       `json:"sound,omitempty"`
	Action  *string       `json:"action,omitempty"`
	Timeout *float64      `json:"timeout,omitempty"`
	Group   *string       `json:"group,omitempty"`
	Focus   *focusPayload `json:"focus,omitempty"`
}

// Field names match the daemon's DismissKey struct (camelCase from
// Swift's JSONEncoder defaults). Do not change without updating
// Sources/notchify-daemon/DismissKey.swift in lockstep.
type focusPayload struct {
	Bundle     string  `json:"bundle"`
	TmuxPane   *string `json:"tmuxPane,omitempty"`
	TmuxSocket *string `json:"tmuxSocket,omitempty"`
	Tty        *string `json:"tty,omitempty"`
}

func optStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func main() {
	args := os.Args[1:]

	// `notchify --daemon quit` is a privileged command (no TCP fallback):
	// the daemon only accepts commands over the Unix socket, where the
	// caller is provably on the same machine.
	if len(args) > 0 && args[0] == "--daemon" {
		if len(args) != 2 || args[1] != "quit" {
			usage()
		}
		data, _ := json.Marshal(map[string]string{
			"type":    "command",
			"command": "quit",
		})
		if err := sendToDaemon(data, false); err != nil {
			fmt.Fprintln(os.Stderr, socketUnreachableMsg)
			os.Exit(1)
		}
		return
	}

	var (
		title, text, icon, color, sound, action, group string
		focus                                          bool
		timeout                                        *float64
		positionals                                    []string
	)

	i := 0
	for i < len(args) {
		flag := args[i]
		i++
		switch flag {
		case "-i", "--icon":
			if i >= len(args) {
				usage()
			}
			icon = args[i]
			i++
		case "-c", "--color":
			if i >= len(args) {
				usage()
			}
			color = args[i]
			i++
		case "-s", "--sound":
			if i >= len(args) {
				usage()
			}
			sound = args[i]
			i++
		case "-a", "--action":
			if i >= len(args) {
				usage()
			}
			action = args[i]
			i++
		case "-f", "--focus":
			focus = true
		case "-t", "--timeout":
			if i >= len(args) {
				usage()
			}
			v, err := strconv.ParseFloat(args[i], 64)
			if err != nil {
				usage()
			}
			timeout = &v
			i++
		case "-g", "--group":
			if i >= len(args) {
				usage()
			}
			group = args[i]
			i++
		case "-h", "--help":
			help()
		default:
			if len(flag) > 0 && flag[0] == '-' {
				usage()
			}
			positionals = append(positionals, flag)
		}
	}

	if len(positionals) > 0 {
		title = positionals[0]
		positionals = positionals[1:]
	}
	if len(positionals) > 0 {
		text = positionals[0]
		positionals = positionals[1:]
	}
	if len(positionals) > 0 {
		usage()
	}
	if title == "" {
		usage()
	}

	var focusBlock *focusPayload
	if focus {
		if action != "" {
			fmt.Fprintln(os.Stderr, "notchify: --focus and --action are mutually exclusive")
			os.Exit(2)
		}
		focusBlock = captureFocus()
		if focusBlock == nil {
			fmt.Fprintln(os.Stderr, "notchify: --focus requested but no terminal or tmux context detected; ignoring")
		}
		// --focus implies persist: the notification keeps a row in its
		// stack after the in-flight retracts, ready to be dismissed
		// when the user visits the source.
		if timeout == nil {
			zero := 0.0
			timeout = &zero
		}
	}

	p := payload{
		Title:   title,
		Text:    optStr(text),
		Icon:    optStr(icon),
		Color:   optStr(color),
		Sound:   optStr(sound),
		Action:  optStr(action),
		Timeout: timeout,
		Group:   optStr(group),
		Focus:   focusBlock,
	}
	data, err := json.Marshal(p)
	if err != nil {
		fmt.Fprintln(os.Stderr, "notchify: failed to encode payload:", err)
		os.Exit(1)
	}
	if err := sendToDaemon(data, true); err != nil {
		fmt.Fprintln(os.Stderr, socketUnreachableMsg)
		os.Exit(1)
	}
}

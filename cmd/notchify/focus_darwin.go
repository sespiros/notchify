//go:build darwin

package main

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// introspectFocus fills any fields the env-var pass left empty using
// macOS-native shell-outs (no CGo, no AppKit dep). Mirrors the probes
// the Swift CLI used to do directly:
//   - tty: tmux client_tty if inside tmux, else shell out to /usr/bin/tty
//     with our stderr/stdout/stdin redirected to its stdin in turn
//     (stderr first; hooks often pipe stdin/stdout while leaving
//     stderr on the real tty).
//   - bundle: when we know the controlling tty, find any process
//     attached to it (`ps -t <tty>`) and walk *that* process's
//     ancestors. This is the only path that works inside tmux: the
//     CLI's own ancestry dead-ends at launchd via the daemonized
//     tmux server, but processes pinned to the terminal's pty
//     ascend through the real terminal emulator. Fallback to our
//     own ancestry only when no tty is known.
func introspectFocus(f *focusCapture) {
	if f.tty == "" {
		f.tty = resolveTTY(f.tmuxPane)
	}
	if f.bundle == "" {
		if f.tty != "" {
			f.bundle = bundleByTTY(f.tty)
		}
		if f.bundle == "" {
			f.bundle = walkAncestorsForBundle(os.Getppid())
		}
	}
}

// bundleByTTY enumerates processes attached to `tty` via `/bin/ps -t`
// and walks each one's ancestors looking for a GUI app. Returns the
// first hit. /bin/ps wants the tty in short form (no /dev/ prefix).
func bundleByTTY(tty string) string {
	short := strings.TrimPrefix(tty, "/dev/")
	out, err := exec.Command("/bin/ps", "-t", short, "-o", "pid=").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		s := strings.TrimSpace(line)
		if s == "" {
			continue
		}
		pid, err := strconv.Atoi(s)
		if err != nil {
			continue
		}
		if b := walkAncestorsForBundle(pid); b != "" {
			return b
		}
	}
	return ""
}

func resolveTTY(tmuxPane string) string {
	if tmuxPane != "" {
		if tty := tmuxClientTTY(tmuxPane); tty != "" {
			return tty
		}
	}
	for _, in := range []*os.File{os.Stderr, os.Stdout, os.Stdin} {
		if name := ttyFromFD(in); name != "" {
			return name
		}
	}
	return ""
}

// ttyFromFD runs /usr/bin/tty with `in` wired in as the child's stdin
// and returns the device path it prints, or "" if the fd is not a tty.
// `tty` exits non-zero ("not a tty") for closed/redirected fds, which
// we filter via the /dev/ prefix check.
func ttyFromFD(in *os.File) string {
	cmd := exec.Command("/usr/bin/tty")
	cmd.Stdin = in
	out, _ := cmd.Output()
	name := strings.TrimSpace(string(out))
	if !strings.HasPrefix(name, "/dev/") {
		return ""
	}
	return name
}

func tmuxClientTTY(pane string) string {
	tmux := findTmux()
	if tmux == "" {
		return ""
	}
	out, err := exec.Command(tmux, "display-message", "-pt", pane, "#{client_tty}").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func findTmux() string {
	out, err := exec.Command("/usr/bin/env", "sh", "-c", "command -v tmux").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// Walk the process ancestry from `start` looking for an ancestor whose
// pid lsappinfo can map to a GUI bundle id. Bounded depth keeps the
// walk honest if /bin/ps ever returns nonsense.
func walkAncestorsForBundle(start int) string {
	pid := start
	for i := 0; i < 10; i++ {
		ppid := readPPID(pid)
		if ppid <= 1 {
			return ""
		}
		if b := bundleFor(ppid); b != "" {
			return b
		}
		pid = ppid
	}
	return ""
}

func readPPID(pid int) int {
	out, err := exec.Command("/bin/ps", "-o", "ppid=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0
	}
	s := strings.TrimSpace(string(out))
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return n
}

// bundleFor returns the LSBundleIdentifier of the given pid via
// lsappinfo, or "" if the pid is not a registered GUI app (shells,
// tmux, daemons, etc.). lsappinfo prints lines of the form
// `"LSBundleIdentifier"="com.foo.bar"`; missing keys produce empty
// output. The exact output format has been stable across recent macOS
// releases (verified on 14.x, 15.x).
func bundleFor(pid int) string {
	out, err := exec.Command("/usr/bin/lsappinfo", "info", "-only", "bundleid", strconv.Itoa(pid)).Output()
	if err != nil {
		return ""
	}
	return parseLsAppInfoBundle(string(out))
}

func parseLsAppInfoBundle(out string) string {
	// Looking for `="<bundle>"` somewhere in the line. lsappinfo
	// prefixes the key (`"LSBundleIdentifier"=`) so the value is
	// always quoted and comes after `=`.
	eq := strings.Index(out, `="`)
	if eq < 0 {
		return ""
	}
	rest := out[eq+2:]
	end := strings.Index(rest, `"`)
	if end < 0 {
		return ""
	}
	return rest[:end]
}

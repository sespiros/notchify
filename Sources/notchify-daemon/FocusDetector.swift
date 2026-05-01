import AppKit
import Foundation

/// Resolves "what is the user currently looking at?" so the daemon
/// can auto-dismiss `-focus` notifications when the user visits the
/// source. The dismiss-key on each notification is matched against:
///
/// - `bundle`: the frontmost application's bundle id.
/// - `tmuxPane` (optional): if set, the pane must additionally be
///   the currently-active pane of *some* attached tmux client. We
///   intentionally accept any attached client because we can't tell,
///   without Accessibility, which terminal window is hosting which
///   tmux client.
///
/// Cost: a single `tmux list-clients` subprocess per poll, plus an
/// NSWorkspace lookup. The poll runs at 1 Hz and only while there
/// are focus-bearing notifications, so the steady-state cost is zero.
@MainActor
enum FocusDetector {
    /// Bundle id of the application owning the user-visible frontmost
    /// window. Falls back to NSWorkspace's frontmostApplication.
    /// Tiling window managers like Aerospace don't always change the
    /// macOS-level frontmost app when switching workspaces (they
    /// show/hide windows without re-focusing), so a plain
    /// NSWorkspace.frontmostApplication can lag the actual user
    /// focus. CGWindowList's on-screen list, ordered by z-index,
    /// reflects the truly visible top window and stays in sync with
    /// workspace switches. The window-info pids are returned without
    /// requiring Screen Recording permission (only window titles
    /// would).
    static func frontmostBundleID() -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for info in raw {
                guard
                    let layer = info[kCGWindowLayer as String] as? Int,
                    layer == 0,
                    let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                    let app = NSRunningApplication(processIdentifier: pid),
                    let bundle = app.bundleIdentifier
                else { continue }
                return bundle
            }
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Set of tmux pane ids ("%23" form) currently displayed in any
    /// attached client of the tmux server at `socket`. If `socket`
    /// is nil, queries tmux's default socket. Empty when tmux isn't
    /// installed or the server has no attached clients.
    ///
    /// Uses `list-panes -a` instead of `list-clients` because the
    /// latter returns empty in some wrapper setups (notably byobu)
    /// even when clients are clearly attached, making it useless as
    /// a focus signal. `list-panes -a` enumerates every pane on the
    /// server; we pick the ones that are both their window's
    /// `pane_active` and live in a session whose `session_attached`
    /// count is non-zero. That gives the same semantic answer as
    /// "active panes across attached clients" without depending on
    /// the brittle list-clients output.
    static func activeTmuxPanes(socket: String?) -> Set<String> {
        guard let tmux = resolveTmuxBinary() else { return [] }
        var args: [String] = []
        if let socket {
            args.append(contentsOf: ["-S", socket])
        }
        args.append(contentsOf: [
            "list-panes", "-a", "-F",
            "#{pane_active} #{window_active} #{session_attached} #{pane_id}"
        ])
        let result = runProcess(tmux, args)
        if result.exitCode != 0 { return [] }
        var panes: Set<String> = []
        for line in (result.stdout ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 4 else { continue }
            guard parts[0] == "1" else { continue }     // pane_active
            guard parts[1] == "1" else { continue }     // window_active
            guard parts[2] != "0" else { continue }     // session_attached > 0
            panes.insert(parts[3])
        }
        return panes
    }

    /// True iff the given dismiss-key matches the current focus.
    /// `activePanesProvider` is invoked lazily (and at most once per
    /// distinct socket per call) so the caller can cache results
    /// across many rows that share a tmux server.
    ///
    /// True iff the dismiss-key matches the user's current focus.
    ///
    /// Both layers must agree:
    /// - **Window**: the Ghostty window the user is currently
    ///   looking at must be the source window. We ask AppleScript
    ///   for the windows list and match the first element (Ghostty
    ///   orders that list focus-first, and the ordering updates on
    ///   Aerospace workspace switches — unlike `front terminal`).
    ///   The check is "title contains source tty short form",
    ///   relying on the user's tmux config to embed `client_tty`
    ///   in the window title.
    /// - **Pane**: at least one attached tmux session must be on
    ///   the source pane. This catches same-window-different-pane
    ///   (any session on source pane = user is or recently was on
    ///   it). It's intentionally lenient because the window-level
    ///   check above already rules out the multi-Ghostty
    ///   false-positive — when the user is on a *different*
    ///   Ghostty window, the title won't contain the source tty
    ///   no matter what tmux's pane state looks like.
    ///
    /// For non-Ghostty bundles, skip the AppleScript step and
    /// fall back to lenient tmux. If tmux returns nothing, refuse
    /// to match rather than dismiss on bundle alone.
    static func matches(
        _ key: DismissKey,
        bundle: String?,
        activePanesProvider: (String?) -> Set<String>,
        ghosttyFocusedTitleProvider: @MainActor () -> String? = ghosttyFocusedWindowTitle
    ) -> Bool {
        guard let bundle, key.bundle == bundle else { return false }
        if bundle == "com.mitchellh.ghostty", let tty = key.tty {
            guard let title = ghosttyFocusedTitleProvider() else { return false }
            guard title.contains(shortTTY(tty)) else { return false }
        }
        guard let pane = key.tmuxPane else { return true }
        let panes = activePanesProvider(key.tmuxSocket)
        guard !panes.isEmpty else { return false }
        return panes.contains(pane)
    }

    /// Title of Ghostty's currently-focused window.
    /// `tell app … to get name of windows` returns the windows in
    /// z-order with the focused one first (verified empirically;
    /// Aerospace workspace switches update this ordering, while
    /// `front terminal` does not). We return only the first item
    /// rather than the whole list to keep the match scoped to the
    /// actually-visible window.
    static func ghosttyFocusedWindowTitle() -> String? {
        let r = runProcess(
            "/usr/bin/osascript",
            ["-e", "tell application \"Ghostty\" to return name of first window"]
        )
        guard r.exitCode == 0 else { return nil }
        return r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `/dev/ttys003` → `ttys003`. Match origin/main's
    /// `#{s|/dev/||:client_tty}` convention.
    private static func shortTTY(_ tty: String) -> String {
        return tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
    }

    private static func resolveTmuxBinary() -> String? {
        // Daemons launched via launchd inherit a minimal PATH that
        // doesn't include Homebrew prefixes, so a plain `command -v
        // tmux` often finds nothing. Probe the usual install
        // locations directly first, then fall back to PATH lookup.
        let candidates = [
            "/opt/homebrew/bin/tmux",   // Apple Silicon Homebrew
            "/usr/local/bin/tmux",       // Intel Homebrew / older
            "/usr/bin/tmux",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return captureOutput("/usr/bin/env", ["sh", "-c", "command -v tmux"])
    }

    private static func captureOutput(_ launchPath: String, _ arguments: [String]) -> String? {
        let r = runProcess(launchPath, arguments)
        guard r.exitCode == 0 else { return nil }
        let out = (r.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> (exitCode: Int32, stdout: String?, stderr: String?) {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (-1, nil, nil) }
        p.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return (p.terminationStatus, stdout, stderr?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

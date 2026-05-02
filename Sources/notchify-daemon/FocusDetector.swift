import AppKit
import Foundation

/// Resolves "what is the user currently looking at?" so the daemon
/// can auto-dismiss `-focus` notifications when the user visits the
/// source.
///
/// This file is the orchestrator and the home of the low-level OS
/// probes. The actual matching logic lives in per-feature detectors
/// under `Focus/` (one file each, mirroring the CLI's
/// `Sources/notchify/Focus/` provider layout). To support a new
/// terminal or multiplexer, add a new detector there; nothing in
/// this file should need to change.
///
/// Cost: one CGWindowList lookup per poll, plus at most one tmux
/// subprocess and one AppleScript invocation per poll (both lazy via
/// `FocusSnapshot`). The poll runs at 1 Hz only while there are
/// focus-bearing notifications, so the steady-state cost is zero.
@MainActor
enum FocusDetector {
    /// True iff the user's current focus matches `key`, per the
    /// composed verdict of all registered detectors. A key matches
    /// when every non-abstaining detector votes true and at least one
    /// detector voted at all.
    static func matches(
        _ key: DismissKey,
        snapshot: FocusSnapshot,
        providers: [FocusDetectorProvider] = registeredFocusDetectors
    ) -> Bool {
        var anyVoted = false
        for provider in providers {
            guard let vote = provider.matches(key: key, snapshot: snapshot) else { continue }
            anyVoted = true
            if !vote { return false }
        }
        return anyVoted
    }

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

    private static func resolveTmuxBinary() -> String? {
        // Daemons launched via launchd inherit a minimal PATH that
        // doesn't include Homebrew or Nix prefixes, so a plain
        // `command -v tmux` often finds nothing. Probe the usual
        // install locations directly first, then fall back to PATH
        // lookup.
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/tmux",                              // Apple Silicon Homebrew
            "/usr/local/bin/tmux",                                  // Intel Homebrew / older
            "/usr/bin/tmux",
            "/run/current-system/sw/bin/tmux",                      // nix-darwin system profile
            "/etc/profiles/per-user/\(NSUserName())/bin/tmux",     // nix-darwin per-user profile
            "\(home)/.nix-profile/bin/tmux",                        // single-user Nix
            "/nix/var/nix/profiles/default/bin/tmux",               // multi-user Nix default profile
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

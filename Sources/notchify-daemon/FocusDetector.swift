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
    /// Bundle id of the frontmost application, or nil if the system
    /// can't determine one.
    static func frontmostBundleID() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Set of tmux pane ids ("%23" form) currently displayed in any
    /// attached client of the tmux server at `socket`. If `socket`
    /// is nil, queries tmux's default socket. Empty when tmux isn't
    /// installed or the server has no attached clients.
    static func activeTmuxPanes(socket: String?) -> Set<String> {
        guard let tmux = resolveTmuxBinary() else { return [] }
        var args: [String] = []
        if let socket {
            args.append(contentsOf: ["-S", socket])
        }
        args.append(contentsOf: ["list-clients", "-F", "#{client_active_pane}"])
        let result = runProcess(tmux, args)
        if result.exitCode != 0 { return [] }
        let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Set(stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    /// True iff the given dismiss-key matches the current focus.
    /// `activePanesProvider` is invoked lazily (and at most once per
    /// distinct socket per call) so the caller can cache results
    /// across many rows that share a tmux server.
    ///
    /// Pragmatic fallback: if the dismiss-key has a tmuxPane but the
    /// tmux server returns no clients (which can happen when a
    /// daemon-spawned subprocess queries tmux even though the user
    /// is genuinely attached), we fall back to bundle-only matching.
    /// Misses the per-pane precision but doesn't leave persistent
    /// notifications stuck on screen forever.
    static func matches(
        _ key: DismissKey,
        bundle: String?,
        activePanesProvider: (String?) -> Set<String>
    ) -> Bool {
        guard let bundle, key.bundle == bundle else { return false }
        guard let pane = key.tmuxPane else { return true }
        let panes = activePanesProvider(key.tmuxSocket)
        if panes.isEmpty {
            // Tmux had nothing to say about clients on this socket.
            // Bundle already matched; consider the user "on the
            // source" rather than ignoring the dismiss.
            return true
        }
        return panes.contains(pane)
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

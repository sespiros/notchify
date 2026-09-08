import AppKit
import Foundation

/// Resolves "what is the user currently looking at?" so the daemon
/// can auto-dismiss `--focus` notifications when the user visits the
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
        providers: [FocusDetectorProvider]? = nil
    ) -> Bool {
        // Fall back to the registered detectors here rather than as a
        // default argument: a `@MainActor` global referenced from a
        // default-argument expression evaluates in the caller's
        // isolation context, which Swift 6 flags as cross-isolation.
        let providers = providers ?? registeredFocusDetectors
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
        let result = runProcess(tmux, args, timeout: tmuxProbeTimeout)
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

    /// Bound on the inline tmux probes. tmux answers over a local
    /// socket in a few ms; anything longer means the server is stuck
    /// and the poll tick should give up rather than hold the UI.
    private static let tmuxProbeTimeout: TimeInterval = 2.0

    /// How long one poll tick waits for a fresh Ghostty title. A
    /// normal osascript round trip is 100-300 ms.
    private static let ghosttyProbeWait: TimeInterval = 1.0

    /// True while an osascript probe is outstanding. Ticks that find
    /// it set return nil instead of spawning another osascript.
    private static var ghosttyProbeInFlight = false

    /// Title of Ghostty's currently-focused window.
    /// `tell app … to get name of windows` returns the windows in
    /// z-order with the focused one first (verified empirically;
    /// Aerospace workspace switches update this ordering, while
    /// `front terminal` does not). We return only the first item
    /// rather than the whole list to keep the match scoped to the
    /// actually-visible window.
    ///
    /// The probe runs on a background queue and a tick waits at most
    /// `ghosttyProbeWait` for it. osascript normally answers in well
    /// under that, but it hangs outright while the system is wedged:
    /// a stalled network mount (Time Machine over SMB on a bad link)
    /// holds the mount table lock, and every process that registered
    /// with LaunchServices, osascript included, then hangs on exit,
    /// unkillable. Waiting for it inline on the main actor froze the
    /// whole daemon for hours (2026-09-07). While a probe is
    /// outstanding, further ticks return nil, so the Ghostty detector
    /// vetoes dismissal and the notification stays up rather than
    /// being dismissed on stale data. No kill and no respawn on
    /// purpose: a wedged child ignores SIGKILL, and one new osascript
    /// per tick would pile up unkillable zombies. The single
    /// outstanding probe returns when the wedge clears, and polling
    /// resumes by itself.
    static func ghosttyFocusedWindowTitle() -> String? {
        if ghosttyProbeInFlight { return nil }
        ghosttyProbeInFlight = true
        let done = DispatchSemaphore(value: 0)
        let title = ProbeBox<String?>(nil)
        ghosttyProbeQueue.async {
            let r = runProcess(
                "/usr/bin/osascript",
                ["-e", "tell application \"Ghostty\" to return name of first window"]
            )
            if r.exitCode == 0 {
                title.value = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            done.signal()
            Task { @MainActor in ghosttyProbeInFlight = false }
        }
        if done.wait(timeout: .now() + ghosttyProbeWait) == .timedOut { return nil }
        return title.value
    }

    /// Internal (not private) so click-time action builders under
    /// `Focus/` can share the same probe order. Daemon-spawned shells
    /// inherit launchd's minimal PATH, so any tmux invocation needs an
    /// absolute path baked in by the daemon at click time.
    static func resolveTmuxBinary() -> String? {
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
        let r = runProcess(launchPath, arguments, timeout: tmuxProbeTimeout)
        guard r.exitCode == 0 else { return nil }
        let out = (r.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Run `launchPath` and collect its output. With a `timeout` the
    /// call gives up after that long: the child gets SIGKILL and the
    /// result reads as a failure. Inline callers on the main actor
    /// (the tmux probes) pass one so a stuck subprocess costs a
    /// bounded stall. The Ghostty probe passes none: it has its own
    /// off-main-actor guard, and a wedged osascript cannot be killed
    /// anyway. Nonisolated so the Ghostty probe can call it from its
    /// background queue.
    nonisolated private static func runProcess(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil
    ) -> (exitCode: Int32, stdout: String?, stderr: String?) {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, nil, nil) }
        // Drain both pipes off-thread. Reading after the exit wait
        // deadlocks a child that fills a pipe; reading before it
        // blocks on a child that never closes its end.
        let out = ProbeBox<Data>(Data())
        let err = ProbeBox<Data>(Data())
        let drained = DispatchGroup()
        drained.enter()
        probeIOQueue.async {
            out.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        probeIOQueue.async {
            err.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                return (-1, nil, nil)
            }
        } else {
            exited.wait()
        }
        // The pipes close with the child; the bound only covers a
        // grandchild that inherited them and lingers.
        _ = drained.wait(timeout: .now() + 1.0)
        let stdout = String(data: out.value, encoding: .utf8)
        let stderr = String(data: err.value, encoding: .utf8)
        return (p.terminationStatus, stdout, stderr?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Serial queue the Ghostty AppleScript probe runs on, so a hung
/// osascript parks a background thread rather than the main actor.
private let ghosttyProbeQueue = DispatchQueue(label: "cloud.seimenis.notchify.ghostty-probe")

/// Readers for subprocess pipes; concurrent because stdout and stderr
/// of one child are drained side by side.
private let probeIOQueue = DispatchQueue(label: "cloud.seimenis.notchify.probe-io", attributes: .concurrent)

/// Lock-guarded cell for handing a value from a background probe
/// back to its caller.
private final class ProbeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

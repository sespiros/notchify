import Foundation
import AppKit

/// Run `launchPath arguments...`, capture stdout, return trimmed.
/// Returns nil on launch failure, non-zero exit, or empty output.
func captureOutput(_ launchPath: String, _ arguments: [String]) -> String? {
    let p = Process()
    p.launchPath = launchPath
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out.isEmpty ? nil : out
}

/// Walk up from `start` looking for an ancestor that NSRunningApplication
/// resolves to a real GUI app. Shells and tmux return nil and are
/// skipped silently. /bin/ps drives ppid lookup so we don't pull in
/// libproc just to walk a few levels.
func findBundleByWalkingAncestors(from start: Int32) -> String? {
    var pid = start
    for _ in 0..<10 {
        if pid <= 1 { return nil }
        if let app = NSRunningApplication(processIdentifier: pid),
           let bid = app.bundleIdentifier {
            return bid
        }
        guard let raw = captureOutput("/bin/ps", ["-o", "ppid=", "-p", String(pid)]),
              let parent = Int32(raw) else { return nil }
        pid = parent
    }
    return nil
}

/// Resolve the controlling tty of the caller. Inside tmux the server
/// is daemonized and our own ancestor chain dead-ends at launchd, so
/// we ask tmux for its client tty instead. Outside tmux we fall back
/// to ttyname() on our own fds (stderr first because hooks often pipe
/// stdin/stdout while leaving stderr on the real tty).
func resolveCallerTTY(env: [String: String], tmux: String?) -> String? {
    if let pane = env["TMUX_PANE"], !pane.isEmpty, let tmux,
       let tty = captureOutput(tmux, ["display-message", "-pt", pane, "#{client_tty}"]) {
        return tty
    }
    for fd: Int32 in [2, 1, 0] {
        if let cstr = ttyname(fd) {
            return String(cString: cstr)
        }
    }
    return nil
}

/// Find the bundle id of the terminal app that owns `tty` by looking
/// up a process attached to that tty and walking its ancestors.
func findTerminalBundleByTTY(_ tty: String) -> String? {
    let short = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
    guard let psOut = captureOutput("/bin/ps", ["-t", short, "-o", "pid="]) else { return nil }
    for line in psOut.split(separator: "\n") {
        if let pid = Int32(line.trimmingCharacters(in: .whitespaces)),
           let bid = findBundleByWalkingAncestors(from: pid) {
            return bid
        }
    }
    return nil
}

func detectTerminalBundle(env: [String: String], callerTTY: String?) -> String? {
    if let override = env["NOTCHIFY_TERMINAL_BUNDLE"], !override.isEmpty {
        return override
    }
    if let tty = callerTTY, let bundle = findTerminalBundleByTTY(tty) {
        return bundle
    }
    return findBundleByWalkingAncestors(from: getppid())
}

func resolveTmuxBinary() -> String? {
    return captureOutput("/usr/bin/env", ["sh", "-c", "command -v tmux"])
}

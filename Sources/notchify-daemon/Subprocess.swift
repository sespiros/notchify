import Foundation

/// Subprocess plumbing shared by everything in the daemon that shells
/// out: the focus-poll probes, the recipes status check, click-time
/// tmux resolution.
///
/// Two rules, both learned on 2026-09-07 when one hung osascript froze
/// the daemon for hours (see `FocusDetector.ghosttyFocusedWindowTitle`):
///
///   1. Never wait on a child from the main actor without a bound.
///      `run` takes a timeout for that; on expiry the child gets
///      SIGKILL and the caller moves on.
///   2. Never let one hung child turn into a new hung child per tick.
///      `GuardedProbe` keeps a single outstanding job per probe and
///      answers nil while it is busy, so a wedged child is its own
///      circuit breaker instead of a growing pile of zombies.
enum Subprocess {
    struct Result {
        let exitCode: Int32
        let stdout: String?
        let stderr: String?
    }

    /// Bound for anything the daemon waits for inline. tmux and the
    /// recipes binary answer in milliseconds; anything longer means
    /// they are stuck and the caller should give up rather than hold
    /// the UI.
    static let inlineTimeout: TimeInterval = 2.0

    /// Run `launchPath` and collect its output. With a `timeout` the
    /// call gives up after that long: the child gets SIGKILL and the
    /// result reads as exit code -1. A nil timeout waits forever and
    /// belongs only on a background queue; a child wedged in the
    /// kernel ignores SIGKILL anyway, so there is nothing to bound.
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval?) -> Result {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Result(exitCode: -1, stdout: nil, stderr: nil) }
        // Drain both pipes off-thread. Reading after the exit wait
        // deadlocks a child that fills a pipe; reading before it
        // blocks on a child that never closes its end.
        let out = ValueBox<Data>(Data())
        let err = ValueBox<Data>(Data())
        let drained = DispatchGroup()
        drained.enter()
        ioQueue.async {
            out.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        ioQueue.async {
            err.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                return Result(exitCode: -1, stdout: nil, stderr: nil)
            }
        } else {
            exited.wait()
        }
        // The pipes close with the child; the bound only covers a
        // grandchild that inherited them and lingers.
        _ = drained.wait(timeout: .now() + 1.0)
        return Result(
            exitCode: p.terminationStatus,
            stdout: String(data: out.value, encoding: .utf8),
            stderr: String(data: err.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Readers for child pipes; concurrent because stdout and stderr
    /// of one child are drained side by side.
    private static let ioQueue = DispatchQueue(
        label: "cloud.seimenis.notchify.subprocess-io",
        attributes: .concurrent
    )
}

/// One outstanding job at a time, a bounded wait per ask, nil while
/// busy. Built for probes that a 1 Hz poll asks over and over: a
/// healthy probe answers inside the wait and the caller never notices
/// the queue; a hung one is asked exactly once, every later tick gets
/// nil immediately, and asking resumes by itself when it finally
/// returns.
final class GuardedProbe<T>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let wait: TimeInterval
    private let lock = NSLock()
    private var inFlight = false

    /// - Parameters:
    ///   - label: suffix for the queue name, for `sample` and Instruments.
    ///   - wait: how long one ask blocks the caller before giving up.
    init(label: String, wait: TimeInterval) {
        queue = DispatchQueue(label: "cloud.seimenis.notchify.probe.\(label)")
        self.wait = wait
    }

    /// True while a previous ask is still running.
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    /// Run `work` on the probe's queue unless a previous ask is still
    /// running, wait up to `wait` for it, and return nil when it has
    /// not finished by then (the work keeps running; its result is
    /// dropped). Callers must treat nil as "unknown", never as "no".
    func ask(_ work: @escaping @Sendable () -> T?) -> T? {
        lock.lock()
        if inFlight {
            lock.unlock()
            return nil
        }
        inFlight = true
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        let result = ValueBox<T?>(nil)
        queue.async { [self] in
            result.value = work()
            lock.lock()
            inFlight = false
            lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + wait) == .timedOut { return nil }
        return result.value
    }
}

/// Lock-guarded cell for handing a value between threads.
private final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

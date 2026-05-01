import Foundation

/// One poll tick's view of the world. Detectors read from this
/// instead of probing the OS directly, so:
///   - expensive probes (tmux subprocess, AppleScript) run at most
///     once per tick regardless of how many rows reference them,
///   - tests can construct a snapshot with canned values.
///
/// Probes are lazy: a snapshot that is only consulted by detectors
/// that abstain costs one CGWindowList lookup (the frontmost bundle).
@MainActor
final class FocusSnapshot {
    let frontmostBundle: String?

    private let panesProvider: (String?) -> Set<String>
    private let ghosttyTitleProvider: () -> String?

    private var panesCache: [String?: Set<String>] = [:]
    private var ghosttyTitleResolved: Bool = false
    private var ghosttyTitleCache: String?

    init(
        frontmostBundle: String?,
        panesProvider: @escaping (String?) -> Set<String>,
        ghosttyTitleProvider: @escaping () -> String?
    ) {
        self.frontmostBundle = frontmostBundle
        self.panesProvider = panesProvider
        self.ghosttyTitleProvider = ghosttyTitleProvider
    }

    /// Capture a snapshot from real OS state.
    static func capture() -> FocusSnapshot {
        FocusSnapshot(
            frontmostBundle: FocusDetector.frontmostBundleID(),
            panesProvider: { FocusDetector.activeTmuxPanes(socket: $0) },
            ghosttyTitleProvider: { FocusDetector.ghosttyFocusedWindowTitle() }
        )
    }

    func activePanes(socket: String?) -> Set<String> {
        if let cached = panesCache[socket] { return cached }
        let panes = panesProvider(socket)
        panesCache[socket] = panes
        return panes
    }

    func ghosttyFocusedTitle() -> String? {
        if ghosttyTitleResolved { return ghosttyTitleCache }
        ghosttyTitleCache = ghosttyTitleProvider()
        ghosttyTitleResolved = true
        return ghosttyTitleCache
    }
}

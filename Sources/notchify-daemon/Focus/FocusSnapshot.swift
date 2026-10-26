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
    private let clientsProvider: (String?) -> [String: Set<String>]

    private var panesCache: [String?: Set<String>] = [:]
    private var ghosttyTitleResolved: Bool = false
    private var ghosttyTitleCache: String?
    private var clientsCache: [String?: [String: Set<String>]] = [:]

    init(
        frontmostBundle: String?,
        panesProvider: @escaping (String?) -> Set<String>,
        ghosttyTitleProvider: @escaping () -> String?,
        clientsProvider: @escaping (String?) -> [String: Set<String>] = { _ in [:] }
    ) {
        self.frontmostBundle = frontmostBundle
        self.panesProvider = panesProvider
        self.ghosttyTitleProvider = ghosttyTitleProvider
        self.clientsProvider = clientsProvider
    }

    /// Capture a snapshot from real OS state.
    static func capture() -> FocusSnapshot {
        FocusSnapshot(
            frontmostBundle: FocusDetector.frontmostBundleID(),
            panesProvider: { FocusDetector.activeTmuxPanes(socket: $0) },
            ghosttyTitleProvider: { FocusDetector.ghosttyFocusedWindowTitle() },
            clientsProvider: { FocusDetector.clientTTYsByPane(socket: $0) }
        )
    }

    func activePanes(socket: String?) -> Set<String> {
        if let cached = panesCache[socket] { return cached }
        let panes = panesProvider(socket)
        panesCache[socket] = panes
        return panes
    }

    /// Ttys of the tmux clients showing `pane` right now.
    func clientTTYs(showing pane: String, socket: String?) -> Set<String> {
        if clientsCache[socket] == nil { clientsCache[socket] = clientsProvider(socket) }
        return clientsCache[socket]?[pane] ?? []
    }

    func ghosttyFocusedTitle() -> String? {
        if ghosttyTitleResolved { return ghosttyTitleCache }
        ghosttyTitleCache = ghosttyTitleProvider()
        ghosttyTitleResolved = true
        return ghosttyTitleCache
    }
}

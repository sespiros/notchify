import Foundation

/// Mirrors the CLI's `Sources/notchify/Focus/Focus.swift` provider
/// pattern on the daemon side. Each detector inspects a dismiss key
/// plus a shared `FocusSnapshot` and answers one narrow question
/// ("is this layer of focus on the source?"). Composition is AND
/// across non-abstaining detectors, so adding a detector tightens
/// the match rather than loosening it.
///
/// Adding support for a new terminal or multiplexer is a self-
/// contained change: drop a new file in this directory with a
/// struct conforming to `FocusDetectorProvider`, slot it into
/// `registeredFocusDetectors` below, rebuild. No changes elsewhere.
///
/// The `category` field is purely declarative (mirrors the CLI), so
/// readers can see at a glance whether a detector covers terminal
/// windowing or multiplexer panes. The orchestrator does not
/// currently dispatch on it.
enum FocusDetectorCategory {
    case terminal
    case multiplexer
}

@MainActor
protocol FocusDetectorProvider {
    var category: FocusDetectorCategory { get }

    /// Vote on whether the user's current focus matches `key`.
    ///
    /// - Returns:
    ///   - `nil` to abstain (this detector is not applicable to this
    ///     dismiss key, e.g. the key has no tmux pane so the tmux
    ///     detector has nothing to say).
    ///   - `true` if this detector confirms the user is on the source.
    ///   - `false` to veto: this detector is applicable but the user
    ///     is not on the source.
    func matches(key: DismissKey, snapshot: FocusSnapshot) -> Bool?
}

/// Order is informational here (composition is AND, so order does not
/// affect the outcome). Group by category for readability.
@MainActor
let registeredFocusDetectors: [FocusDetectorProvider] = [
    BundleDetector(),
    GhosttyWindowDetector(),
    TmuxPaneDetector(),
]

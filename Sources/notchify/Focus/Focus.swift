import Foundation

// The -focus click action is built by composing small "providers".
// Each provider inspects a shared FocusContext and either returns a
// shell command (its piece of the action) or nil if it doesn't apply.
//
// Adding support for a new terminal or multiplexer is meant to be a
// self-contained change: drop a new file in this directory with a
// struct conforming to FocusProvider, slot it into
// `registeredFocusProviders` below in the right priority order,
// rebuild. No changes elsewhere.

/// The category controls how providers compose. Within a single
/// category the *first* matching provider wins; later ones are
/// skipped. Across categories the actions are concatenated, so a
/// terminal provider and a multiplexer provider can both fire.
enum FocusCategory {
    /// Brings the right terminal app/window/tab to the front.
    case terminal
    /// Switches a running multiplexer to the originating pane.
    case multiplexer
}

protocol FocusProvider {
    var category: FocusCategory { get }
    /// A shell command (will run under `sh -c` from notchify-daemon)
    /// that performs this provider's piece of the focus, or nil if
    /// the provider doesn't apply.
    func action(in context: FocusContext) -> String?
}

/// Resolved once per CLI invocation and read by every provider.
struct FocusContext {
    let env: [String: String]
    /// Absolute path to tmux, or nil if tmux isn't on PATH.
    let tmuxBinary: String?
    /// The caller's controlling tty, or the tmux client tty when
    /// inside tmux. nil if neither could be resolved.
    let callerTTY: String?
    /// Bundle id of the GUI app that owns the caller (resolved by
    /// walking the process ancestry from the tty owner). nil if none.
    let detectedBundle: String?

    static func resolve(env: [String: String]) -> FocusContext {
        let tmux = resolveTmuxBinary()
        let tty = resolveCallerTTY(env: env, tmux: tmux)
        let bundle = detectTerminalBundle(env: env, callerTTY: tty)
        return FocusContext(env: env, tmuxBinary: tmux, callerTTY: tty, detectedBundle: bundle)
    }
}

/// Order matters: within a category, the first match wins. So put
/// specific providers (e.g. GhosttyFocusProvider) before generic
/// fallbacks (OpenBundleFocusProvider) of the same category.
let registeredFocusProviders: [FocusProvider] = [
    GhosttyFocusProvider(),
    OpenBundleFocusProvider(),
    TmuxFocusProvider(),
]

/// Result of `-focus` resolution.
/// `action` is the shell command that runs on click (raise window,
/// jump to pane). `dismissKey` is the fingerprint the daemon uses
/// to auto-dismiss when the user visits the source. Either may be
/// nil independently, though in practice they go together.
struct FocusResult {
    let action: String?
    let dismissKey: DismissKeyPayload?
}

/// CLI-side mirror of the daemon's `DismissKey`. Kept separate so
/// the two binaries don't have to share a module.
struct DismissKeyPayload: Codable {
    let bundle: String
    let tmuxPane: String?
    let tmuxSocket: String?
}

/// Build the click-action shell string and dismiss-key for `-focus`.
/// Returns a result whose fields are nil when nothing applied; main()
/// emits a warning in that case and the notification fires without
/// either piece.
func buildFocus(env: [String: String]) -> FocusResult {
    let context = FocusContext.resolve(env: env)
    var seen: Set<FocusCategory> = []
    var parts: [String] = []
    for provider in registeredFocusProviders {
        if seen.contains(provider.category) { continue }
        if let part = provider.action(in: context) {
            parts.append(part)
            seen.insert(provider.category)
        }
    }
    let action = parts.isEmpty ? nil : parts.joined(separator: "; ")

    var key: DismissKeyPayload? = nil
    if let bundle = context.detectedBundle {
        let pane = env["TMUX_PANE"].flatMap { $0.isEmpty ? nil : $0 }
        // tmux's $TMUX env value is "<socket-path>,<pid>,<id>". We
        // need the socket path so the daemon can pass `-S <path>` to
        // its own tmux invocation. Without this the daemon would
        // talk to whatever default-socket server its environment
        // points at, which is often a different server than the
        // user's (especially on Nix).
        let tmuxSocket: String? = {
            guard let tmuxEnv = env["TMUX"], !tmuxEnv.isEmpty else { return nil }
            return tmuxEnv.split(separator: ",", maxSplits: 1).first.map(String.init)
        }()
        key = DismissKeyPayload(
            bundle: bundle,
            tmuxPane: pane,
            tmuxSocket: pane != nil ? tmuxSocket : nil
        )
    }

    return FocusResult(action: action, dismissKey: key)
}

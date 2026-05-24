import Foundation

/// Generic terminal-app fallback: `open -b <bundle>` brings the app
/// forward. Picks up whatever GUI app owns the source, so it covers
/// iTerm, Terminal.app, WezTerm, kitty, Alacritty, etc. without
/// per-app code.
///
/// macOS raises the last-frontmost window of the target app, so the
/// right window often comes forward by accident, but there is no
/// per-window targeting at this level. For per-window or per-tab
/// focus add a provider with `category = .terminal` that runs before
/// this one and returns its own action when it matches.
@MainActor
struct OpenBundleActionProvider: FocusActionProvider {
    let category: FocusActionCategory = .terminal

    func action(for focus: DismissKey) -> String? {
        let bundle = focus.bundle
        guard !bundle.isEmpty else { return nil }
        return "open -b \(bundle)"
    }
}

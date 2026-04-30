import Foundation

/// Generic terminal-app fallback: `open -b <bundle>` brings the app
/// forward. Picks up whatever GUI app owns the caller, so it covers
/// iTerm, Terminal.app, WezTerm, kitty, Alacritty, etc. without
/// per-app code.
///
/// macOS raises the last-frontmost window of the target app, so the
/// right window often comes forward by accident, but there is no
/// per-window targeting at this level. If you want per-window or
/// per-tab focus for a specific terminal, write a provider with
/// category=.terminal that runs *before* this one and returns its
/// own action when it matches.
struct OpenBundleFocusProvider: FocusProvider {
    let category: FocusCategory = .terminal

    func action(in context: FocusContext) -> String? {
        guard let bundle = context.detectedBundle else { return nil }
        return "open -b \(bundle)"
    }
}

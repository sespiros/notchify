import Foundation

/// Builds the click-time shell action for a `--focus` notification.
///
/// Click-action providers mirror the matching providers in
/// `FocusDetectorProvider`: drop a file in `Focus/`, conform to this
/// protocol, slot into `registeredFocusActionProviders`, rebuild.
///
/// Composition: within a single category the *first* matching provider
/// wins; later ones in the same category are skipped. Across categories
/// the actions concatenate (joined with `; `), so a terminal provider
/// and a multiplexer provider both fire on the same click.
@MainActor
protocol FocusActionProvider {
    var category: FocusActionCategory { get }

    /// Returns the shell snippet that performs this provider's piece of
    /// the focus, or nil if the provider doesn't apply.
    func action(for focus: DismissKey) -> String?
}

enum FocusActionCategory {
    /// Raises the right terminal app/window/tab.
    case terminal
    /// Switches a running multiplexer to the originating pane.
    case multiplexer
}

/// Registration order is priority order within a category. Specific
/// providers (e.g. GhosttyActionProvider) go before generic fallbacks
/// (OpenBundleActionProvider) of the same category.
@MainActor
let registeredFocusActionProviders: [FocusActionProvider] = [
    GhosttyActionProvider(),
    OpenBundleActionProvider(),
    TmuxActionProvider(),
]

@MainActor
enum FocusActionBuilder {
    /// Build the composed shell action for a click on a focus-bearing
    /// notification. Returns nil when no provider applied (the caller
    /// then runs the regular `message.action`, which is also nil for
    /// pure `--focus` notifications => banner with no click side-effect).
    static func build(for focus: DismissKey) -> String? {
        var seen: Set<FocusActionCategory> = []
        var parts: [String] = []
        for provider in registeredFocusActionProviders {
            if seen.contains(provider.category) { continue }
            if let part = provider.action(for: focus) {
                parts.append(part)
                seen.insert(provider.category)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

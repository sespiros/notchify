import AppKit
import Sparkle

/// Sparkle-backed in-app updater for drag-installed builds. Suppressed
/// for Nix installs (the OS package manager owns the version there).
@MainActor
final class Updater {
    /// True when the running bundle lives under /nix/store, i.e. it was
    /// installed via Nix and updates are managed out-of-band. Symlinks
    /// are resolved first so a /Applications/Nix Apps/ symlink into the
    /// store still counts.
    static let isNixInstall: Bool = {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/nix/store/")
    }()

    static func makeIfEnabled() -> Updater? {
        guard !isNixInstall else { return nil }
        return Updater()
    }

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}

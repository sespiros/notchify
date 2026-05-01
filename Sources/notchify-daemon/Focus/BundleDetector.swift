import Foundation

/// The frontmost GUI app's bundle id must equal the source bundle.
/// Always opines: every dismiss key carries a bundle, and bundle
/// equality is the baseline that every match builds on.
struct BundleDetector: FocusDetectorProvider {
    let category: FocusDetectorCategory = .terminal

    func matches(key: DismissKey, snapshot: FocusSnapshot) -> Bool? {
        return key.bundle == snapshot.frontmostBundle
    }
}
